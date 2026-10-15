import XCTest
import MetalKit
import Network
import Dependencies
import Clocks
import ConcurrencyExtras
@testable import Holodeck
@testable import HolodeckCore

@MainActor
final class HolodeckTests: XCTestCase {
    func testDeliveryReportsOnlyOutputDefectsAndRetriesTransientFailures() async throws {
        for scenario in ["capture", "refresh", "control", "activation", "missing", "superseded", "success"] {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let renderer = try makeRenderer(view: MTKView(frame: .zero, device: device))
            let service = CatalogService(initialCatalog: TestCatalog.catalog, source: CatalogSource(kind: .standard) { request, _ in
                if scenario == "refresh" { throw LocalCatalogError.timeout }
                guard case .head = request else { throw CatalogError.invalidResponse }
                return try JSONEncoder().encode(CatalogHead(revision: TestCatalog.catalog.publicationRevision))
            }, storage: .disabled)
            let session = ViewerSession(catalogService: service, preferences: .inMemory(), policy: .tv)
            let scenes = DeliverySceneRenderer(); session.attach(scenes)
            await session.refreshTask?.value; await session.selectionTask?.value
            scenes.mode = scenario
            let shader = scenario == "activation" || scenario == "superseded" ? TestCatalog.shaders[1] : TestCatalog.initialShader
            let png = try RequestScreenshot.encode(pixels: Data([128,64,32,255]), width: 1, height: 1, bytesPerRow: 4)
            let context = ShaderRequestContext(shader: shader, screenshot: png, animationTime: 0, width: 1280, height: 720)
            var diagnostics: [String] = [], acknowledgements = 0
            let operations = TVRequestOperations(control: { operation, payload in
                if scenario == "control" { throw ShaderRequestError.unavailable("Host temporarily busy") }
                if operation == "requestActivated" {
                    if let diagnostic = payload.diagnostic { diagnostics.append(diagnostic) }
                    else { acknowledgements += 1 }
                }
                return ShaderRequestControlReply(enabled: true, message: "Fixture")
            }, capture: {
                if scenario == "capture" { throw ShaderRequestError.unavailable("Frame capture temporarily unavailable") }
                return context
            })
            let presenter = UIViewController()
            let controller = TVRequestsController(presenter: presenter, renderer: renderer, client: LocalCatalogClient(), session: session,
                defaults: nil, covered: { false }, operations: operations)
            var job = ShaderRequestStatus(request: ShaderRequest(prompt: "Fixture", context: context), deviceID: "TV")
            job.stage = .awaitingActivation
            job.result = ShaderRequestResult(outputKind: .edited, shaderID: scenario == "missing" ? "removed" : shader.id,
                changed: true, summary: "Fixture", approximations: [])
            controller.setForeground(true)
            await controller.deliver(job) // Delivery nonce handshake.
            await controller.deliver(job)
            controller.setForeground(false)
            XCTAssertEqual(diagnostics.count, scenario == "missing" || scenario == "activation" ? 1 : 0, scenario)
            XCTAssertEqual(acknowledgements, scenario == "success" ? 1 : 0, scenario)
        }
    }
    func testPerformanceSubmissionGuardSpansCaptureAndDelayedAcknowledgement() async throws {
        let gate = PerformanceSubmissionGate()
        let capture = AsyncStream<Void>.makeStream()
        let acknowledgement = AsyncStream<Void>.makeStream()
        var captures = 0, submissions = 0
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { XCTFail("Submission fixture timed out"); throw ShaderRequestError.unavailable("Test backstop") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let submit: @MainActor () async -> Void = {
            captures += 1
            for await _ in capture.stream { break }
            submissions += 1
            for await _ in acknowledgement.stream { break }
        }
        gate.start(submit)
        try await waitUntil { captures == 1 }
        capture.continuation.yield()
        try await waitUntil { submissions == 1 }
        var monitor = ShaderPerformanceMonitor()
        monitor.reset(at: 0)
        for frame in 0..<300 {
            if monitor.presented(at: Double(frame) / 20) != nil { gate.start(submit) }
        }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(submissions, 1)
        XCTAssertTrue(gate.isSubmitting)
        acknowledgement.continuation.yield()
        try await waitUntil { !gate.isSubmitting }
        XCTAssertFalse(gate.isSubmitting)
        gate.start(submit)
        try await waitUntil { captures == 2 }
        capture.continuation.yield()
        try await waitUntil { submissions == 2 }
        acknowledgement.continuation.yield()
        try await waitUntil { !gate.isSubmitting }
        capture.continuation.finish(); acknowledgement.continuation.finish()
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(submissions, 2)
        XCTAssertFalse(gate.isSubmitting)
    }

    func testUserActivationDismissesOpenChooserButStartupLeavesItOpen() async throws {
        for userSelection in [false, true] {
            let (controller, compiler, pipeline) = try await controlledController()
            try await waitForRequest("plasma", in: compiler)
            var selection = try XCTUnwrap(controller.shaderSelectionTask)
            controller.openPickerFromRemote()
            if userSelection {
                await compiler.complete("plasma", pipeline: pipeline)
                try await waitForSelection(selection)
                let cards: UICollectionView = try findView("shader-cards", in: controller)
                controller.collectionView(cards, didSelectItemAt: IndexPath(item: 1, section: 0))
                try await waitForRequest("aurora", in: compiler)
                selection = try XCTUnwrap(controller.shaderSelectionTask)
            }
            let button: UIButton = try findView("collection-filter", in: controller)
            button.sendActions(for: .primaryActionTriggered)
            let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                controller.presentedViewController is UIAlertController && controller.presentedViewController?.isBeingPresented == false
            }, object: controller)
            try await waitForExpectation(presented)
            await compiler.complete(userSelection ? "aurora" : "plasma", pipeline: pipeline)
            try await waitForSelection(selection)
            let picker: UIView = try findView("shader-picker", in: controller)
            XCTAssertEqual(picker.isHidden, userSelection)
            if userSelection {
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    controller.presentedViewController == nil
                }, object: controller)
                try await waitForExpectation(dismissed)
            }
            else {
                XCTAssertTrue(controller.presentedViewController is UIAlertController)
                controller.closePickerFromRemote()
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    controller.presentedViewController == nil
                }, object: controller)
                try await waitForExpectation(dismissed)
            }
        }
    }

    func testRefreshKeepsUserSelectionFailureVisibleOverPlayback() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        controller.openPickerFromRemote()
        let cards: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(cards, didSelectItemAt: IndexPath(item: 1, section: 0))
        try await waitForRequest("aurora", in: compiler)
        let selection = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.fail("aurora")
        try await waitForSelection(selection)
        var snapshot = TestCatalog.snapshot
        snapshot.manifest.shaders.reverse()
        snapshot.publicationRevision = String(repeating: "a", count: 40)
        controller.applyCatalog(try snapshot.validated())
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertEqual(status.text, "Couldn’t load Aurora. Choose another shader.")
        XCTAssertEqual((controller.view as? MTKView)?.delegate.flatMap { ($0 as? Renderer)?.activeShader?.id }, "plasma")
    }

    func testRefreshDuringSelectionKeepsPendingShaderAndCurrentPlayback() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        try await waitForRequest("aurora", in: compiler)
        let pending = try XCTUnwrap(controller.shaderSelectionTask)
        var refreshed = TestCatalog.snapshot
        refreshed.manifest.shaders.reverse()
        refreshed.publicationRevision = String(repeating: "a", count: 40)
        controller.applyCatalog(try! refreshed.validated())
        XCTAssertEqual(controller.collectionView(collection, numberOfItemsInSection: 0), 8)
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertEqual(status.text, "Loading Aurora…")
        await compiler.complete("aurora", pipeline: pipeline)
        try await waitForSelection(pending)
        XCTAssertTrue(status.text?.hasPrefix("Now showing Aurora") == true)
        controller.openPickerFromRemote()
        XCTAssertEqual(controller.indexPathForPreferredFocusedView(in: collection)?.item, 6)
    }

    func testRemovedActiveShaderKeepsPlayingAndNewSelectionIsAvailable() async throws {
        let preferences = PreferenceSpy(id: "plasma")
        let (controller, compiler, pipeline) = try await controlledController(preferences: preferences.client)
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        var refreshed = TestCatalog.snapshot
        var added = refreshed.manifest.shaders[0]
        added.id = "ninth-shader"; added.name = "Ninth Shader"
        added.sourcePath = "sources/ninth-shader.metal"
        added.previewPath = "previews/ninth-shader.png"
        refreshed.sources[added.id] = refreshed.sources["plasma"]
        refreshed.manifest.shaders.removeFirst()
        refreshed.sources.removeValue(forKey: "plasma")
        refreshed.manifest.shaders.append(added)
        refreshed.manifest.defaultShaderID = "aurora"
        refreshed.publicationRevision = String(repeating: "a", count: 40)
        controller.applyCatalog(try! refreshed.validated())
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertTrue(status.text?.hasPrefix("Now showing Plasma") == true)
        XCTAssertEqual(preferences.id, "plasma")
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 7, section: 0))
        try await waitForRequest("ninth-shader", in: compiler)
        let selection = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("ninth-shader", pipeline: pipeline)
        try await waitForSelection(selection)
        XCTAssertEqual(preferences.id, "ninth-shader")
    }

    func testInvalidSourceAndMissingEntryPointPreserveActiveShader() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let renderer = try makeRenderer(view: view)
        let activated = try await renderer.select(TestCatalog.initialShader)
        XCTAssertTrue(activated)
        let missingFragment = TestCatalog.initialShader.source.replacingOccurrences(
            of: "fragment float4 fragmentShader", with: "fragment float4 otherFragment")
        for source in ["not valid Metal source", "#include <metal_stdlib>\nusing namespace metal;", missingFragment] {
            let bad = ShaderDefinition(id: UUID().uuidString, title: "Broken", category: .procedural,
                                       description: "", colors: [], source: source)
            do {
                try await renderer.select(bad)
                XCTFail("Invalid shaders must report an error")
            } catch {
                XCTAssertEqual(renderer.activeShader?.id, "plasma")
            }
        }
    }

    func testLatestSelectionWinsAndStaleFailuresAreIgnored() async throws {
        let (renderer, compiler, pipeline) = try await controlledRenderer()
        let older = TestCatalog.shaders[1], newer = TestCatalog.shaders[2]
        let olderTask = Task { try await renderer.select(older) }
        await compiler.waitForRequest(older.id)
        let newerTask = Task { try await renderer.select(newer) }
        await compiler.waitForRequest(newer.id)
        XCTAssertEqual(renderer.activeShader?.id, "plasma")
        await compiler.complete(newer.id, pipeline: pipeline)
        let newerActivated = try await newerTask.value
        XCTAssertTrue(newerActivated)
        await compiler.fail(older.id)
        let olderActivated = try await olderTask.value
        XCTAssertFalse(olderActivated)
        XCTAssertEqual(renderer.activeShader?.id, newer.id)

        let firstTask = Task { try await renderer.select(older) }
        await compiler.waitForRequest(older.id)
        let secondTask = Task { try await renderer.select(TestCatalog.shaders[3]) }
        await compiler.waitForRequest(TestCatalog.shaders[3].id)
        await compiler.complete(older.id, pipeline: pipeline)
        let staleActivated = try await firstTask.value
        XCTAssertFalse(staleActivated)
        await compiler.complete(TestCatalog.shaders[3].id, pipeline: pipeline)
        let latestActivated = try await secondTask.value
        XCTAssertTrue(latestActivated)
        XCTAssertEqual(renderer.activeShader?.id, "kaleidoscope")
    }

    func testDismissingPendingSelectionAndSceneActivity() async throws {
        let (renderer, compiler, pipeline) = try await controlledRenderer()
        let shader = TestCatalog.shaders[1]
        let pending = Task { try await renderer.select(shader) }
        await compiler.waitForRequest(shader.id)
        renderer.cancelPendingSelection()
        await compiler.complete(shader.id, pipeline: pipeline)
        let activated = try await pending.value
        XCTAssertFalse(activated)
        XCTAssertEqual(renderer.activeShader?.id, "plasma")

        let view = MTKView(frame: .zero, device: renderer.device)
        let lifecycleRenderer = try makeRenderer(view: view)
        XCTAssertTrue(view.isPaused)
        lifecycleRenderer.setActive(true)
        XCTAssertFalse(view.isPaused)
        lifecycleRenderer.setActive(false)
        XCTAssertTrue(view.isPaused)
    }

    func testInitialActivationKeepsPickerAndBrowsingPosition() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        let index = IndexPath(item: 5, section: 0)
        collection.scrollToItem(at: index, at: .centeredHorizontally, animated: false)
        collection.layoutIfNeeded()
        XCTAssertNotNil(collection.cellForItem(at: index))
        let offset = collection.contentOffset

        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)

        let picker: UIView = try findView("shader-picker", in: controller)
        let hint: UIView = try findView("shader-hint", in: controller)
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertFalse(picker.isHidden)
        XCTAssertTrue(hint.isHidden)
        XCTAssertEqual(collection.contentOffset, offset)
        XCTAssertTrue(status.text?.hasPrefix("Now showing Plasma") == true)
    }

    func testInitialLoadingContinuesAfterBackDismissal() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        controller.closePickerFromRemote()
        let picker: UIView = try findView("shader-picker", in: controller)
        XCTAssertTrue(picker.isHidden)
        let loadingHint: UIView = try findView("shader-hint", in: controller)
        XCTAssertFalse(loadingHint.isHidden)
        XCTAssertTrue(loadingHint.subviewsRecursive.contains { ($0 as? UILabel)?.text == "Loading Plasma…" })

        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        let hint: UIView = try findView("shader-hint", in: controller)
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertTrue(picker.isHidden)
        XCTAssertFalse(hint.isHidden)
        XCTAssertTrue(status.text?.hasPrefix("Now showing Plasma") == true)
    }

    func testInitialFailureKeepsPickerAndBrowsingPosition() async throws {
        let (controller, compiler, _) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        collection.scrollToItem(at: IndexPath(item: 5, section: 0), at: .centeredHorizontally, animated: false)
        collection.layoutIfNeeded()
        let offset = collection.contentOffset
        await compiler.fail("plasma")
        try await waitForSelection(initial)
        let picker: UIView = try findView("shader-picker", in: controller)
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertFalse(picker.isHidden)
        XCTAssertEqual(collection.contentOffset, offset)
        XCTAssertEqual(status.text, "Couldn’t load Plasma. Choose another shader.")
    }

    func testStartupBackCancelsUserSelectionAndResumesPlasma() async throws {
        for selectedFails in [false, true] {
            for fallbackFirst in [false, true] {
                let (controller, compiler, pipeline) = try await controlledController()
                try await waitForRequest("plasma", in: compiler)
                let initial = try XCTUnwrap(controller.shaderSelectionTask)
                controller.openPickerFromRemote()
                let collection: UICollectionView = try findView("shader-cards", in: controller)
                controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
                try await waitForRequest("aurora", in: compiler)
                let selected = try XCTUnwrap(controller.shaderSelectionTask)
                controller.closePickerFromRemote()
                let hint: UIView = try findView("shader-hint", in: controller)
                XCTAssertFalse(hint.isHidden)
                try await waitForRequest("plasma", occurrence: 2, in: compiler)
                let fallback = try XCTUnwrap(controller.shaderSelectionTask)
                controller.openPickerFromRemote()
                let picker: UIView = try findView("shader-picker", in: controller)
                let status: UILabel = try findView("shader-status", in: controller)

                if fallbackFirst {
                    await compiler.complete("plasma", occurrence: 2, pipeline: pipeline)
                    try await waitForSelection(fallback)
                }
                let before = status.text
                if selectedFails { await compiler.fail("aurora") }
                else { await compiler.complete("aurora", pipeline: pipeline) }
                try await waitForSelection(selected)
                XCTAssertFalse(picker.isHidden)
                XCTAssertEqual(status.text, before)
                await compiler.fail("plasma", occurrence: 1)
                try await waitForSelection(initial)
                XCTAssertEqual(status.text, before)
                if !fallbackFirst {
                    await compiler.complete("plasma", occurrence: 2, pipeline: pipeline)
                    try await waitForSelection(fallback)
                }
                XCTAssertFalse(picker.isHidden)
                XCTAssertTrue(status.text?.hasPrefix("Now showing Plasma") == true)
                let plasma = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
                XCTAssertEqual(plasma.accessibilityValue, "Now showing")
                XCTAssertTrue(hint.isHidden)
            }
        }
    }

    func testBackCancelsSelectionBeforeItsTaskStarts() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        let canceled = try XCTUnwrap(controller.shaderSelectionTask)
        controller.closePickerFromRemote()
        try await waitForSelection(canceled)
        let auroraRequests = await compiler.requestCount("aurora")
        XCTAssertEqual(auroraRequests, 0)
        try await waitForRequest("plasma", occurrence: 2, in: compiler)
        let fallback = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", occurrence: 2, pipeline: pipeline)
        try await waitForSelection(fallback)
        await compiler.complete("plasma", occurrence: 1, pipeline: pipeline)
        try await waitForSelection(initial)
        let picker: UIView = try findView("shader-picker", in: controller)
        let hint: UIView = try findView("shader-hint", in: controller)
        XCTAssertTrue(picker.isHidden)
        XCTAssertFalse(hint.isHidden)
    }

    func testControllerBackRetainsActiveShader() async throws {
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        try await waitForRequest("aurora", in: compiler)
        let selected = try XCTUnwrap(controller.shaderSelectionTask)
        controller.closePickerFromRemote()
        controller.openPickerFromRemote()
        let status: UILabel = try findView("shader-status", in: controller)
        let before = status.text
        await compiler.complete("aurora", pipeline: pipeline)
        try await waitForSelection(selected)
        let picker: UIView = try findView("shader-picker", in: controller)
        XCTAssertFalse(picker.isHidden)
        XCTAssertEqual(status.text, before)
        XCTAssertTrue(status.text?.hasPrefix("Now showing Plasma") == true)
    }

    func testExplicitSelectionSupersedesInitialCompletionAndFailure() async throws {
        for initialFails in [false, true] {
            let (controller, compiler, pipeline) = try await controlledController()
            try await waitForRequest("plasma", in: compiler)
            let initial = try XCTUnwrap(controller.shaderSelectionTask)
            controller.openPickerFromRemote()
            let collection: UICollectionView = try findView("shader-cards", in: controller)
            controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
            try await waitForRequest("aurora", in: compiler)
            let selected = try XCTUnwrap(controller.shaderSelectionTask)
            await compiler.complete("aurora", pipeline: pipeline)
            try await waitForSelection(selected)

            if initialFails {
                await compiler.fail("plasma")
            } else {
                await compiler.complete("plasma", pipeline: pipeline)
            }
            try await waitForSelection(initial)

            let picker: UIView = try findView("shader-picker", in: controller)
            let hint: UIView = try findView("shader-hint", in: controller)
            let status: UILabel = try findView("shader-status", in: controller)
            XCTAssertTrue(picker.isHidden)
            XCTAssertTrue(hint.isHidden)
            XCTAssertTrue(status.text?.hasPrefix("Now showing Aurora") == true)
        }
    }

    func testUnavailableRendererWithEmptyAndCachedCatalogNeverRefreshesOnReactivation() async throws {
        for cached in [false, true] {
            let counter = ControllerNetworkCounter()
            let service = CatalogService(initialCatalog: cached ? TestCatalog.catalog : nil,
                source: CatalogSource(kind: .standard) { url, _ in
                    if url.isHead { await counter.record() }
                    throw CatalogError.invalidResponse
                }, storage: .disabled)
            let controller = try await hostController(dependencies: { $0.catalogService = service },
                factory: { _ in throw RendererStartupError.metalUnavailable })
            let status: UILabel = try findView("shader-status", in: controller)
            let hint: UIView = try findView("shader-hint", in: controller)
            let spinner: UIActivityIndicatorView = try findView("shader-loading", in: controller)
            for _ in 0..<3 {
                controller.setSceneActive(false)
                controller.setSceneActive(true)
                XCTAssertEqual(status.text, RendererStartupError.metalUnavailable.localizedDescription)
                XCTAssertTrue(hint.isHidden)
                XCTAssertFalse(spinner.isAnimating)
                controller.openPickerFromRemote()
            }
            let requests = await counter.count
            XCTAssertEqual(requests, 0)
        }
    }

    func testUnavailableErrorsSurvivePickerUpdates() async throws {
        for error in [RendererStartupError.metalUnavailable, .initializationFailed] {
            let controller = try await hostController(factory: { view in
                if case .initializationFailed = error { view.device = MTLCreateSystemDefaultDevice() }
                throw error
            })
            let picker: UIView = try findView("shader-picker", in: controller)
            let hint: UIView = try findView("shader-hint", in: controller)
            let status: UILabel = try findView("shader-status", in: controller)
            let spinner: UIActivityIndicatorView = try findView("shader-loading", in: controller)
            let collection: UICollectionView = try findView("shader-cards", in: controller)
            XCTAssertNil(controller.shaderSelectionTask)
            let metalView = try XCTUnwrap(controller.view as? MTKView)
            XCTAssertTrue(metalView.isPaused)
            for _ in 0..<3 {
                controller.setSceneActive(false)
                controller.setSceneActive(true)
                XCTAssertTrue(metalView.isPaused)
                controller.openPickerFromRemote()
                controller.closePickerFromRemote()
                XCTAssertFalse(picker.isHidden)
                XCTAssertTrue(hint.isHidden)
                XCTAssertEqual(status.text, error.localizedDescription)
                XCTAssertFalse(spinner.isAnimating)
                XCTAssertFalse(collection.isUserInteractionEnabled)
            }
        }
    }

    func testPickerLayoutIsStableWhileLoadingReadyAndUnavailable() async throws {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)] {
            let (controller, compiler, pipeline) = try await controlledController(size: size)
            try await waitForRequest("plasma", in: compiler)
            let initial = try XCTUnwrap(controller.shaderSelectionTask)
            controller.openPickerFromRemote()
            let loading = try checkPickerLayout(controller, size: size)
            await compiler.complete("plasma", pipeline: pipeline)
            try await waitForSelection(initial)
            XCTAssertEqual(try checkPickerLayout(controller, size: size), loading)
            let unavailable = try await hostController(size: size, factory: { _ in throw RendererStartupError.metalUnavailable })
            XCTAssertEqual(try checkPickerLayout(unavailable, size: size), loading)
        }
    }

    func testDeviceAndCompilerOverridesSurviveControllerConstructionScope() async throws {
        let (device, pipeline) = try await Self.controllerPipeline.value
        let compiler = ControlledCompiler()
        addTeardownBlock { await compiler.cancelAll() }
        let preferences = PreferenceSpy()
        let controller = try await hostController(preferences: preferences.client, dependencies: {
            $0.metalDevice = device
            $0.shaderCompilerFactory = { actualDevice, pixelFormat in
                XCTAssertTrue(actualDevice === device)
                XCTAssertEqual(pixelFormat, .bgra8Unorm_srgb)
                return compiler
            }
        })
        XCTAssertTrue((controller.view as? MTKView)?.device === device)
        try await waitForRequest("plasma", in: compiler)
        let selection = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(selection)
        XCTAssertEqual(preferences.writes, ["plasma"])
    }

    func testMissingMetalUsesRegisteredDeviceDependency() async throws {
        let controller = try await hostController(dependencies: { $0.metalDevice = nil })
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertEqual(status.text, RendererStartupError.metalUnavailable.localizedDescription)
        XCTAssertNil(controller.shaderSelectionTask)
        XCTAssertTrue((controller.view as? MTKView)?.isPaused == true)
    }

    func testRendererUsesControlledTimeForPauseResumeAndSelectionReset() async throws {
        let (device, pipeline) = try await Self.controllerPipeline.value
        let compiler = ControlledCompiler()
        addTeardownBlock { await compiler.cancelAll() }
        let time = ControlledTime(value: 10)
        let view = MTKView(frame: .zero, device: device)
        let renderer = try makeRenderer(view: view, compilerFactory: { _, _ in compiler }, now: { time.value })
        renderer.setActive(true)
        let initial = Task { try await renderer.select(TestCatalog.initialShader) }
        await compiler.waitForRequest("plasma")
        await compiler.complete("plasma", pipeline: pipeline)
        let activated = try await initial.value
        XCTAssertTrue(activated)
        XCTAssertEqual(renderer.animationTime, 0)
        time.value = 12
        XCTAssertEqual(renderer.animationTime, 2)
        time.value = 13
        renderer.setActive(false)
        XCTAssertTrue(view.isPaused)
        time.value = 100
        XCTAssertEqual(renderer.animationTime, 3)
        renderer.setActive(true)
        XCTAssertFalse(view.isPaused)
        time.value = 102
        XCTAssertEqual(renderer.animationTime, 5)
        let next = Task { try await renderer.select(TestCatalog.shaders[1]) }
        await compiler.waitForRequest("aurora")
        await compiler.complete("aurora", pipeline: pipeline)
        let nextActivated = try await next.value
        XCTAssertTrue(nextActivated)
        XCTAssertEqual(renderer.animationTime, 0)
    }

    func testStartupHintUsesFourSecondClockAndCancelsWhenPickerOpens() async throws {
        // Advance virtual time and main-actor UI tasks on a deterministic test executor.
        try await withMainSerialExecutor {
            for opensPicker in [false, true] {
                let clock = TestClock()
                let (controller, compiler, pipeline) = try await controlledController(clock: clock)
                try await waitForRequest("plasma", in: compiler)
                let initial = try XCTUnwrap(controller.shaderSelectionTask)
                await compiler.complete("plasma", pipeline: pipeline)
                try await waitForSelection(initial)
                let hint: UIView = try findView("shader-hint", in: controller)
                let hintTask = try XCTUnwrap(controller.hintTask)
                await clock.advance(by: .seconds(3))
                XCTAssertFalse(hint.isHidden)
                if opensPicker {
                    controller.openPickerFromRemote()
                    XCTAssertTrue(hintTask.isCancelled)
                    XCTAssertTrue(hint.isHidden)
                    try await waitForSelection(hintTask)
                    try await clock.checkSuspension()
                    await clock.advance(by: .seconds(1))
                    XCTAssertTrue(hint.isHidden)
                } else {
                    await clock.advance(by: .seconds(1))
                    try await waitForSelection(hintTask)
                    XCTAssertTrue(hint.isHidden)
                }
            }
        }
    }

    func testSavedAbsentAndUnknownShaderIDsResolveOnceAndSaveAfterActivation() async throws {
        for savedID in [nil, "aurora", "removed-shader"] as [String?] {
            let preferences = PreferenceSpy(id: savedID)
            let (controller, compiler, pipeline) = try await controlledController(preferences: preferences.client)
            let expected = savedID == "aurora" ? "aurora" : "plasma"
            try await waitForRequest(expected, in: compiler)
            XCTAssertEqual(preferences.reads, 1)
            XCTAssertTrue(preferences.writes.isEmpty)
            let hint: UIView = try findView("shader-hint", in: controller)
            let title = expected == "aurora" ? "Aurora" : "Plasma"
            XCTAssertTrue(hint.subviewsRecursive.contains { ($0 as? UILabel)?.text == "Loading \(title)…" })
            let initial = try XCTUnwrap(controller.shaderSelectionTask)
            controller.openPickerFromRemote()
            let collection: UICollectionView = try findView("shader-cards", in: controller)
            XCTAssertEqual(controller.indexPathForPreferredFocusedView(in: collection)?.item, expected == "aurora" ? 1 : 0)
            await compiler.complete(expected, pipeline: pipeline)
            try await waitForSelection(initial)
            XCTAssertEqual(preferences.id, expected)
            XCTAssertEqual(preferences.writes, [expected])
            XCTAssertEqual(preferences.reads, 1)
        }
    }

    func testRestoredShaderFailureKeepsSavedIDAndAllowsRecovery() async throws {
        let preferences = PreferenceSpy(id: "aurora")
        let (controller, compiler, pipeline) = try await controlledController(preferences: preferences.client)
        try await waitForRequest("aurora", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.fail("aurora")
        try await waitForSelection(initial)
        let picker: UIView = try findView("shader-picker", in: controller)
        let status: UILabel = try findView("shader-status", in: controller)
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        XCTAssertFalse(picker.isHidden)
        XCTAssertEqual(status.text, "Couldn’t load Aurora. Choose another shader.")
        XCTAssertEqual(controller.indexPathForPreferredFocusedView(in: collection)?.item, 1)
        XCTAssertEqual(preferences.id, "aurora")
        XCTAssertTrue(preferences.writes.isEmpty)
        let plasmaRequests = await compiler.requestCount("plasma")
        XCTAssertEqual(plasmaRequests, 0)
        let menu = try XCTUnwrap(controller.view.gestureRecognizers?.first { $0.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue)) })
        XCTAssertFalse(menu.isEnabled, "Idle recovery must pass Back to the system")
        controller.closePickerFromRemote()
        XCTAssertFalse(picker.isHidden, "Recovery remains visible if invoked directly")
        XCTAssertTrue(status.text?.contains("Couldn’t load Aurora") == true)
        XCTAssertNil((controller.view as? MTKView)?.delegate.flatMap { ($0 as? Renderer)?.activeShader })
        XCTAssertEqual(preferences.id, "aurora")
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 2, section: 0))
        try await waitForRequest("waves", in: compiler)
        let canceled = try XCTUnwrap(controller.shaderSelectionTask)
        XCTAssertTrue(menu.isEnabled, "Pending recovery selection handles the first Back")
        controller.closePickerFromRemote()
        XCTAssertFalse(menu.isEnabled)
        XCTAssertFalse(picker.isHidden)
        await compiler.complete("waves", pipeline: pipeline)
        try await waitForSelection(canceled)
        let auroraRequests = await compiler.requestCount("aurora")
        XCTAssertEqual(auroraRequests, 1, "Cancel must not automatically retry the failed startup")
        XCTAssertTrue(preferences.writes.isEmpty)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 2, section: 0))
        try await waitForRequest("waves", in: compiler)
        let recovery = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("waves", pipeline: pipeline)
        try await waitForSelection(recovery)
        XCTAssertEqual(preferences.writes, ["waves"])
    }

    func testFailedCanceledAndSupersededSelectionsNeverOverwritePreferences() async throws {
        let preferences = PreferenceSpy(id: "plasma")
        let (controller, compiler, pipeline) = try await controlledController(preferences: preferences.client)
        try await waitForRequest("plasma", in: compiler)
        let startup = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        try await waitForRequest("aurora", in: compiler)
        let selected = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.complete("aurora", pipeline: pipeline)
        try await waitForSelection(selected)
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(startup)
        XCTAssertEqual(preferences.writes, ["aurora"])

        controller.openPickerFromRemote()
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 2, section: 0))
        try await waitForRequest("waves", in: compiler)
        let failed = try XCTUnwrap(controller.shaderSelectionTask)
        await compiler.fail("waves")
        try await waitForSelection(failed)
        XCTAssertEqual(preferences.writes, ["aurora"])

        for index in [3, 4] {
            controller.collectionView(collection, didSelectItemAt: IndexPath(item: index, section: 0))
            let id = TestCatalog.shaders[index].id
            try await waitForRequest(id, in: compiler)
            let canceled = try XCTUnwrap(controller.shaderSelectionTask)
            controller.closePickerFromRemote()
            if index == 3 { await compiler.complete(id, pipeline: pipeline) } else { await compiler.fail(id) }
            try await waitForSelection(canceled)
            XCTAssertEqual(preferences.writes, ["aurora"])
            controller.openPickerFromRemote()
        }
        XCTAssertEqual(preferences.id, "aurora")
    }

    func testBackRestartsRememberedStartupAndPreservesBrowsing() async throws {
        let preferences = PreferenceSpy(id: "waves")
        let (controller, compiler, pipeline) = try await controlledController(preferences: preferences.client)
        try await waitForRequest("waves", occurrence: 1, in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        try await waitForRequest("aurora", in: compiler)
        let canceled = try XCTUnwrap(controller.shaderSelectionTask)
        controller.closePickerFromRemote()
        try await waitForRequest("waves", occurrence: 2, in: compiler)
        let resumed = try XCTUnwrap(controller.shaderSelectionTask)
        let hint: UIView = try findView("shader-hint", in: controller)
        XCTAssertTrue(hint.subviewsRecursive.contains { ($0 as? UILabel)?.text == "Loading Waves…" })
        XCTAssertTrue(preferences.writes.isEmpty)
        controller.openPickerFromRemote()
        let spinner: UIActivityIndicatorView = try findView("shader-loading", in: controller)
        XCTAssertTrue(spinner.isAnimating, "Resumed startup keeps its spinner when reopened")
        collection.scrollToItem(at: IndexPath(item: 5, section: 0), at: .centeredHorizontally, animated: false)
        collection.layoutIfNeeded()
        let offset = collection.contentOffset
        await compiler.complete("waves", occurrence: 2, pipeline: pipeline)
        try await waitForSelection(resumed)
        XCTAssertEqual(collection.contentOffset, offset)
        await compiler.fail("aurora")
        await compiler.complete("waves", occurrence: 1, pipeline: pipeline)
        try await waitForSelection(canceled)
        try await waitForSelection(initial)
        XCTAssertEqual(preferences.writes, ["waves"])
        XCTAssertEqual(preferences.reads, 1)
    }

    func testPreferencesUserDefaultsRoundTripAndMemoryIsolation() throws {
        let suite = "Holodeck.unit-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShaderPreferences.userDefaults(defaults)
        XCTAssertNil(preferences.lastShaderID())
        preferences.setLastShaderID("aurora")
        let reopened = ShaderPreferences.userDefaults(try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.lastShaderID(), "aurora")
        preferences.setLastShaderID(nil)
        XCTAssertNil(reopened.lastShaderID())
        let first = ShaderPreferences.inMemory()
        let second = ShaderPreferences.inMemory()
        first.setLastShaderID("waves")
        XCTAssertNil(second.lastShaderID())
    }

    private static let controllerPipeline = Task { @MainActor in
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try await ShaderCompiler(device: device).pipeline(for: TestCatalog.initialShader)
        return (device, pipeline)
    }

    private func controlledController(size: CGSize? = nil,
                                      preferences: ShaderPreferences = .inMemory(),
                                      clock: any Clock<Duration> = TestClock()) async throws -> (GameViewController, ControlledCompiler, any MTLRenderPipelineState) {
        let (device, pipeline) = try await Self.controllerPipeline.value
        let compiler = ControlledCompiler()
        addTeardownBlock { await compiler.cancelAll() }
        let controller = try await hostController(size: size, preferences: preferences, clock: clock, dependencies: {
            $0.metalDevice = device
            $0.shaderCompilerFactory = { _, _ in compiler }
        })
        if let refresh = controller.catalogRefreshTask {
            try await waitForAsync("Initial catalog check finishes before injecting updates") { await refresh.value }
        }
        return (controller, compiler, pipeline)
    }

    private func hostController(size: CGSize? = nil,
                                preferences: ShaderPreferences = .inMemory(),
                                clock: any Clock<Duration> = TestClock(),
                                dependencies: (inout DependencyValues) -> Void = { _ in },
                                factory: @escaping @MainActor @Sendable (MTKView) throws -> Renderer = RendererFactoryKey.liveValue) async throws -> GameViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: GameViewController.self))
        let controller = try withDependencies {
            $0.context = .test
            $0.catalogService = CatalogService.offline(initialCatalog: TestCatalog.catalog, storage: TestCatalog.storage)
            $0.rendererFactory = factory
            $0.shaderPreferences = preferences
            $0.continuousClock = clock
            $0.monotonicTime = { 0 }
            dependencies(&$0)
        } operation: {
            try XCTUnwrap(storyboard.instantiateInitialViewController() as? GameViewController)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var presenter = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow)?.rootViewController)
        while let presented = presenter.presentedViewController { presenter = presented }
        let hosted: UIViewController = size.map { LayoutHost(controller: controller, size: $0) } ?? controller
        hosted.modalPresentationStyle = .fullScreen
        addTeardownBlock { @MainActor in
            controller.hintTask?.cancel()
            controller.setSceneActive(false)
            controller.setSceneForeground(false)
            guard hosted.presentingViewController != nil else { return }
            let dismissed = XCTestExpectation(description: "Controller finishes disappearing")
            hosted.dismiss(animated: false) { dismissed.fulfill() }
            let result = await XCTWaiter.fulfillment(of: [dismissed], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        let appeared = XCTestExpectation(description: "Controller finishes appearing")
        presenter.present(hosted, animated: false) { appeared.fulfill() }
        try await waitForExpectation(appeared)
        hosted.view.layoutIfNeeded()
        if let host = hosted as? LayoutHost { host.configureSafeArea() }
        controller.view.layoutIfNeeded()
        return controller
    }

    private func waitForRequest(_ id: String, occurrence: Int? = nil, in compiler: ControlledCompiler) async throws {
        try await waitForAsync("Compiler receives \(id) request \(occurrence.map(String.init) ?? "next")") {
            await compiler.waitForRequest(id, occurrence: occurrence)
        }
    }

    private func waitForSelection(_ task: Task<Void, Never>) async throws {
        try await waitForAsync("Selection updates the controller") { await task.value }
    }

    private func waitForAsync(_ description: String, operation: @escaping @MainActor () async -> Void) async throws {
        let checkpoint = XCTestExpectation(description: description)
        let waiting = Task {
            await operation()
            checkpoint.fulfill()
        }
        defer { waiting.cancel() }
        try await waitForExpectation(checkpoint)
    }

    private func waitForExpectation(_ expectation: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, expectation.expectationDescription)
        guard result == .completed else { throw ControllerTestError.timedOut }
    }

    private func findView<T: UIView>(_ identifier: String, in controller: GameViewController) throws -> T {
        func search(_ view: UIView) -> T? {
            if view.accessibilityIdentifier == identifier, let found = view as? T { return found }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(search(controller.view), "Missing \(identifier)")
    }

    private func checkPickerLayout(_ controller: GameViewController, size: CGSize) throws -> CGRect {
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.view.bounds.size, size)
        XCTAssertEqual(controller.view.safeAreaInsets, UIEdgeInsets(top: 60, left: 90, bottom: 60, right: 90))
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        let layout = try XCTUnwrap(collection.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.itemSize, CGSize(width: 320, height: 232))
        XCTAssertGreaterThan(collection.bounds.height - collection.adjustedContentInset.top
                             - collection.adjustedContentInset.bottom, layout.itemSize.height)
        let first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let frame = first.convert(first.bounds, to: controller.view)
        let visible = collection.convert(collection.bounds, to: controller.view)
        let safe = controller.view.safeAreaLayoutGuide.layoutFrame
        let expanded = CGRect(x: frame.midX - first.bounds.width * 1.045 / 2,
                              y: frame.midY - first.bounds.height * 1.045 / 2,
                              width: first.bounds.width * 1.045, height: first.bounds.height * 1.045)
        XCTAssertGreaterThanOrEqual(expanded.minY, visible.minY)
        XCTAssertLessThanOrEqual(expanded.maxY, visible.maxY)
        XCTAssertTrue(safe.contains(expanded), "Focused card must fit the safe area: \(expanded), \(safe)")
        let status: UIView = try findView("shader-status-row", in: controller)
        XCTAssertGreaterThanOrEqual(status.bounds.height, 40)
        return visible
    }

    private func makeRenderer(view: MTKView,
                              compilerFactory: @escaping @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling = ShaderCompilerFactoryKey.liveValue,
                              now: @escaping @MainActor @Sendable () -> TimeInterval = { 0 }) throws -> Renderer {
        try withDependencies {
            $0.shaderCompilerFactory = compilerFactory
            $0.monotonicTime = now
        } operation: {
            try XCTUnwrap(Renderer(metalKitView: view))
        }
    }

    private func controlledRenderer() async throws -> (Renderer, ControlledCompiler, any MTLRenderPipelineState) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try await ShaderCompiler(device: device).pipeline(for: TestCatalog.initialShader)
        let compiler = ControlledCompiler()
        addTeardownBlock { await compiler.cancelAll() }
        let view = MTKView(frame: .zero, device: device)
        let renderer = try makeRenderer(view: view, compilerFactory: { _, _ in compiler })
        let initial = Task { try await renderer.select(TestCatalog.initialShader) }
        await compiler.waitForRequest("plasma")
        await compiler.complete("plasma", pipeline: pipeline)
        let activated = try await initial.value
        XCTAssertTrue(activated)
        return (renderer, compiler, pipeline)
    }

}

