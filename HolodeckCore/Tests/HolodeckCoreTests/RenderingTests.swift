import XCTest
import MetalKit
import ImageIO
@testable import HolodeckCore

@MainActor
final class RenderingTests: XCTestCase {
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
    func testLivePublishedCatalogCompilesRendersAndAnimates() async throws {
        guard ProcessInfo.processInfo.environment["HOLODECK_LIVE_CATALOG"] == "1" else {
            throw XCTSkip("Set HOLODECK_LIVE_CATALOG=1 to verify the current published repository.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CatalogService(storage: .disk(at: directory))
        let downloaded = try await service.refresh(force: true)
        let snapshot = try XCTUnwrap(downloaded)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let compiler = ShaderCompiler(device: device, pixelFormat: .rgba32Float)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for shader in snapshot.shaders {
            let pipeline = try await compiler.pipeline(for: shader)
            let first = try render(device: device, queue: queue, pipeline: pipeline, time: 0)
            let later = try render(device: device, queue: queue, pipeline: pipeline, time: 6)
            XCTAssertTrue(first.allSatisfy { $0.isFinite && (0...1).contains($0) }, shader.title)
            XCTAssertTrue(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 1 }, shader.title)
            XCTAssertNotEqual(first, later, shader.title)
            let preview = try XCTUnwrap(shader.preview)
            let image = try await service.preview(preview)
            XCTAssertEqual(CatalogHash.sha256(image), preview.hash)
            attachImage(first, name: "Published-" + shader.title)
        }
        print("Verified \(snapshot.shaders.count) published scenes at \(snapshot.publicationRevision)")
    }

    func testPipelineCache() async throws {
        let compiler = ShaderCompiler(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = try await compiler.pipeline(for: TestCatalog.initialShader)
        let again = try await compiler.pipeline(for: TestCatalog.initialShader)
        XCTAssertTrue(first === again)
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
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let attachment = XCTAttachment(data: png as Data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
