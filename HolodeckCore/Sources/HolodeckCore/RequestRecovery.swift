#if os(macOS)
import Foundation
import Darwin

nonisolated struct RequestWorkerSupervisionError: LocalizedError, Sendable {
    let message: String
    var retryable = true
    var errorDescription: String? { message }
}

/// Separate from process evidence: successful settlement does not replenish a retry.
nonisolated struct RequestWorkerOperation: Codable, Sendable {
    enum Phase: String, Codable { case initial, retryPending, retryRunning, paused, complete }
    var formatVersion = 1
    var id = UUID()
    var mode: String
    var phase: Phase = .initial
    static let filename = "worker-operation.json"

    static func read(in directory: URL) throws -> Self? {
        var info = stat()
        if lstat(directory.appendingPathComponent(filename).path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw RequestWorkerEvidenceError(cause: "Worker operation journal cannot be inspected.")
        }
        do {
            let value = try JSONDecoder().decode(Self.self, from: BoundedCatalogReader(root: directory).read(filename, limit: CatalogLimits.headBytes).bytes)
            guard value.formatVersion == 1, ["run", "preflight", "publication", "discard"].contains(value.mode) else {
                throw RequestWorkerEvidenceError(cause: "Invalid worker operation journal.")
            }
            return value
        } catch { throw RequestWorkerEvidenceError(cause: "Worker operation journal is unreadable: " + error.localizedDescription) }
    }
    func save(in directory: URL) throws {
        do { try write(in: URL(fileURLWithPath: RequestPaths.canonical(directory))) }
        catch { throw RequestWorkerEvidenceError(cause: "Cannot persist worker retry state: " + error.localizedDescription) }
    }
    private func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".operation-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(self)); try handle.synchronize()
        guard rename(temporary.path, directory.appendingPathComponent(Self.filename).path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    static func begin(mode: String, in directory: URL) throws -> Self {
        if var saved = try read(in: directory), saved.mode == mode, saved.phase != .complete {
            if saved.phase == .retryRunning { saved.phase = .paused; try saved.save(in: directory) }
            guard saved.phase != .paused else {
                throw RequestWorkerEvidenceError(cause: "The automatic supervision retry was exhausted or interrupted. Retry recovery manually to resume preserved work.")
            }
            return saved
        }
        let value = Self(mode: mode); try value.save(in: directory); return value
    }
    static func restartPaused(in directory: URL) throws {
        if let saved = try read(in: directory), saved.phase == .paused {
            try Self(mode: saved.mode).save(in: directory)
        }
    }
}

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
        var preferencesRollback: ShaderRequestConfiguration?
    }
    var formatVersion = 1
    var legacyMigrationComplete = false
    var entries: [String: Entry] = [:]
}
#endif
