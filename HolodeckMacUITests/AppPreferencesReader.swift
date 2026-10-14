import Foundation

nonisolated enum AppPreferencesReader {
    enum ReadError: Error, Equatable, LocalizedError {
        case invalidSnapshot, incompatibleSchema, wrongApplication, missingDomain, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: "Preferences inspection returned malformed data."
            case .incompatibleSchema: "Preferences inspection returned an unsupported schema."
            case .wrongApplication: "Preferences inspection returned data for a different app."
            case .missingDomain: "The app's saved preferences domain is missing."
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
        let bundleIdentifier: String
        let domainExists: Bool
        let frames: [String: String]
        let lifecycle: Lifecycle
    }
    static func snapshot(_ payload: String, bundleIdentifier: String, allowMissing: Bool = false) throws -> Snapshot {
        let snapshot: Snapshot
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(payload.utf8)) }
        catch { throw ReadError.invalidSnapshot }
        guard snapshot.schemaVersion == 2 else { throw ReadError.incompatibleSchema }
        guard snapshot.bundleIdentifier == bundleIdentifier else { throw ReadError.wrongApplication }
        guard snapshot.frames.keys.allSatisfy({ $0.hasPrefix("NSWindow Frame HolodeckViewer-") }),
              snapshot.domainExists || snapshot.frames.isEmpty,
              snapshot.lifecycle.modelCreations >= 0, snapshot.lifecycle.libraryCreations >= 0,
              snapshot.lifecycle.serverStartAttempts >= 0 else { throw ReadError.invalidSnapshot }
        guard snapshot.domainExists || allowMissing else { throw ReadError.missingDomain }
        return snapshot
    }
    static func read(_ payload: String, bundleIdentifier: String, allowMissing: Bool = false) throws -> [String: String] {
        try snapshot(payload, bundleIdentifier: bundleIdentifier, allowMissing: allowMissing).frames
    }
    static func wait(read: () throws -> Snapshot, until predicate: (Snapshot) -> Bool,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                     timeout: TimeInterval = 10) throws -> Snapshot {
        let deadline = now() + timeout
        while true {
            let value = try read()
            if predicate(value) { return value }
            let remaining = deadline - now()
            guard remaining > 0 else { throw ReadError.timedOut }
            sleep(min(0.25, remaining))
        }
    }
}
