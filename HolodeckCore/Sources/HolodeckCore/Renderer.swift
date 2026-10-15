import MetalKit
import Dependencies
import Foundation
#if os(tvOS)
import QuartzCore
#endif

/// Matches ShaderUniforms in the runtime Metal source: 8 + 4 + 4 bytes.
nonisolated public struct ShaderUniforms {
    public var resolution: SIMD2<Float>
    public var time: Float
    public var padding: Float = 0
    public static func validateLayout() throws {
        guard MemoryLayout<Self>.size == 16, MemoryLayout<Self>.stride == 16,
              MemoryLayout<Self>.offset(of: \.resolution) == 0,
              MemoryLayout<Self>.offset(of: \.time) == 8,
              MemoryLayout<Self>.offset(of: \.padding) == 12 else {
            throw ShaderCompilationError.invalidUniformLayout
        }
    }
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

    public var onPresentedFrame: (@MainActor @Sendable (Double, Double?) -> Void)?
    public var onMeasurementReset: (@MainActor @Sendable () -> Void)?
    #if os(tvOS)
    public var onDisplayCadence: (@MainActor @Sendable (Double) -> Void)?
    private var displayCadence: Double?
    private var displayLink: CADisplayLink?
    private var completedFrame = false
    private var completedGPU: Double?
    #endif
    private var snapshotEncodingID: UUID?
    private var snapshotRequest: (id: UUID, shader: ShaderDefinition, continuation: CheckedContinuation<ShaderRequestContext, Error>)?

    isolated deinit {
        #if os(tvOS)
        displayLink?.invalidate()
        #endif
    }

    public func captureSnapshot() async throws -> ShaderRequestContext {
        guard isActive, let shader = activeShader, snapshotRequest == nil else {
            throw ShaderRequestError.unavailable("A playing shader is required to capture context.")
        }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            snapshotRequest = (id, shader, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finishSnapshot(id, .failure(ShaderRequestError.unavailable("Couldn’t capture the playing shader. Try Input again.")))
            }
        }
    }

    private func finishSnapshot(_ id: UUID, _ result: Result<ShaderRequestContext, Error>) {
        guard let request = snapshotRequest, request.id == id else { return }
        snapshotRequest = nil; snapshotEncodingID = nil
        request.continuation.resume(with: result)
    }

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
        if let request = snapshotRequest, snapshotEncodingID != request.id {
            snapshotEncodingID = request.id
            if request.shader.id != activeShader?.id || request.shader.sourceHash != activeShader?.sourceHash {
                finishSnapshot(request.id, .failure(ShaderRequestError.unavailable("The scene changed while capturing it. Try Input again.")))
            } else {
                let width = drawable.texture.width, height = drawable.texture.height
                let row = (width * 4 + 255) & ~255
                if width * height <= 16_777_216, let buffer = device.makeBuffer(length: row * height, options: .storageModeShared),
                   let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                              to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * height)
                    blit.endEncoding()
                    let capturedBuffer = RequestMetalBuffer(buffer)
                    let time = uniforms.time
                    commandBuffer.addCompletedHandler { [weak self] command in
                        guard command.status == .completed else {
                            Task { @MainActor in self?.finishSnapshot(request.id, .failure(ShaderRequestError.unavailable("Frame capture failed."))) }
                            return
                        }
                        let pixels = Data(bytes: capturedBuffer.value.contents(), count: row * height)
                        Task.detached {
                            do {
                                let png = try RequestScreenshot.encode(pixels: pixels, width: width, height: height, bytesPerRow: row)
                                let context = ShaderRequestContext(shader: request.shader, screenshot: png, animationTime: time, width: width, height: height)
                                await self?.finishSnapshot(request.id, .success(context))
                            } catch { await self?.finishSnapshot(request.id, .failure(error)) }
                        }
                    }
                } else { finishSnapshot(request.id, .failure(ShaderRequestError.unavailable("Unable to allocate frame capture."))) }
            }
        }
        let generation = timingGeneration
        #if os(tvOS)
        // tvOS omits MTLDrawable's presentation callback. Consume completed frames on
        // display ticks, counting at most one visible update per tick (dropped frames
        // do not inflate delivered FPS). GPU duration remains separate evidence.
        commandBuffer.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            let duration = command.gpuEndTime > command.gpuStartTime && command.gpuStartTime > 0
                ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.timingGeneration == generation else { return }
                self.completedFrame = true; self.completedGPU = duration
            }
        }
        #else
        let commandTiming = RequestMetalCommand(commandBuffer)
        drawable.addPresentedHandler { [weak self] presented in
            let timestamp = presented.presentedTime
            let command = commandTiming.value
            let duration = command.gpuEndTime > command.gpuStartTime && command.gpuStartTime > 0
                ? (command.gpuEndTime - command.gpuStartTime) * 1000 : nil
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.timingGeneration == generation else { return }
                self.onPresentedFrame?(timestamp > 0 ? timestamp : self.now(), duration)
            }
        }
        #endif
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
        metalKitView.framebufferOnly = false
        metalKitView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalKitView.preferredFramesPerSecond = policy.framesPerSecond
        metalKitView.autoResizeDrawable = !policy.adaptiveResolution
        metalKitView.isPaused = !isActive
        metalKitView.delegate = self
        #if os(tvOS)
        displayLink?.invalidate(); displayCadence = nil
        let displayLink = CADisplayLink(target: RequestDisplayLinkTarget(self), selector: #selector(RequestDisplayLinkTarget.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        #endif
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

    #if os(tvOS)
    fileprivate func displayTick(_ link: CADisplayLink) {
        guard isActive else { return }
        let target = ShaderPerformanceMonitor.attainableTarget(displayFramesPerSecond: 1 / link.duration, preferred: Double(policy.framesPerSecond))
        if displayCadence == nil || abs(target - displayCadence!) > 0.1 {
            displayCadence = target
            view?.preferredFramesPerSecond = max(1, Int(target.rounded()))
            resetMeasurements(); onDisplayCadence?(target)
        }
        if completedFrame { onPresentedFrame?(link.timestamp, completedGPU) }
        else { onDisplayObservation?(link.timestamp) }
        completedFrame = false; completedGPU = nil
    }
    public var onDisplayObservation: (@MainActor @Sendable (Double) -> Void)?
    #endif

    private func resetMeasurements() {
        #if os(tvOS)
        completedFrame = false; completedGPU = nil
        #endif
        onMeasurementReset?()
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
        resetMeasurements()
        resolution = SIMD2(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }
}

// Metal owns GPU synchronization; these immutable references are read only after completion/presentation.
nonisolated private final class RequestMetalBuffer: @unchecked Sendable {
    let value: any MTLBuffer
    init(_ value: any MTLBuffer) { self.value = value }
}
nonisolated private final class RequestMetalCommand: @unchecked Sendable {
    let value: any MTLCommandBuffer
    init(_ value: any MTLCommandBuffer) { self.value = value }
}

#if os(tvOS)
@MainActor private final class RequestDisplayLinkTarget: NSObject {
    weak var renderer: Renderer?
    init(_ renderer: Renderer) { self.renderer = renderer }
    @objc func tick(_ link: CADisplayLink) { renderer?.displayTick(link) }
}
#endif
