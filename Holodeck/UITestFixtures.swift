#if DEBUG
import UIKit
import MetalKit
import Dependencies

/// App-side controls let UI regressions finish startup without timing delays.
final class UITestFixtures: NSObject {
    private let arguments: [String]
    private let gate = InitialShaderGate()
    private weak var controller: GameViewController?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.arguments = arguments
    }

    func configure(_ dependencies: inout DependencyValues) {
        if let index = arguments.firstIndex(of: "--ui-test-storage-suite"), index + 1 < arguments.count,
           let defaults = UserDefaults(suiteName: arguments[index + 1]) {
            dependencies.shaderPreferences = .userDefaults(defaults)
            dependencies.catalogService = CatalogService(bundled: ShaderCatalog.bundled, storage: .disabled, enabled: false)
        }
        if arguments.contains("--ui-test-metal-unavailable") {
            dependencies.metalDevice = nil
        } else if arguments.contains("--ui-test-hold-initial-shader") {
            let gate = gate
            let failsInitial = arguments.contains("--ui-test-fail-initial-shader")
            let savedID = dependencies.shaderPreferences.lastShaderID()
            let startupID = ShaderCatalog.shaders.first { $0.id == savedID }?.id ?? ShaderCatalog.initialShader.id
            dependencies.shaderCompilerFactory = { device, pixelFormat in
                HeldInitialShaderCompiler(device: device, pixelFormat: pixelFormat, startupID: startupID,
                                          gate: gate, failsInitial: failsInitial)
            }
        }
    }

    func installControls(on controller: GameViewController) {
        self.controller = controller
        if arguments.contains("--ui-test-hold-initial-shader") {
            let releaseGesture = UITapGestureRecognizer(target: self, action: #selector(releaseInitialShader))
            releaseGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            controller.view.addGestureRecognizer(releaseGesture)
        } else if arguments.contains("--ui-test-refresh-catalog") {
            let refreshGesture = UITapGestureRecognizer(target: self, action: #selector(refreshCatalog))
            refreshGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            controller.view.addGestureRecognizer(refreshGesture)
        } else if arguments.contains("--ui-test-repeat-activation") {
            let activationGesture = UITapGestureRecognizer(target: self, action: #selector(repeatActivation))
            activationGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            controller.view.addGestureRecognizer(activationGesture)
        }
    }

    @objc private func releaseInitialShader() {
        Task { await gate.release() }
    }

    @objc private func refreshCatalog() {
        var snapshot = ShaderCatalog.bundled
        var added = snapshot.manifest.shaders[0]
        added.id = "ninth-shader"
        added.name = "Ninth Shader"
        added.sourcePath = "sources/ninth-shader.metal"
        added.previewPath = "previews/ninth-shader.png"
        snapshot.sources[added.id] = snapshot.sources["plasma"]
        snapshot.manifest.shaders.reverse()
        snapshot.manifest.shaders.append(added)
        snapshot.publicationRevision = String(repeating: "a", count: 40)
        controller?.applyCatalog(snapshot)
    }

    @objc private func repeatActivation() {
        controller?.setSceneActive(false)
        controller?.setSceneActive(true)
        controller?.setSceneActive(true)
    }
}

private actor HeldInitialShaderCompiler: ShaderCompiling {
    private let compiler: ShaderCompiler
    private let gate: InitialShaderGate
    private let failsInitial: Bool
    private let startupID: String
    private var receivedInitial = false

    init(device: any MTLDevice, pixelFormat: MTLPixelFormat, startupID: String,
         gate: InitialShaderGate, failsInitial: Bool) {
        compiler = ShaderCompiler(device: device, pixelFormat: pixelFormat)
        self.startupID = startupID
        self.gate = gate
        self.failsInitial = failsInitial
    }

    func pipeline(for shader: ShaderDefinition) async throws -> any MTLRenderPipelineState {
        if shader.id == startupID {
            let isFirst = !receivedInitial
            receivedInitial = true
            await gate.wait()
            if isFirst && failsInitial { throw ShaderCompilationError.missingFunction("fragmentShader") }
        }
        return try await compiler.pipeline(for: shader)
    }
}

private actor InitialShaderGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
#endif
