import Foundation
import ImageIO

nonisolated public struct ShaderRequestContext: Codable, Sendable, Equatable {
    public var shaderID: String
    public var name: String
    public var category: String
    public var description: String
    public var colors: [[Float]]
    public var source: String
    public var sourceHash: String
    public var discovery: SceneDiscovery?
    public var updatedAt: Date?
    public var publicationRevision: String?
    public var screenshot: Data
    public var animationTime: Float
    public var drawableWidth: Int
    public var drawableHeight: Int

    public init(shader: ShaderDefinition, screenshot: Data, animationTime: Float, width: Int, height: Int) {
        shaderID = shader.id; name = shader.title; category = shader.category.rawValue
        description = shader.description; colors = shader.colors.map { [$0.x, $0.y, $0.z] }
        source = shader.source; sourceHash = shader.sourceHash; discovery = shader.discovery; updatedAt = shader.updatedAt; publicationRevision = shader.preview?.publicationRevision
        self.screenshot = screenshot; self.animationTime = animationTime
        drawableWidth = width; drawableHeight = height
    }

    public func validate() throws {
        guard ShaderRequest.validID(shaderID), !name.isEmpty, name.count <= 200,
              source.utf8.count <= CatalogLimits.sourceBytes,
              CatalogHash.sha256(Data(source.utf8)) == sourceHash,
              !screenshot.isEmpty, screenshot.count <= 4_000_000,
              colors.count <= 10, colors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              description.utf8.count <= 16_384,
              let image = CGImageSourceCreateWithData(screenshot as CFData, nil), CGImageSourceGetCount(image) == 1,
              CGImageSourceGetType(image) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 1280,
              properties[kCGImagePropertyPixelHeight] as? Int == 720,
              animationTime.isFinite, animationTime >= 0,
              (1...8192).contains(drawableWidth), (1...8192).contains(drawableHeight) else {
            throw ShaderRequestError.invalidRequest
        }
    }
}

nonisolated public struct PerformanceEvidence: Codable, Sendable, Equatable {
    public var targetFramesPerSecond: Double?
    public var framesPerSecond: [Double]
    public var gpuMilliseconds: [Double]
    public var device: String
    public var sourceHash: String
    public init(framesPerSecond: [Double], gpuMilliseconds: [Double], device: String, sourceHash: String, targetFramesPerSecond: Double? = nil) {
        self.targetFramesPerSecond = targetFramesPerSecond
        self.framesPerSecond = framesPerSecond; self.gpuMilliseconds = gpuMilliseconds
        self.device = device; self.sourceHash = sourceHash
    }
}

nonisolated public struct ShaderRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Purpose: String, Codable, Sendable { case creative, performance }
    public enum Origin: String, Codable, Sendable { case manual, automatic }
    public var id: UUID
    public var purpose: Purpose
    public var origin: Origin
    public var prompt: String
    public var context: ShaderRequestContext
    public var performance: PerformanceEvidence?
    public var parentRequestID: UUID?
    public init(id: UUID = UUID(), purpose: Purpose = .creative, origin: Origin = .manual,
                prompt: String, context: ShaderRequestContext, performance: PerformanceEvidence? = nil,
                parentRequestID: UUID? = nil) {
        self.id = id; self.purpose = purpose; self.origin = origin; self.prompt = prompt
        self.context = context; self.performance = performance; self.parentRequestID = parentRequestID
    }
    public static func validID(_ id: String) -> Bool {
        id.count <= 100 && id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
    public func validate() throws {
        try context.validate()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 16_384 else {
            throw ShaderRequestError.invalidRequest
        }
        if purpose == .performance {
            guard let performance else { throw ShaderRequestError.invalidRequest }
            let target = performance.targetFramesPerSecond ?? 30
            guard target.isFinite, target > 0, target <= 30, performance.sourceHash == context.sourceHash,
                  performance.framesPerSecond.count == 10,
                  performance.framesPerSecond.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < target * 0.9 }),
                  performance.gpuMilliseconds.count <= 10,
                  performance.gpuMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  performance.device.count <= 200 else { throw ShaderRequestError.invalidRequest }
        }
    }
}

nonisolated public struct ShaderRequestResult: Codable, Sendable, Equatable {
    public enum OutputKind: String, Codable, Sendable { case new, edited }
    public var outputKind: OutputKind
    public var shaderID: String
    public var changed: Bool
    public var summary: String
    public var approximations: [String]
    public var commitSHA: String?
    public var deliveredSourceHash: String?
    public init(outputKind: OutputKind, shaderID: String, changed: Bool, summary: String,
                approximations: [String] = [], commitSHA: String? = nil, deliveredSourceHash: String? = nil) {
        self.outputKind = outputKind; self.shaderID = shaderID; self.changed = changed; self.summary = summary
        self.approximations = approximations; self.commitSHA = commitSHA; self.deliveredSourceHash = deliveredSourceHash
    }
}

nonisolated public struct ShaderClarification: Codable, Sendable, Equatable {
    public var question: String
    public var options: [String]
    public init(question: String, options: [String] = []) { self.question = question; self.options = options }
}

