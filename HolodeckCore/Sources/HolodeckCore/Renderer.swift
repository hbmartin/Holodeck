import MetalKit
import Dependencies

/// Matches ShaderUniforms in the runtime Metal source: 8 + 4 + 4 bytes.
nonisolated public struct ShaderUniforms {
    public var resolution: SIMD2<Float>
    public var time: Float
    public var padding: Float = 0
    public init(resolution: SIMD2<Float>, time: Float, padding: Float = 0) {
        self.resolution = resolution; self.time = time; self.padding = padding
    }
}

nonisolated public struct ShaderClock {
    public init() {}
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    public mutating func reset(at now: TimeInterval, running: Bool) {
        accumulated = 0
        startedAt = running ? now : nil
    }

    public mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        if running, startedAt == nil {
            startedAt = now
        } else if !running, let start = startedAt {
            accumulated += max(0, now - start)
            startedAt = nil
        }
    }

    public func elapsed(at now: TimeInterval) -> Float {
        Float(accumulated + (startedAt.map { max(0, now - $0) } ?? 0))
    }
}

@MainActor
public final class Renderer: NSObject, MTKViewDelegate, SceneRendering {
    public let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let compiler: any ShaderCompiling
    private let now: @MainActor @Sendable () -> TimeInterval
    private weak var view: MTKView?
    private var pipelineState: (any MTLRenderPipelineState)?
    private var selectionRequest: UInt64 = 0
    private var clock = ShaderClock()
    private var isActive = false
    private var policy = RenderingPolicy.tv
    private var quality = AdaptiveQuality()
    private var nativeDrawableSize = CGSize(width: 1, height: 1)
    private var timingGeneration: UInt64 = 0
    private var resolution = SIMD2<Float>(1, 1)
    public private(set) var activeShader: ShaderDefinition?

    public var animationTime: Float { clock.elapsed(at: now()) }

    public init?(metalKitView: MTKView) {
        guard let device = metalKitView.device, let queue = device.makeCommandQueue() else { return nil }
        @Dependency(\.shaderCompilerFactory) var compilerFactory
        @Dependency(\.monotonicTime) var monotonicTime
        self.device = device
        commandQueue = queue
        compiler = compilerFactory(device, .bgra8Unorm_srgb)
        now = monotonicTime
        view = metalKitView
        super.init()
        bind(to: metalKitView)

    }

    /// False means a newer selection superseded this result, including its errors.
    @discardableResult
    public func select(_ shader: ShaderDefinition) async throws -> Bool {
        selectionRequest &+= 1
        let request = selectionRequest
        do {
            let pipeline = try await compiler.pipeline(for: shader)
            guard request == selectionRequest else { return false }
            pipelineState = pipeline
            activeShader = shader
            clock.reset(at: now(), running: isActive)
            resetMeasurements()
            return true
        } catch {
            guard request == selectionRequest else { return false }
            throw error
        }
    }

    public func cancelPendingSelection() { selectionRequest &+= 1 }

    public func setActive(_ active: Bool) {
        if active != isActive { resetMeasurements() }
        isActive = active
        clock.setRunning(active, at: now())
        view?.isPaused = !active
    }

    public func draw(in view: MTKView) {
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
        if policy.adaptiveResolution {
            let generation = timingGeneration
            commandBuffer.addCompletedHandler { [weak self] buffer in
                let duration = buffer.gpuEndTime > buffer.gpuStartTime && buffer.gpuStartTime > 0
                    ? buffer.gpuEndTime - buffer.gpuStartTime : nil
                Task { @MainActor [weak self] in
                    guard let self, self.isActive, self.timingGeneration == generation else { return }
                    if self.quality.record(duration: duration, at: self.now()) != nil { self.updateDrawableSize() }
                }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public func bind(to metalKitView: MTKView) {
        if view !== metalKitView { view?.isPaused = true; view?.delegate = nil }
        view = metalKitView
        metalKitView.device = device
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = .invalid
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalKitView.preferredFramesPerSecond = policy.framesPerSecond
        metalKitView.autoResizeDrawable = !policy.adaptiveResolution
        metalKitView.isPaused = !isActive
        metalKitView.delegate = self
        nativeDrawableSize = .zero
        resetMeasurements()
        mtkView(metalKitView, drawableSizeWillChange: metalKitView.drawableSize)
    }

    public func configure(_ policy: RenderingPolicy) {
        self.policy = policy
        view?.preferredFramesPerSecond = policy.framesPerSecond
        if policy.adaptiveResolution { view?.autoResizeDrawable = false }
        resetMeasurements()
    }

    /// The Mac adapter supplies backing-pixel size; adaptive scaling never changes view geometry.
    public func resize(nativeSize: CGSize) {
        guard nativeSize.width > 0, nativeSize.height > 0, nativeSize != nativeDrawableSize else { return }
        nativeDrawableSize = nativeSize
        resetMeasurements()
        updateDrawableSize()
    }

    private func resetMeasurements() {
        timingGeneration &+= 1
        quality.reset(at: now())
    }

    private func updateDrawableSize() {
        guard policy.adaptiveResolution else { return }
        let size = CGSize(width: max(1, (nativeDrawableSize.width * quality.scale).rounded()),
                          height: max(1, (nativeDrawableSize.height * quality.scale).rounded()))
        if view?.drawableSize != size { view?.drawableSize = size }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resolution = SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }
}
