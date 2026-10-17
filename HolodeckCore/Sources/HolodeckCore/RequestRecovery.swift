#if os(macOS)
import Foundation

public enum ShaderRequestRecoveryDisposition: String, Codable, Sendable {
    case resume, retainResult, cleanup, detach
}

/// Recovery survives creative-record deletion and includes maintenance journals.
nonisolated struct RequestRecoveryStore: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var id = UUID()
        var journal: String
        var requestID: UUID?
        var configuration: ShaderRequestConfiguration?
        var disposition: ShaderRequestRecoveryDisposition
        var message: String
    }
    var formatVersion = 1
    var legacyMigrationComplete = false
    var entries: [String: Entry] = [:]
}
#endif