private actor ControlledCompiler: ShaderCompiling {
    private struct Request: Hashable {
        let id: String
        let occurrence: Int
    }
    private var counts: [String: Int] = [:]
    private var requests: [Request: CheckedContinuation<any MTLRenderPipelineState, any Error>] = [:]
    private var waiters: [Request: [CheckedContinuation<Void, Never>]] = [:]
    private var canceled = false

    func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState {
        guard !canceled else { throw CancellationError() }
        counts[shader.id, default: 0] += 1
        let request = Request(id: shader.id, occurrence: counts[shader.id]!)
        return try await withCheckedThrowingContinuation { continuation in
            requests[request] = continuation
            waiters.removeValue(forKey: request)?.forEach { $0.resume() }
        }
    }

    func requestCount(_ id: String) -> Int { counts[id, default: 0] }

    func waitForRequest(_ id: String, occurrence: Int? = nil) async {
        guard !canceled else { return }
        if let occurrence, counts[id, default: 0] >= occurrence { return }
        if occurrence == nil, requests.keys.contains(where: { $0.id == id }) { return }
        let request = Request(id: id, occurrence: occurrence ?? (counts[id, default: 0] + 1))
        await withCheckedContinuation { waiters[request, default: []].append($0) }
    }

    func complete(_ id: String, occurrence: Int? = nil, pipeline: any MTLRenderPipelineState) {
        guard let request = pendingRequest(id, occurrence: occurrence) else { return }
        requests.removeValue(forKey: request)?.resume(returning: pipeline)
    }

    func fail(_ id: String, occurrence: Int? = nil) {
        guard let request = pendingRequest(id, occurrence: occurrence) else { return }
        requests.removeValue(forKey: request)?.resume(throwing: ShaderCompilationError.missingFunction("fragmentShader"))
    }

    private func pendingRequest(_ id: String, occurrence: Int?) -> Request? {
        if let occurrence { return Request(id: id, occurrence: occurrence) }
        return requests.keys.filter { $0.id == id }.min { $0.occurrence < $1.occurrence }
    }

    func cancelAll() {
        canceled = true
        let pending = Array(requests.values)
        let waiting = waiters.values.flatMap { $0 }
        requests.removeAll()
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class LayoutHost: UIViewController {
    private let controller: GameViewController
    private let size: CGSize

    init(controller: GameViewController, size: CGSize) {
        self.controller = controller
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Layout hosts are created by tests.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controller.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            controller.view.widthAnchor.constraint(equalToConstant: size.width),
            controller.view.heightAnchor.constraint(equalToConstant: size.height)
        ])
        controller.didMove(toParent: self)
    }

    func configureSafeArea() {
        view.layoutIfNeeded()
        let inherited = controller.view.safeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, 60 - inherited.top),
                                                          left: max(0, 90 - inherited.left),
                                                          bottom: max(0, 60 - inherited.bottom),
                                                          right: max(0, 90 - inherited.right))
        view.layoutIfNeeded()
    }
}

