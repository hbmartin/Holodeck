import Foundation

/// Frame timing stays outside UI observation. Resolution changes require sustained evidence.
nonisolated public struct AdaptiveQuality {
    public static let scales: [Double] = [1, 0.85, 0.7, 0.5]
    public private(set) var level = 0
    public var scale: Double { Self.scales[level] }
    private var warmUntil: TimeInterval = 0
    private var windowStart: TimeInterval = 0
    private var total: Double = 0
    private var count = 0
    private var slowWindows = 0
    private var fastWindows = 0

    public init() {}
    public mutating func reset(at now: TimeInterval) {
        warmUntil = now + 2
        windowStart = warmUntil
        total = 0; count = 0; slowWindows = 0; fastWindows = 0
    }

    /// Returns a new scale only when a threshold has been crossed.
    public mutating func record(duration: TimeInterval?, at now: TimeInterval) -> Double? {
        guard now.isFinite, now >= warmUntil else { return nil }
        guard let duration, duration.isFinite, duration > 0 else {
            reset(at: now)
            return nil
        }
        var changed: Double?
        if now - windowStart >= 1 {
            // Gaps are not a sustained performance sample.
            if count > 0, now - windowStart < 2 {
                let average = total / Double(count)
                slowWindows = average > 0.025 ? slowWindows + 1 : 0
                fastWindows = average < 0.016 ? fastWindows + 1 : 0
                let previous = level
                if slowWindows >= 2 { level = min(level + 1, Self.scales.count - 1) }
                if fastWindows >= 5 { level = max(level - 1, 0) }
                if previous != level { changed = scale; slowWindows = 0; fastWindows = 0 }
            } else {
                slowWindows = 0; fastWindows = 0
            }
            windowStart = now; total = 0; count = 0
        }
        total += duration
        count += 1
        return changed
    }
}

nonisolated public struct RenderingPolicy: Sendable {
    public let framesPerSecond: Int
    public let adaptiveResolution: Bool
    public static let tv = Self(framesPerSecond: 60, adaptiveResolution: false)
    public static let mac = Self(framesPerSecond: 30, adaptiveResolution: true)
    public init(framesPerSecond: Int, adaptiveResolution: Bool) {
        self.framesPerSecond = framesPerSecond
        self.adaptiveResolution = adaptiveResolution
    }
}
