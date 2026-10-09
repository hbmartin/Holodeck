import XCTest
import MetalKit
import Dependencies
import Clocks
import ConcurrencyExtras
@testable import Holodeck

@MainActor
final class HolodeckTests: XCTestCase {
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
        controller.applyCatalog(refreshed)
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
        controller.applyCatalog(refreshed)
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

    func testUniformLayout() {
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.size, 16)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.stride, 16)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.offset(of: \.resolution), 0)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.offset(of: \.time), 8)
        XCTAssertEqual(MemoryLayout<ShaderUniforms>.offset(of: \.padding), 12)
    }

    func testClockExcludesInactiveTimeAndResets() {
        var clock = ShaderClock()
        clock.reset(at: 10, running: true)
        XCTAssertEqual(clock.elapsed(at: 12), 2)
        clock.setRunning(false, at: 13)
        clock.setRunning(false, at: 15)
        XCTAssertEqual(clock.elapsed(at: 100), 3)
        clock.setRunning(true, at: 100)
        clock.setRunning(true, at: 101)
        XCTAssertEqual(clock.elapsed(at: 102), 5)
        clock.reset(at: 103, running: false)
        XCTAssertEqual(clock.elapsed(at: 200), 0)
        clock.setRunning(true, at: 200)
        XCTAssertEqual(clock.elapsed(at: 201), 1)
    }

    func testCatalog() {
        XCTAssertEqual(TestCatalog.shaders.count, 8)
        XCTAssertEqual(Set(TestCatalog.shaders.map(\.id)).count, 8)
        XCTAssertEqual(TestCatalog.shaders.filter { $0.category == .procedural }.count, 5)
        XCTAssertEqual(TestCatalog.shaders.filter { $0.category == .material }.count, 3)
        XCTAssertEqual(TestCatalog.initialShader.id, "plasma")
    }

    func testEveryShaderCompilesRendersAndAnimates() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device, pixelFormat: .rgba32Float)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var materials: [[Float]] = []
        for shader in TestCatalog.shaders {
            let pipeline = try await compiler.pipeline(for: shader)
            let first = try render(device: device, queue: queue, pipeline: pipeline, time: 0)
            let later = try render(device: device, queue: queue, pipeline: pipeline, time: 6)
            XCTAssertTrue(first.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, shader.title)
            XCTAssertTrue(later.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, shader.title)
            XCTAssertTrue(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 1 },
                          "\(shader.title) must cover every pixel, including the screen edges")
            let red = stride(from: 0, to: first.count, by: 4).map { first[$0] }
            XCTAssertGreaterThan((red.max() ?? 0) - (red.min() ?? 0), 0.02, shader.title)
            XCTAssertNotEqual(first, later, "\(shader.title) should animate")
            attachImage(first, name: shader.title)
            if shader.category == .material { materials.append(first) }
        }
        XCTAssertNotEqual(materials[0], materials[1])
        XCTAssertNotEqual(materials[1], materials[2])
        XCTAssertNotEqual(materials[0], materials[2])
    }

    func testPipelineCache() async throws {
        let compiler = ShaderCompiler(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = try await compiler.pipeline(for: TestCatalog.initialShader)
        let again = try await compiler.pipeline(for: TestCatalog.initialShader)
        XCTAssertTrue(first === again)
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
            $0.catalogService = CatalogService(storage: TestCatalog.storage, enabled: false)
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

    private let width = 640
    private let height = 360

    private func render(device: any MTLDevice, queue: any MTLCommandQueue,
                        pipeline: any MTLRenderPipelineState, time: Float) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 0)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = ShaderUniforms(resolution: SIMD2(Float(width), Float(height)), time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU render failed")
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    private func attachImage(_ pixels: [Float], name: String) {
        let bytes: [UInt8] = pixels.enumerated().map { index, value in
            if index % 4 == 3 { return 255 }
            let linear = max(0, min(value.isFinite ? value : 0, 1))
            let srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
            return UInt8(max(0, min(srgb * 255, 255)))
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let attachment = XCTAttachment(data: UIImage(cgImage: image).pngData()!, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
