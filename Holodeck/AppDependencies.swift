import Dependencies
import Foundation
import IssueReporting
import MetalKit
import QuartzCore

nonisolated struct ShaderPreferences: Sendable {
    var lastShaderID: @MainActor @Sendable () -> String?
    var setLastShaderID: @MainActor @Sendable (String?) -> Void

    private static let key = "holodeck.lastShaderID"

    static let live = Self(
        lastShaderID: { UserDefaults.standard.string(forKey: key) },
        setLastShaderID: { UserDefaults.standard.set($0, forKey: key) }
    )

    @MainActor
    static func userDefaults(_ defaults: UserDefaults) -> Self {
        Self(
            lastShaderID: { defaults.string(forKey: key) },
            setLastShaderID: { defaults.set($0, forKey: key) }
        )
    }

    static func inMemory(initialShaderID: String? = nil) -> Self {
        let storage = MemoryStorage(initialShaderID: initialShaderID)
        return Self(lastShaderID: { storage.id }, setLastShaderID: { storage.id = $0 })
    }

    @MainActor
    private final class MemoryStorage {
        var id: String?

        nonisolated init(initialShaderID: String?) { id = initialShaderID }
    }
}

extension DependencyValues {
    var metalDevice: (any MTLDevice)? {
        get { self[MetalDeviceKey.self] }
        set { self[MetalDeviceKey.self] = newValue }
    }

    var shaderCompilerFactory: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling {
        get { self[ShaderCompilerFactoryKey.self] }
        set { self[ShaderCompilerFactoryKey.self] = newValue }
    }

    var rendererFactory: @MainActor @Sendable (MTKView) throws -> Renderer {
        get { self[RendererFactoryKey.self] }
        set { self[RendererFactoryKey.self] = newValue }
    }

    var monotonicTime: @MainActor @Sendable () -> TimeInterval {
        get { self[MonotonicTimeKey.self] }
        set { self[MonotonicTimeKey.self] = newValue }
    }

    var shaderPreferences: ShaderPreferences {
        get { self[ShaderPreferencesKey.self] }
        set { self[ShaderPreferencesKey.self] = newValue }
    }
}

nonisolated enum MetalDeviceKey: DependencyKey {
    static let liveValue = MTLCreateSystemDefaultDevice()
    static var testValue: (any MTLDevice)? {
        if shouldReportUnimplemented { reportIssue("Override metalDevice before using Metal in a test.") }
        return nil
    }
}

nonisolated enum ShaderCompilerFactoryKey: DependencyKey {
    static let liveValue: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling = {
        ShaderCompiler(device: $0, pixelFormat: $1)
    }
    static let testValue: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling = { _, _ in
        reportIssue("Override shaderCompilerFactory before creating a renderer in a test.")
        return UnimplementedShaderCompiler()
    }
}

nonisolated enum RendererFactoryKey: DependencyKey {
    static let liveValue: @MainActor @Sendable (MTKView) throws -> Renderer = { view in
        @Dependency(\.metalDevice) var device
        guard let device else { throw RendererStartupError.metalUnavailable }
        view.device = device
        guard let renderer = Renderer(metalKitView: view) else { throw RendererStartupError.initializationFailed }
        return renderer
    }
    static let testValue: @MainActor @Sendable (MTKView) throws -> Renderer = { _ in
        reportIssue("Override rendererFactory before starting a controller in a test.")
        throw RendererStartupError.initializationFailed
    }
}

nonisolated enum MonotonicTimeKey: DependencyKey {
    static let liveValue: @MainActor @Sendable () -> TimeInterval = { CACurrentMediaTime() }
    static let testValue: @MainActor @Sendable () -> TimeInterval = {
        reportIssue("Override monotonicTime before advancing renderer time in a test.")
        return 0
    }
}

nonisolated enum ShaderPreferencesKey: DependencyKey {
    static let liveValue = ShaderPreferences.live
    static let previewValue = ShaderPreferences.inMemory()
    static let testValue = ShaderPreferences(
        lastShaderID: {
            reportIssue("Override shaderPreferences before reading preferences in a test.")
            return nil
        },
        setLastShaderID: { _ in reportIssue("Override shaderPreferences before saving preferences in a test.") }
    )
}

nonisolated private struct UnimplementedShaderCompiler: ShaderCompiling {
    func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState {
        throw RendererStartupError.initializationFailed
    }
}
