import Foundation

nonisolated enum AppPreferencesReader {
    enum ReadError: Error, Equatable, LocalizedError {
        case invalidSnapshot, incompatibleSchema, wrongApplication, missingDomain, timedOut
        case refreshTimedOut(expected: Int, observed: Int)
        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: "Preferences inspection returned malformed data."
            case .incompatibleSchema: "Preferences inspection returned an unsupported schema."
            case .wrongApplication: "Preferences inspection returned data for a different app."
            case .missingDomain: "The app's saved preferences domain is missing."
            case .refreshTimedOut(let expected, let observed): "Timed out waiting for preferences refresh generation \(expected); last observed \(observed)."
            case .timedOut: "Timed out waiting for the expected saved preference changes."
            }
        }
    }
    struct Lifecycle: Decodable, Equatable {
        let modelCreations: Int
        let libraryCreations: Int
        let serverStartAttempts: Int
        var isIdle: Bool { modelCreations == 0 && libraryCreations == 0 && serverStartAttempts == 0 }
    }
    struct Snapshot: Decodable, Equatable {
        let schemaVersion: Int
        let refreshGeneration: Int
        let bundleIdentifier: String
        let domainExists: Bool
        let frames: [String: String]
        let lifecycle: Lifecycle
    }
    static func snapshot(_ payload: String, bundleIdentifier: String, allowMissing: Bool = false) throws -> Snapshot {
        let snapshot: Snapshot
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(payload.utf8)) }
        catch { throw ReadError.invalidSnapshot }
        guard snapshot.schemaVersion == 3 else { throw ReadError.incompatibleSchema }
        guard snapshot.bundleIdentifier == bundleIdentifier else { throw ReadError.wrongApplication }
        guard snapshot.refreshGeneration >= 0, snapshot.frames.keys.allSatisfy({ $0.hasPrefix("NSWindow Frame HolodeckViewer-") }),
              snapshot.domainExists || snapshot.frames.isEmpty,
              snapshot.lifecycle.modelCreations >= 0, snapshot.lifecycle.libraryCreations >= 0,
              snapshot.lifecycle.serverStartAttempts >= 0 else { throw ReadError.invalidSnapshot }
        guard snapshot.domainExists || allowMissing else { throw ReadError.missingDomain }
        return snapshot
    }
    static func read(_ payload: String, bundleIdentifier: String, allowMissing: Bool = false) throws -> [String: String] {
        try snapshot(payload, bundleIdentifier: bundleIdentifier, allowMissing: allowMissing).frames
    }
    static func acknowledged(read: () throws -> Snapshot, generation: Int, deadline: TimeInterval,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Snapshot {
        var observed = -1
        do {
            return try wait(read: { let value = try read(); observed = value.refreshGeneration; return value },
                until: { $0.refreshGeneration == generation }, now: now, sleep: sleep, deadline: deadline)
        } catch ReadError.timedOut { throw ReadError.refreshTimedOut(expected: generation, observed: observed) }
    }
    static func wait(read: () throws -> Snapshot, until predicate: (Snapshot) -> Bool,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                     timeout: TimeInterval = 10, deadline: TimeInterval? = nil) throws -> Snapshot {
        let deadline = deadline ?? now() + timeout
        while true {
            let value = try read()
            guard now() <= deadline else { throw ReadError.timedOut }
            if predicate(value) { return value }
            let remaining = deadline - now()
            guard remaining > 0 else { throw ReadError.timedOut }
            sleep(min(0.25, remaining))
        }
    }
}