@MainActor
private extension UIView {
    var subviewsRecursive: [UIView] { subviews + subviews.flatMap { $0.subviewsRecursive } }
}

private enum ControllerTestError: Error { case timedOut }

private actor ControllerNetworkCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
private final class PreferenceSpy {
    var id: String?
    var reads = 0
    var writes: [String?] = []

    init(id: String? = nil) { self.id = id }

    var client: ShaderPreferences {
        ShaderPreferences(lastShaderID: {
            self.reads += 1
            return self.id
        }, setLastShaderID: {
            self.id = $0
            self.writes.append($0)
        })
    }
}

@MainActor
private final class ControlledTime {
    var value: TimeInterval
    init(value: TimeInterval) { self.value = value }
}

@MainActor
extension HolodeckTests {
    private func recoveryClient(channel: TVRecoveryChannel = TVRecoveryChannel()) -> LocalCatalogClient {
        var dependencies = LocalClientDependencies()
        dependencies.usesSystemBrowser = false
        dependencies.readSecret = { _ in nil }; dependencies.writeSecret = { _, _ in }; dependencies.removeSecret = { _ in }
        dependencies.resolve = { _ in ResolvedMac(address: "192.168.1.2", port: 1234) }
        dependencies.transport = { mac, _, _, _ in
            channel.setMac(mac.id)
            return LocalClientTransport(channel: channel, fingerprint: { "test-pin" }, identityChanged: { false })
        }
        let client = LocalCatalogClient(testingNamespace: "tv-controller", dependencies: dependencies)
        addTeardownBlock { await client.stop() }
        return client
    }
    func testCatalogFailureRemainsPrimaryWhileConnectionStatusChanges() async throws {
        let (device, _) = try await Self.controllerPipeline.value
        let client = recoveryClient()
        let service = CatalogService(source: CatalogSource(kind: .standard) { _, _ in
            throw LocalCatalogError.invalidFile("catalog.json", "Broken catalog")
        }, storage: .disabled, usesLocalNetwork: true)
        let controller = try await hostController(dependencies: {
            $0.catalogService = service; $0.localCatalogClient = client; $0.metalDevice = device; $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue
        })
        let status: UILabel = try findView("shader-status", in: controller)
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in status.text == "catalog.json: Broken catalog" }, object: controller)
        try await waitForExpectation(failed)
        var state = LocalClientState(); state.status = .connected("Test Mac")
        controller.applyLocalState(state)
        let connection: UILabel = try findView("mac-connection-status", in: controller)
        XCTAssertEqual(connection.text, "Connected to Test Mac")
        XCTAssertEqual(status.text, "catalog.json: Broken catalog")
        state.status = .permissionDenied; controller.applyLocalState(state)
        XCTAssertEqual(status.text, "catalog.json: Broken catalog")
    }

    func testDirectionalUserFocusTakesOwnershipDuringPendingRestoration() {
        var restoration = EmptyPickerFocusRestoration(pending: true)
        XCTAssertFalse(restoration.accepts(active: false, preferred: false, heading: .right))
        XCTAssertFalse(restoration.accepts(active: true, preferred: false, heading: []))
        XCTAssertTrue(restoration.pending)
        XCTAssertTrue(restoration.accepts(active: true, preferred: false, heading: .right))
        XCTAssertFalse(restoration.pending)
        // Once navigation wins, later focus updates are remembered normally.
        XCTAssertTrue(restoration.accepts(active: true, preferred: false, heading: []))
        restoration.pending = true
        XCTAssertTrue(restoration.accepts(active: true, preferred: true, heading: []))
        XCTAssertFalse(restoration.pending)
    }

    func testFocusRestorationRecognizesEmptyLocalPickerControlsAndExistingRootRules() async throws {
        let (device, _) = try await Self.controllerPipeline.value
        for local in [false, true] {
            let client = recoveryClient()
            let service = CatalogService(source: .unavailable, storage: .disabled, usesLocalNetwork: local)
            let controller = try await hostController(dependencies: {
                $0.catalogService = service; $0.localCatalogClient = client; $0.metalDevice = device
                $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue
            })
            controller.openPickerFromRemote()
            let change: UIButton = try findView("change-mac", in: controller)
            let check: UIButton = try findView("check-scene-updates", in: controller)
            XCTAssertEqual(controller.hasRestoredFocus(change), local)
            XCTAssertFalse(controller.hasRestoredFocus(check))
            XCTAssertEqual(controller.hasRestoredFocus(controller.view), !local)
            XCTAssertFalse(controller.hasRestoredFocus(UIView()))
            XCTAssertFalse(controller.hasRestoredFocus(nil))
            controller.rememberPickerFocus(check)
            controller.rememberPickerFocus(nil)
            if local {
                XCTAssertTrue(controller.preferredFocusEnvironments.first === check)
                controller.setSceneActive(false)
                controller.rememberPickerFocus(change)
                XCTAssertTrue(controller.preferredFocusEnvironments.first === check)
                XCTAssertFalse(controller.hasRestoredFocus(change))
                XCTAssertTrue(controller.hasRestoredFocus(check))
                controller.setSceneActive(true)
                XCTAssertTrue(controller.preferredFocusEnvironments.first === check)
                controller.rememberPickerFocus(change, heading: .right)
                XCTAssertTrue(controller.preferredFocusEnvironments.first === change)
                controller.setSceneActive(false)
                controller.rememberPickerFocus(check)
                XCTAssertTrue(controller.preferredFocusEnvironments.first === change)
                controller.setSceneActive(true)
                XCTAssertTrue(controller.preferredFocusEnvironments.first === change)
            }
            else { XCTAssertTrue(controller.preferredFocusEnvironments.first === controller.view) }
            controller.closePickerFromRemote()
            XCTAssertTrue(controller.hasRestoredFocus(controller.view))
            XCTAssertFalse(controller.hasRestoredFocus(check))
            controller.openPickerFromRemote()
            XCTAssertTrue(controller.preferredFocusEnvironments.first === (local ? change : controller.view))
        }
        let controller = try await hostController(dependencies: {
            $0.metalDevice = device; $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue
        })
        await controller.shaderSelectionTask?.value
        controller.openPickerFromRemote()
        let cards: UICollectionView = try findView("shader-cards", in: controller)
        XCTAssertTrue(controller.hasRestoredFocus(cards))
        XCTAssertFalse(controller.hasRestoredFocus(controller.view))
        let unavailable = try await hostController(dependencies: {
            $0.catalogService = CatalogService(storage: .disabled, usesLocalNetwork: true)
            $0.localCatalogClient = recoveryClient()
        }, factory: { _ in throw RendererStartupError.metalUnavailable })
        let control: UIButton = try findView("change-mac", in: unavailable)
        XCTAssertTrue(unavailable.hasRestoredFocus(unavailable.view))
        XCTAssertFalse(unavailable.hasRestoredFocus(control))
    }
    func testTemporaryInactivityPreservesPairingWhileBackgroundStopsIt() async throws {
        let (device, _) = try await Self.controllerPipeline.value
        let channel = TVRecoveryChannel(); let client = recoveryClient(channel: channel)
        let service = CatalogService(initialCatalog: TestCatalog.localCatalog, source: client.source, storage: .disabled, usesLocalNetwork: true)
        let controller = try await hostController(dependencies: {
            $0.catalogService = service; $0.localCatalogClient = client; $0.metalDevice = device; $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue
        })
        let deadline = ContinuousClock.now + .seconds(3)
        while await client.currentBrowserID == nil {
            guard ContinuousClock.now < deadline else { throw LocalCatalogError.timeout }; await Task.yield()
        }
        let browser = await client.currentBrowserID
        let mac = LocalMac(id: UUID().uuidString, name: "Test Mac", endpoint: .service(name: "Test",
            type: LocalProtocol.serviceType, domain: "local.", interface: nil), interface: nil, version: LocalProtocol.version)
        await client.discovered([mac], id: try XCTUnwrap(browser), sequence: 1)
        while true {
            if case .awaitingApproval = await client.currentState.status { break }
            guard ContinuousClock.now < deadline else { throw LocalCatalogError.timeout }; await Task.yield()
        }
        let pairing = await client.currentState.status
        controller.setSceneActive(false); controller.setSceneActive(true)
        let resumed = await client.currentState.status
        XCTAssertEqual(resumed, pairing); XCTAssertEqual(channel.cancellations, 0)
        XCTAssertTrue(controller.sceneIsForeground)
        controller.setSceneForeground(false)
        while await client.currentBrowserID != nil || channel.cancellations == 0 {
            guard ContinuousClock.now < deadline else { throw LocalCatalogError.timeout }; await Task.yield()
        }
        XCTAssertFalse(controller.sceneIsForeground)
    }
    func testAutomaticMacChooserDefersBehindModalAndClosesWhenRememberedMacReturns() async throws {
        let (device, _) = try await Self.controllerPipeline.value
        let controller = try await hostController(clock: ContinuousClock(), dependencies: { $0.metalDevice = device; $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue })
        await controller.shaderSelectionTask?.value
        let other = UIAlertController(title: "Other modal", message: nil, preferredStyle: .alert)
        other.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(other, animated: false)
        var choice = LocalClientState(); choice.status = .chooseMac; choice.macChoiceID = UUID()
        controller.applyLocalState(choice)
        XCTAssertTrue(controller.presentedViewController === other)
        let disappeared = XCTestExpectation(description: "Other modal dismissed")
        other.dismiss(animated: false) { disappeared.fulfill() }
        try await waitForExpectation(disappeared)
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (controller.presentedViewController as? UIAlertController)?.title == "Choose a Mac"
                && controller.presentedViewController?.isBeingPresented == false
        }, object: controller)
        try await waitForExpectation(presented)
        var returning = LocalClientState(); returning.status = .connecting
        controller.applyLocalState(returning)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in controller.presentedViewController == nil }, object: controller)
        try await waitForExpectation(dismissed)
    }
    func testCanceledMacChooserDoesNotReopenForSameAbsenceEpisode() async throws {
        let (device, _) = try await Self.controllerPipeline.value
        let controller = try await hostController(clock: ContinuousClock(), dependencies: { $0.metalDevice = device; $0.shaderCompilerFactory = ShaderCompilerFactoryKey.liveValue })
        await controller.shaderSelectionTask?.value
        var choice = LocalClientState(); choice.status = .chooseMac; choice.macChoiceID = UUID()
        controller.applyLocalState(choice)
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.presentedViewController is UIAlertController && controller.presentedViewController?.isBeingPresented == false
        }, object: controller)
        try await waitForExpectation(presented)
        controller.cancelMacChoice()
        let dismissed = XCTestExpectation(description: "Canceled chooser dismissed")
        controller.presentedViewController?.dismiss(animated: false) { dismissed.fulfill() }
        try await waitForExpectation(dismissed)
        controller.applyLocalState(choice)
        await Task.yield()
        XCTAssertNil(controller.presentedViewController)
    }
}

private nonisolated final class TVRecoveryChannel: LocalRequestConnection, @unchecked Sendable {
    private let lock = NSLock(); private var macID = ""; private var canceled = 0
    var cancellations: Int { lock.withLock { canceled } }
    func setMac(_ id: String) { lock.withLock { macID = id } }
    func start() async throws {}
    func pairingCode() async throws -> String { "123456" }
    func cancel() { lock.withLock { canceled += 1 } }
    func exchange(_ packet: LocalPacket) async throws -> LocalPacket {
        var message = LocalMessage(operation: "ok")
        if packet.message.operation == "hello" { message.serverID = lock.withLock { macID } }
        else { message.operation = "pending" }
        return LocalPacket(message: message)
    }
}

@MainActor private final class DeliverySceneRenderer: SceneRendering {
    var activeShader: ShaderDefinition?
    var mode = "success"
    func select(_ shader: ShaderDefinition) async throws -> Bool {
        if mode == "activation" { throw ShaderCompilationError.missingFunction("fragmentShader") }
        if mode == "superseded" { return false }
        activeShader = shader; return true
    }
    func cancelPendingSelection() {}
    func setActive(_ active: Bool) {}
}