nonisolated public struct ShaderRequestStatus: Codable, Sendable, Equatable, Identifiable {
    public enum Stage: String, Codable, Sendable {
        case queued, implementing, awaitingClarification, validating, reviewing, pushing, publishing
        case awaitingActivation, repairing, completed, failed, cancelled
        public var title: String {
            switch self {
            case .queued: "Queued"
            case .implementing: "Implementing"
            case .awaitingClarification: "Waiting for an answer"
            case .validating: "Checking shaders"
            case .reviewing: "Reviewing images"
            case .pushing: "Pushing to main"
            case .publishing: "Publishing library"
            case .awaitingActivation: "Waiting for TV playback"
            case .repairing: "Repairing"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }
        public var terminal: Bool { self == .completed || self == .failed || self == .cancelled }
    }
    public var id: UUID
    public var request: ShaderRequest
    public var deviceID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var stage: Stage
    public var message: String
    public var clarification: ShaderClarification?
    public var result: ShaderRequestResult?
    public var sequence: UInt64
    public init(request: ShaderRequest, deviceID: String, date: Date = Date()) {
        id = request.id; self.request = request; self.deviceID = deviceID
        createdAt = date; updatedAt = date; stage = .queued; message = "Waiting for the Mac worker"
        sequence = 0
    }
    public var blocksBrowsing: Bool { request.purpose == .creative && !stage.terminal }
}

nonisolated public struct ShaderRequestControl: Codable, Sendable {
    public var request: ShaderRequest?
    public var requestID: UUID?
    public var answer: String?
    public var sourceHash: String?
    public var diagnostic: String?
    public init(request: ShaderRequest? = nil, requestID: UUID? = nil, answer: String? = nil,
                sourceHash: String? = nil, diagnostic: String? = nil) {
        self.request = request; self.requestID = requestID; self.answer = answer
        self.sourceHash = sourceHash; self.diagnostic = diagnostic
    }
}

nonisolated public struct ShaderRequestControlReply: Codable, Sendable {
    public var enabled: Bool
    public var message: String
    public var jobs: [ShaderRequestStatus]
    public var publicationRevision: String?
    public init(enabled: Bool, message: String, jobs: [ShaderRequestStatus] = [], publicationRevision: String? = nil) {
        self.enabled = enabled; self.message = message; self.jobs = jobs; self.publicationRevision = publicationRevision
    }
}

nonisolated public enum ShaderRequestError: Error, LocalizedError {
    case invalidRequest, unavailable(String), notFound
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The shader request or captured context is invalid."
        case .unavailable(let message): message
        case .notFound: "This request is unavailable for this TV."
        }
    }
}

/// Only these output-specific failures request an implementation repair on the Mac.
nonisolated public enum ShaderDeliveryDefect: Error, LocalizedError {
    case outputMissing(String), activation(String)
    public var errorDescription: String? {
        switch self {
        case .outputMissing(let id): "Output shader \(id) is no longer in the freshly checked library."
        case .activation(let diagnostic): diagnostic
        }
    }
}

/// Measures presented frames, independently of GPU timing or adaptive resolution.
nonisolated public struct ShaderPerformanceMonitor: Sendable {
    private var warmUntil = 0.0
    private var start = 0.0
    private var frames = 0
    private var gpuTotal = 0.0
    private var gpuCount = 0
    private var slow: [Double] = []
    private var gpu: [Double] = []
    public private(set) var targetFramesPerSecond = 30.0
    public init() {}
    public static func attainableTarget(displayFramesPerSecond rate: Double, preferred: Double = 30) -> Double {
        guard rate.isFinite, rate > 0, preferred.isFinite, preferred > 0 else { return 30 }
        let nearest = max(1, (rate / preferred).rounded())
        let tolerance = max(0.01, nearest * preferred * 0.001)
        let divisor = abs(rate - nearest * preferred) <= tolerance + rate.ulp ? nearest : max(1, ceil(rate / preferred))
        return min(preferred, rate / divisor)
    }
    public mutating func setTargetFramesPerSecond(_ target: Double, at time: Double) {
        guard target.isFinite, target > 0, target <= 30, abs(target - targetFramesPerSecond) > 0.1 else { return }
        targetFramesPerSecond = target; reset(at: time)
    }
    public mutating func reset(at time: Double) {
        warmUntil = time + 2; start = warmUntil; frames = 0; gpuTotal = 0; gpuCount = 0
        slow.removeAll(); gpu.removeAll()
    }
    public mutating func presented(at time: Double, gpuMilliseconds: Double? = nil) -> (fps: [Double], gpu: [Double])? {
        observe(at: time, deliveredFrames: 1, gpuMilliseconds: gpuMilliseconds)
    }
    public mutating func observe(at time: Double, deliveredFrames: Int, gpuMilliseconds: Double? = nil) -> (fps: [Double], gpu: [Double])? {
        guard time.isFinite, time >= warmUntil else { return nil }
        if time - start >= 1 {
            let elapsed = time - start
            if elapsed < 2 {
                let fps = Double(frames) / elapsed
                if fps < targetFramesPerSecond * 0.9 { slow.append(fps); gpu.append(gpuCount > 0 ? gpuTotal / Double(gpuCount) : 0) }
                else { slow.removeAll(); gpu.removeAll() }
            } else { slow.removeAll(); gpu.removeAll() }
            start = time; frames = 0; gpuTotal = 0; gpuCount = 0
            if slow.count == 10 {
                let result = (slow, gpu); reset(at: time); return result
            }
        }
        frames += max(0, deliveredFrames)
        if let duration = gpuMilliseconds, duration.isFinite, duration >= 0 { gpuTotal += duration; gpuCount += 1 }
        return nil
    }
}

/// One non-preempting worker; parked jobs do not occupy it.
nonisolated enum ShaderRequestScheduling {
    static func next(in jobs: [ShaderRequestStatus], recoveringID: UUID? = nil) -> UUID? {
        let ready = jobs.filter { $0.stage == .queued || $0.stage == .repairing }
        if let recoveringID, ready.contains(where: { $0.id == recoveringID }) { return recoveringID }
        return ready.sorted {
            if $0.request.origin != $1.request.origin { return $0.request.origin == .manual }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first?.id
    }
}
