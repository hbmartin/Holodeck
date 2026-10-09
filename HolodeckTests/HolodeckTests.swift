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
}
