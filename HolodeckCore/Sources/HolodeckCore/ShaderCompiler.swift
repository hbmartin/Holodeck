import Metal

nonisolated public enum ShaderCompilationError: LocalizedError {
    case missingFunction(String)
    case invalidUniformLayout
    case pipelineInterface(NSError)

    public static func isSourceDefect(_ error: Error) -> Bool {
        if error is ShaderCompilationError { return true }
        let native = error as NSError
        return native.domain == MTLLibraryErrorDomain && native.code == MTLLibraryError.compileFailure.rawValue
    }

    /// Driver error domains/codes vary by GPU. Only known interface diagnostics are source defects.
    static func pipelineError(_ error: Error) -> Error {
        let native = error as NSError, diagnostic = native.localizedDescription.lowercased()
        if diagnostic.contains("fragment input"),
           diagnostic.contains("mismatching vertex shader output") || diagnostic.contains("not written by vertex shader") ||
           diagnostic.contains("not found in vertex shader output") {
            return ShaderCompilationError.pipelineInterface(native)
        }
        return error
    }

    public var errorDescription: String? {
        switch self {
        case .pipelineInterface(let error): return error.localizedDescription
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
    do { return try device.makeRenderPipelineState(descriptor: descriptor) }
    catch { throw ShaderCompilationError.pipelineError(error) }
}
