import XCTest
import MetalKit
@testable import Holodeck

@MainActor
final class HolodeckTests: XCTestCase {
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
        XCTAssertEqual(ShaderCatalog.shaders.count, 8)
        XCTAssertEqual(Set(ShaderCatalog.shaders.map(\.id)).count, 8)
        XCTAssertEqual(ShaderCatalog.shaders.filter { $0.category == .procedural }.count, 5)
        XCTAssertEqual(ShaderCatalog.shaders.filter { $0.category == .material }.count, 3)
        XCTAssertEqual(ShaderCatalog.initialShader.id, "plasma")
    }

    func testEveryShaderCompilesRendersAndAnimates() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device, pixelFormat: .rgba32Float)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var materials: [[Float]] = []
        for shader in ShaderCatalog.shaders {
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
        let first = try await compiler.pipeline(for: ShaderCatalog.initialShader)
        let again = try await compiler.pipeline(for: ShaderCatalog.initialShader)
        XCTAssertTrue(first === again)
    }

    func testInvalidSourceAndMissingEntryPointPreserveActiveShader() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(Renderer(metalKitView: view))
        let activated = try await renderer.select(ShaderCatalog.initialShader)
        XCTAssertTrue(activated)
        let missingFragment = ShaderCatalog.initialShader.source.replacingOccurrences(
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
        let older = ShaderCatalog.shaders[1], newer = ShaderCatalog.shaders[2]
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
        let secondTask = Task { try await renderer.select(ShaderCatalog.shaders[3]) }
        await compiler.waitForRequest(ShaderCatalog.shaders[3].id)
        await compiler.complete(older.id, pipeline: pipeline)
        let staleActivated = try await firstTask.value
        XCTAssertFalse(staleActivated)
        await compiler.complete(ShaderCatalog.shaders[3].id, pipeline: pipeline)
        let latestActivated = try await secondTask.value
        XCTAssertTrue(latestActivated)
        XCTAssertEqual(renderer.activeShader?.id, "kaleidoscope")
    }

    func testDismissingPendingSelectionAndSceneActivity() async throws {
        let (renderer, compiler, pipeline) = try await controlledRenderer()
        let shader = ShaderCatalog.shaders[1]
        let pending = Task { try await renderer.select(shader) }
        await compiler.waitForRequest(shader.id)
        renderer.cancelPendingSelection()
        await compiler.complete(shader.id, pipeline: pipeline)
        let activated = try await pending.value
        XCTAssertFalse(activated)
        XCTAssertEqual(renderer.activeShader?.id, "plasma")

        let view = MTKView(frame: .zero, device: renderer.device)
        let lifecycleRenderer = try XCTUnwrap(Renderer(metalKitView: view))
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

        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        let hint: UIView = try findView("shader-hint", in: controller)
        let status: UILabel = try findView("shader-status", in: controller)
        XCTAssertTrue(picker.isHidden)
        XCTAssertFalse(hint.isHidden)
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
            let controller = try await hostController { _ in throw error }
            let picker: UIView = try findView("shader-picker", in: controller)
            let hint: UIView = try findView("shader-hint", in: controller)
            let status: UILabel = try findView("shader-status", in: controller)
            let spinner: UIActivityIndicatorView = try findView("shader-loading", in: controller)
            let collection: UICollectionView = try findView("shader-cards", in: controller)
            XCTAssertNil(controller.shaderSelectionTask)
            for _ in 0..<3 {
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
        let sizes = [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)]
        let (controller, compiler, pipeline) = try await controlledController()
        try await waitForRequest("plasma", in: compiler)
        let initial = try XCTUnwrap(controller.shaderSelectionTask)
        controller.openPickerFromRemote()
        let loading = try sizes.map { try checkPickerLayout(controller, size: $0) }
        await compiler.complete("plasma", pipeline: pipeline)
        try await waitForSelection(initial)
        for (index, size) in sizes.enumerated() {
            XCTAssertEqual(try checkPickerLayout(controller, size: size), loading[index])
        }

        let unavailable = try await hostController { _ in throw RendererStartupError.metalUnavailable }
        for (index, size) in sizes.enumerated() {
            XCTAssertEqual(try checkPickerLayout(unavailable, size: size), loading[index])
        }
    }

    private func controlledController() async throws -> (GameViewController, ControlledCompiler, any MTLRenderPipelineState) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try await ShaderCompiler(device: device).pipeline(for: ShaderCatalog.initialShader)
        let compiler = ControlledCompiler()
        addTeardownBlock { await compiler.cancelAll() }
        let controller = try await hostController { view in
            view.device = device
            return try XCTUnwrap(Renderer(metalKitView: view, compiler: compiler))
        }
        return (controller, compiler, pipeline)
    }

    private func hostController(factory: @escaping @MainActor (MTKView) throws -> Renderer) async throws -> GameViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: GameViewController.self))
        let controller = try XCTUnwrap(storyboard.instantiateInitialViewController() as? GameViewController)
        controller.rendererFactory = factory
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var presenter = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow)?.rootViewController)
        while let presented = presenter.presentedViewController { presenter = presented }
        controller.modalPresentationStyle = .fullScreen
        let appeared = XCTestExpectation(description: "Controller finishes appearing")
        presenter.present(controller, animated: false) { appeared.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [appeared], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw ControllerTestError.timedOut }
        controller.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.setSceneActive(false)
            let dismissed = XCTestExpectation(description: "Controller finishes disappearing")
            controller.dismiss(animated: false) { dismissed.fulfill() }
            let result = await XCTWaiter.fulfillment(of: [dismissed], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        return controller
    }

    private func waitForRequest(_ id: String, in compiler: ControlledCompiler) async throws {
        let checkpoint = XCTestExpectation(description: "Compiler receives \(id)")
        let waiting = Task {
            await compiler.waitForRequest(id)
            checkpoint.fulfill()
        }
        defer { waiting.cancel() }
        let result = await XCTWaiter.fulfillment(of: [checkpoint], timeout: 5)
        XCTAssertEqual(result, .completed)
        guard result == .completed else { throw ControllerTestError.timedOut }
    }

    private func waitForSelection(_ task: Task<Void, Never>) async throws {
        let finished = XCTestExpectation(description: "Selection updates the controller")
        let waiting = Task {
            await task.value
            finished.fulfill()
        }
        defer { waiting.cancel() }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, .completed)
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
        controller.view.bounds.size = size
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let collection: UICollectionView = try findView("shader-cards", in: controller)
        let layout = try XCTUnwrap(collection.collectionViewLayout as? UICollectionViewFlowLayout)
        XCTAssertEqual(layout.itemSize, CGSize(width: 320, height: 232))
        XCTAssertGreaterThan(collection.bounds.height - collection.adjustedContentInset.top
                             - collection.adjustedContentInset.bottom, layout.itemSize.height)
        let first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
        let frame = first.convert(first.bounds, to: controller.view)
        let visible = collection.convert(collection.bounds, to: controller.view)
        let expandedHeight = first.bounds.height * 1.045
        XCTAssertGreaterThanOrEqual(frame.midY - expandedHeight / 2, visible.minY)
        XCTAssertLessThanOrEqual(frame.midY + expandedHeight / 2, visible.maxY)
        let status: UIView = try findView("shader-status-row", in: controller)
        XCTAssertGreaterThanOrEqual(status.bounds.height, 40)
        return visible
    }

    private func controlledRenderer() async throws -> (Renderer, ControlledCompiler, any MTLRenderPipelineState) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try await ShaderCompiler(device: device).pipeline(for: ShaderCatalog.initialShader)
        let compiler = ControlledCompiler()
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(Renderer(metalKitView: view, compiler: compiler))
        let initial = Task { try await renderer.select(ShaderCatalog.initialShader) }
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
    private var requests: [String: CheckedContinuation<any MTLRenderPipelineState, any Error>] = [:]
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState {
        try await withCheckedThrowingContinuation { continuation in
            requests[shader.id] = continuation
            waiters.removeValue(forKey: shader.id)?.resume()
        }
    }

    func waitForRequest(_ id: String) async {
        if requests[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func complete(_ id: String, pipeline: any MTLRenderPipelineState) {
        requests.removeValue(forKey: id)?.resume(returning: pipeline)
    }

    func fail(_ id: String) {
        requests.removeValue(forKey: id)?.resume(throwing: ShaderCompilationError.missingFunction("fragmentShader"))
    }

    func cancelAll() {
        let pending = Array(requests.values)
        let waiting = Array(waiters.values)
        requests.removeAll()
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
        waiting.forEach { $0.resume() }
    }
}

private enum ControllerTestError: Error { case timedOut }
