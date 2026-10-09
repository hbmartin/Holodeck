import MetalKit
import Dependencies

/// Matches ShaderUniforms in the runtime Metal source: 8 + 4 + 4 bytes.
nonisolated struct ShaderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var padding: Float = 0
}

nonisolated struct ShaderClock {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    mutating func reset(at now: TimeInterval, running: Bool) {
        accumulated = 0
        startedAt = running ? now : nil
    }

    mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        if running, startedAt == nil {
            startedAt = now
        } else if !running, let start = startedAt {
            accumulated += max(0, now - start)
            startedAt = nil
        }
    }

    func elapsed(at now: TimeInterval) -> Float {
        Float(accumulated + (startedAt.map { max(0, now - $0) } ?? 0))
    }
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let compiler: any ShaderCompiling
    private let now: @MainActor @Sendable () -> TimeInterval
    private weak var view: MTKView?
    private var pipelineState: (any MTLRenderPipelineState)?
    private var selectionRequest: UInt64 = 0
    private var clock = ShaderClock()
    private var isActive = false
    private var resolution = SIMD2<Float>(1, 1)
    private(set) var activeShader: ShaderDefinition?

    var animationTime: Float { clock.elapsed(at: now()) }

    init?(metalKitView: MTKView) {
        guard let device = metalKitView.device, let queue = device.makeCommandQueue() else { return nil }
        @Dependency(\.shaderCompilerFactory) var compilerFactory
        @Dependency(\.monotonicTime) var monotonicTime
        self.device = device
        commandQueue = queue
        compiler = compilerFactory(device, .bgra8Unorm_srgb)
        now = monotonicTime
        view = metalKitView
        super.init()
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = .invalid
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalKitView.preferredFramesPerSecond = 60
        metalKitView.isPaused = true
        mtkView(metalKitView, drawableSizeWillChange: metalKitView.drawableSize)
    }

    /// False means a newer selection superseded this result, including its errors.
    @discardableResult
    func select(_ shader: ShaderDefinition) async throws -> Bool {
        selectionRequest &+= 1
        let request = selectionRequest
        do {
            let pipeline = try await compiler.pipeline(for: shader)
            guard request == selectionRequest else { return false }
            pipelineState = pipeline
            activeShader = shader
            clock.reset(at: now(), running: isActive)
            return true
        } catch {
            guard request == selectionRequest else { return false }
            throw error
        }
    }

    func cancelPendingSelection() { selectionRequest &+= 1 }

    func setActive(_ active: Bool) {
        isActive = active
        clock.setRunning(active, at: now())
        view?.isPaused = !active
    }

    func draw(in view: MTKView) {
        guard let pipelineState,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = ShaderUniforms(resolution: resolution, time: animationTime)
        encoder.label = activeShader?.title
        encoder.setRenderPipelineState(pipelineState)
        // Metal copies these bytes; no shared mutable GPU buffer is needed.
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resolution = SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }
}
