import Foundation

nonisolated enum AppPreferencesReader {
    enum ReadError: Error {
        case invalidSnapshot, incompatibleSchema, wrongApplication, missingDomain
    }
    private struct Snapshot: Decodable {
        let schemaVersion: Int
        let bundleIdentifier: String
        let domainExists: Bool
        let frames: [String: String]
    }

    static func read(_ payload: String, bundleIdentifier: String, allowMissing: Bool = false) throws -> [String: String] {
        let snapshot: Snapshot
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(payload.utf8)) }
        catch { throw ReadError.invalidSnapshot }
        guard snapshot.schemaVersion == 1 else { throw ReadError.incompatibleSchema }
        guard snapshot.bundleIdentifier == bundleIdentifier else { throw ReadError.wrongApplication }
        guard snapshot.frames.keys.allSatisfy({ $0.hasPrefix("NSWindow Frame HolodeckViewer-") }),
              snapshot.domainExists || snapshot.frames.isEmpty else { throw ReadError.invalidSnapshot }
        guard snapshot.domainExists || allowMissing else { throw ReadError.missingDomain }
        return snapshot.frames
    }
}
