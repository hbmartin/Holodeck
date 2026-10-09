import Dependencies
import Foundation
import IssueReporting
import MetalKit
import QuartzCore

nonisolated public enum RendererStartupError: LocalizedError {
    case metalUnavailable, initializationFailed
    public var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "Metal rendering is unavailable on this device."
        case .initializationFailed: return "The renderer could not start. Relaunch Holodeck to try again."
        }
    }
}

nonisolated public struct ShaderPreferences: Sendable {
    public var lastShaderID: @MainActor @Sendable () -> String?
    public var setLastShaderID: @MainActor @Sendable (String?) -> Void

    public init(lastShaderID: @escaping @MainActor @Sendable () -> String?,
                setLastShaderID: @escaping @MainActor @Sendable (String?) -> Void) {
        self.lastShaderID = lastShaderID
        self.setLastShaderID = setLastShaderID
    }

    private static let key = "holodeck.lastShaderID"

    public static let live = Self(
        lastShaderID: { UserDefaults.standard.string(forKey: key) },
        setLastShaderID: { UserDefaults.standard.set($0, forKey: key) }
    )

    @MainActor
    public static func userDefaults(_ defaults: UserDefaults) -> Self {
        Self(
            lastShaderID: { defaults.string(forKey: key) },
            setLastShaderID: { defaults.set($0, forKey: key) }
        )
    }

    public static func inMemory(initialShaderID: String? = nil) -> Self {
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
    public var metalDevice: (any MTLDevice)? {
        get { self[MetalDeviceKey.self] }
        set { self[MetalDeviceKey.self] = newValue }
    }

    public var shaderCompilerFactory: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling {
        get { self[ShaderCompilerFactoryKey.self] }
        set { self[ShaderCompilerFactoryKey.self] = newValue }
    }

    public var rendererFactory: @MainActor @Sendable (MTKView) throws -> Renderer {
        get { self[RendererFactoryKey.self] }
        set { self[RendererFactoryKey.self] = newValue }
    }

    public var monotonicTime: @MainActor @Sendable () -> TimeInterval {
        get { self[MonotonicTimeKey.self] }
        set { self[MonotonicTimeKey.self] = newValue }
    }

    public var shaderPreferences: ShaderPreferences {
        get { self[ShaderPreferencesKey.self] }
        set { self[ShaderPreferencesKey.self] = newValue }
    }
}

nonisolated public enum MetalDeviceKey: DependencyKey {
    public static let liveValue = MTLCreateSystemDefaultDevice()
    public static var testValue: (any MTLDevice)? {
        if shouldReportUnimplemented { reportIssue("Override metalDevice before using Metal in a test.") }
        return nil
    }
}

nonisolated public enum ShaderCompilerFactoryKey: DependencyKey {
    public static let liveValue: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling = {
        ShaderCompiler(device: $0, pixelFormat: $1)
    }
    public static let testValue: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling = { _, _ in
        reportIssue("Override shaderCompilerFactory before creating a renderer in a test.")
        return UnimplementedShaderCompiler()
    }
}

nonisolated public enum RendererFactoryKey: DependencyKey {
    public static let liveValue: @MainActor @Sendable (MTKView) throws -> Renderer = { view in
        @Dependency(\.metalDevice) var device
        guard let device else { throw RendererStartupError.metalUnavailable }
        view.device = device
        guard let renderer = Renderer(metalKitView: view) else { throw RendererStartupError.initializationFailed }
        return renderer
    }
    public static let testValue: @MainActor @Sendable (MTKView) throws -> Renderer = { _ in
        reportIssue("Override rendererFactory before starting a controller in a test.")
        throw RendererStartupError.initializationFailed
    }
}

nonisolated public enum MonotonicTimeKey: DependencyKey {
    public static let liveValue: @MainActor @Sendable () -> TimeInterval = { CACurrentMediaTime() }
    public static let testValue: @MainActor @Sendable () -> TimeInterval = {
        reportIssue("Override monotonicTime before advancing renderer time in a test.")
        return 0
    }
}

nonisolated public enum ShaderPreferencesKey: DependencyKey {
    public static let liveValue = ShaderPreferences.live
    public static let previewValue = ShaderPreferences.inMemory()
    public static let testValue = ShaderPreferences(
        lastShaderID: {
            reportIssue("Override shaderPreferences before reading preferences in a test.")
            return nil
        },
        setLastShaderID: { _ in reportIssue("Override shaderPreferences before saving preferences in a test.") }
    )
}

nonisolated private struct UnimplementedShaderCompiler: ShaderCompiling {
    public func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState {
        throw RendererStartupError.initializationFailed
    }
}
