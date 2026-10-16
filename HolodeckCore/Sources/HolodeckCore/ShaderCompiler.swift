import Metal

nonisolated public enum ShaderCompilationError: LocalizedError {
    case missingFunction(String)
    case invalidUniformLayout

    public static func isSourceDefect(_ error: Error) -> Bool {
        if error is ShaderCompilationError { return true }
        let native = error as NSError
        return native.domain == MTLLibraryErrorDomain && native.code == MTLLibraryError.compileFailure.rawValue
    }

    public var errorDescription: String? {
        switch self {
        case .invalidUniformLayout: return "Uniforms must match the 16-byte buffer-0 contract"
        case .missingFunction(let name): return "The shader is missing its \(name) entry point."
        }
    }
}

public protocol ShaderCompiling: Sendable {
    func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState
}

/// Its actor executor keeps synchronous Metal compilation away from UIKit and drawing.
public actor ShaderCompiler: ShaderCompiling {
    private let device: any MTLDevice
    private let pixelFormat: MTLPixelFormat
    private var pipelines: [String: any MTLRenderPipelineState] = [:]

    public init(device: any MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) {
        self.device = device
        self.pixelFormat = pixelFormat
    }

    public func pipeline(for shader: ShaderDefinition) throws -> any MTLRenderPipelineState {
        let cacheKey = shader.id + ":" + shader.sourceHash
        if let cached = pipelines[cacheKey] { return cached }
        let library = try device.makeLibrary(source: shader.source, options: nil)
        let pipeline = try makeShaderPipeline(device: device, library: library, pixelFormat: pixelFormat, label: shader.title)
        pipelines[cacheKey] = pipeline
        return pipeline
    }
}

nonisolated func makeShaderPipeline(device: any MTLDevice, library: any MTLLibrary,
                               pixelFormat: MTLPixelFormat, label: String? = nil) throws -> any MTLRenderPipelineState {
    guard let vertex = library.makeFunction(name: "vertexShader") else {
        throw ShaderCompilationError.missingFunction("vertexShader")
    }
    guard let fragment = library.makeFunction(name: "fragmentShader") else {
        throw ShaderCompilationError.missingFunction("fragmentShader")
    }
    let descriptor = MTLRenderPipelineDescriptor()
    if let label { descriptor.label = label }
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = pixelFormat
    descriptor.rasterSampleCount = 1
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
