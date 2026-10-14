#if os(macOS)
import Foundation
import Metal

public struct ShaderToolError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }
    public init(_ description: String) { self.description = description }
}

public func validateRenderDimensions(width: Int, height: Int) throws {
    guard (1...8192).contains(width) else { throw ShaderToolError("Invalid width") }
    guard (1...8192).contains(height) else { throw ShaderToolError("Invalid height") }
    guard width * height <= 16_777_216 else { throw ShaderToolError("Render exceeds 16 megapixels") }
}

public func validateRenderTime(_ time: Float) throws {
    guard time.isFinite, time >= 0 else { throw ShaderToolError("Invalid time") }
}

public final class MetalContext {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary

    public convenience init(sourcePath: String) throws {
        try self.init(source: String(contentsOfFile: sourcePath, encoding: .utf8))
    }

    public init(source: String) throws {
        try ShaderUniforms.validateLayout()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ShaderToolError("Metal device unavailable")
        }
        self.device = device
        self.queue = queue
        library = try device.makeLibrary(source: source, options: nil)
    }
}

public struct RenderedFrame: Sendable {
    public let pixels: Data
    public let bytesPerRow: Int
    public let gpuMilliseconds: Double
}

public final class OffscreenRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    public init(context: MetalContext, width: Int, height: Int, pixelFormat: MTLPixelFormat) throws {
        try validateRenderDimensions(width: width, height: height)
        let bytesPerPixel: Int
        switch pixelFormat {
        case .bgra8Unorm_srgb: bytesPerPixel = 4
        case .rgba32Float: bytesPerPixel = 16
        default: throw ShaderToolError("Unsupported offscreen pixel format: \(pixelFormat)")
        }
        self.context = context
        self.width = width
        self.height = height
        bytesPerRow = width * bytesPerPixel
        pipeline = try makeShaderPipeline(device: context.device, library: context.library, pixelFormat: pixelFormat)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        td.storageMode = .shared
        td.usage = [.renderTarget]
        guard let texture = context.device.makeTexture(descriptor: td) else {
            throw ShaderToolError("Unable to allocate render target")
        }
        self.texture = texture
    }

    public func render(time: Float) throws -> RenderedFrame {
        try validateRenderTime(time)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let command = context.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw ShaderToolError("Unable to create render command or encoder")
        }
        var uniforms = ShaderUniforms(resolution: SIMD2(Float(width), Float(height)), time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw ShaderToolError(command.error?.localizedDescription ?? "Rendering failed")
        }
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return RenderedFrame(pixels: pixels, bytesPerRow: bytesPerRow,
                             gpuMilliseconds: (command.gpuEndTime - command.gpuStartTime) * 1000)
    }
}
#endif
