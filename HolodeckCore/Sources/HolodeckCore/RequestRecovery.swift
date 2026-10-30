#if os(macOS)
import Foundation
import Darwin

nonisolated struct RequestWorkerSupervisionError: LocalizedError, Sendable {
    let message: String
    var underlyingError: (any Error)? = nil
    var retryable = true
    var errorDescription: String? { message }
}

/// Separate from process evidence: successful settlement does not replenish a retry.
nonisolated struct RequestWorkerOperation: Codable, Sendable {
    enum Phase: String, Codable { case initial, retryPending, retryRunning, paused, complete }
    struct Target: Codable, Equatable, Sendable {
        var repository: String
        var checkoutID: String?
        init(_ configuration: ShaderRequestConfiguration) {
            repository = RequestPaths.canonical(URL(fileURLWithPath: configuration.repository))
            checkoutID = configuration.checkoutID
        }
    }
    struct Binding: Codable, Sendable {
        var predecessor: UUID?
        var previous: Data?
        var replacement: Data
    }
    var formatVersion = 2
    var id = UUID()
    var mode: String
    var phase: Phase = .initial
    var target: Target?
    var binding: Binding?
    static let filename = "worker-operation.json"
    typealias Writer = (Data, URL) throws -> Void

    static func read(in directory: URL) throws -> Self? {
        guard RequestProcessIdentity.evidenceExists(directory.appendingPathComponent(filename)) else { return nil }
        do {
            let value = try JSONDecoder().decode(Self.self, from: BoundedCatalogReader(root: directory).read(filename, limit: CatalogLimits.headBytes).bytes)
            guard [1, 2].contains(value.formatVersion), ["run", "preflight", "publication", "discard"].contains(value.mode),
                  value.formatVersion == 2 || value.binding == nil,
                  value.formatVersion == 1 || value.target != nil else {
                throw RequestWorkerEvidenceError(cause: "Invalid worker operation journal.")
            }
            if let binding = value.binding {
                let replacement = try configurationObject(binding.replacement)
                guard operationID(replacement) == value.id,
                      try binding.previous.map({ operationID(try configurationObject($0)) }) ?? nil == binding.predecessor,
                      let target = value.target,
                      Target(try JSONDecoder().decode(ShaderRequestConfiguration.self, from: binding.replacement)) == target else {
                    throw RequestWorkerEvidenceError(cause: "Invalid worker configuration transition.")
                }
            }
            return value
        } catch { throw RequestWorkerEvidenceError(cause: "Worker operation journal is unreadable: " + error.localizedDescription) }
    }
    func save(in directory: URL, writer: Writer = RequestJournalWriter.write) throws {
        do {
            let bytes = try JSONEncoder().encode(self)
            guard bytes.count <= CatalogLimits.headBytes else { throw RequestWorkerEvidenceError(cause: "Worker retry state exceeds 64 KiB.") }
            try writer(bytes, directory.appendingPathComponent(Self.filename))
        } catch { throw RequestWorkerEvidenceError(cause: "Cannot persist worker retry state: " + error.localizedDescription) }
    }
    private static func configurationBytes(in directory: URL) throws -> Data? {
        guard RequestProcessIdentity.evidenceExists(directory.appendingPathComponent("configuration.json")) else { return nil }
        return try BoundedCatalogReader(root: directory).read("configuration.json", limit: CatalogLimits.headBytes).bytes
    }
    private static func configurationObject(_ data: Data) throws -> [String: Any] {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequestWorkerEvidenceError(cause: "Worker configuration is invalid.")
        }
        if let id = value["workerOperationID"], !(id is String && UUID(uuidString: id as! String) != nil) {
            throw RequestWorkerEvidenceError(cause: "Worker operation identity is invalid.")
        }
        if let repository = value["repository"] as? String {
            value["repository"] = RequestPaths.canonical(URL(fileURLWithPath: repository))
        }
        return value
    }
    private static func operationID(_ object: [String: Any]) -> UUID? {
        (object["workerOperationID"] as? String).flatMap(UUID.init(uuidString:))
    }
    static func encodedConfiguration(_ configuration: ShaderRequestConfiguration, id: UUID?) throws -> Data {
        var object = try configurationObject(JSONEncoder().encode(configuration))
        if let id { object["workerOperationID"] = id.uuidString }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
    static func expectedID(in directory: URL) throws -> UUID? {
        do { return try configurationBytes(in: directory).map { operationID(try configurationObject($0)) } ?? nil }
        catch { throw RequestWorkerEvidenceError(cause: "Worker operation identity is unreadable: " + error.localizedDescription) }
    }
    /// Call only after process reconciliation, while holding checkout execution ownership.
    private mutating func finishBinding(in directory: URL, writer: Writer) throws {
        guard let binding else { return }
        let current = try Self.configurationBytes(in: directory)
        guard current == binding.previous || current == binding.replacement else {
            throw RequestWorkerEvidenceError(cause: "Worker configuration differs from both recorded transition states.")
        }
        if current != binding.replacement { try writer(binding.replacement, directory.appendingPathComponent("configuration.json")) }
        self.binding = nil
        try save(in: directory, writer: writer)
    }
    private static func rotate(mode: String, configuration: ShaderRequestConfiguration, in directory: URL, id: UUID = UUID(), writer: Writer) throws -> Self {
        let previous = try configurationBytes(in: directory)
        var value = Self(id: id, mode: mode, target: Target(configuration))
        value.binding = Binding(predecessor: try previous.map { operationID(try configurationObject($0)) } ?? nil,
                                previous: previous, replacement: try encodedConfiguration(configuration, id: value.id))
        try value.save(in: directory, writer: writer)
        try value.finishBinding(in: directory, writer: writer)
        return value
    }
    static func begin(mode: String, configuration: ShaderRequestConfiguration, in directory: URL,
                      replacingInitialMaintenance: Bool = false, writer: Writer = RequestJournalWriter.write) throws -> Self {
        var saved = try read(in: directory)
        if var pending = saved, pending.binding != nil {
            guard pending.target == Target(configuration) || (replacingInitialMaintenance && pending.phase == .initial && ["preflight", "publication"].contains(pending.mode)) else { throw RequestWorkerEvidenceError(cause: "Pending operation belongs to another checkout.") }
            try pending.finishBinding(in: directory, writer: writer); saved = pending
        }
        if let expected = try expectedID(in: directory), expected != saved?.id {
            throw RequestWorkerEvidenceError(cause: "Worker retry journal is missing or belongs to another operation. Use explicit Retry Recovery or detach while retaining files; automatic retries remain blocked.")
        }
        if var saved, saved.mode == mode, saved.phase != .complete {
            if replacingInitialMaintenance, saved.phase == .initial, ["preflight", "publication"].contains(mode),
               let bytes = try configurationBytes(in: directory), try !matches(bytes, configuration: configuration, id: saved.id) {
                return try rotate(mode: mode, configuration: configuration, in: directory, writer: writer)
            }
            guard saved.target == nil || saved.target == Target(configuration) else {
                throw RequestWorkerEvidenceError(cause: "Worker operation belongs to another checkout; retire it before replacement.")
            }
            if saved.phase == .retryRunning { saved.phase = .paused; try saved.save(in: directory, writer: writer) }
            guard saved.phase != .paused else {
                throw RequestWorkerEvidenceError(cause: "The automatic supervision retry was exhausted or interrupted. Retry recovery manually to resume preserved work.")
            }
            // Legacy bound configurations can differ in JSON encoding, but not in content.
            let existing = try configurationBytes(in: directory)
            if let existing {
                guard try matches(existing, configuration: configuration, id: saved.id) else {
                    throw RequestWorkerEvidenceError(cause: "Worker configuration changed during an unfinished operation. Retry recovery explicitly.")
                }
            } else {
                // A legacy journal created before its first launch has no binding yet.
                saved.formatVersion = 2; saved.target = Target(configuration)
                saved.binding = Binding(predecessor: nil, previous: nil, replacement: try encodedConfiguration(configuration, id: saved.id))
                try saved.save(in: directory, writer: writer); try saved.finishBinding(in: directory, writer: writer)
            }
            return saved
        }
        return try rotate(mode: mode, configuration: configuration, in: directory, writer: writer)
    }
    static func restartPaused(in directory: URL, configuration: ShaderRequestConfiguration? = nil,
                              repairLegacyMismatch: Bool = false, writer: Writer = RequestJournalWriter.write) throws {
        guard var saved = try read(in: directory) else { return }
        if saved.binding != nil { try saved.finishBinding(in: directory, writer: writer) }
        let expected = try expectedID(in: directory)
        let mismatch = expected != nil && expected != saved.id
        guard !mismatch || (repairLegacyMismatch && saved.formatVersion == 1) else {
            throw RequestWorkerEvidenceError(cause: "Worker operation binding does not match; explicit legacy recovery or Detach is required.")
        }
        let bytes = try configurationBytes(in: directory)
        var configurationChanged = false
        if let configuration, let bytes {
            let original = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: bytes)
            guard Target(original) == Target(configuration) else { throw RequestWorkerEvidenceError(cause: "Recovery configuration belongs to another checkout.") }
            configurationChanged = try !matches(bytes, configuration: configuration, id: saved.id)
        }
        guard saved.phase == .paused || saved.phase == .retryRunning || mismatch || configurationChanged else { return }
        let replacement: ShaderRequestConfiguration
        if let configuration { replacement = configuration }
        else if let bytes { replacement = try JSONDecoder().decode(ShaderRequestConfiguration.self, from: bytes) }
        else { throw RequestWorkerEvidenceError(cause: "Saved checkout configuration is required to restart this operation.") }
        _ = try rotate(mode: saved.mode, configuration: replacement, in: directory, writer: writer)
    }
    static func matches(_ bytes: Data, configuration: ShaderRequestConfiguration, id: UUID?) throws -> Bool {
        try JSONSerialization.data(withJSONObject: configurationObject(bytes), options: .sortedKeys) == encodedConfiguration(configuration, id: id)
    }
    /// Explicit, settled recovery: replay exactly the recorded binding replacement.
    static func repair(in directory: URL, mode: String, previous: ShaderRequestConfiguration,
                       corrected: ShaderRequestConfiguration, oldID: UUID?, newID: UUID, repairLegacyMismatch: Bool = false) throws {
        if var saved = try read(in: directory) {
            if saved.id == newID {
                try saved.finishBinding(in: directory, writer: RequestJournalWriter.write)
                guard let bytes = try configurationBytes(in: directory), try matches(bytes, configuration: corrected, id: newID) else {
                    throw RequestWorkerEvidenceError(cause: "Repaired configuration conflicts with its durable intent.")
                }
                return
            }
            guard saved.id == oldID else { throw RequestWorkerOwnershipError() }
            try saved.finishBinding(in: directory, writer: RequestJournalWriter.write)
            let expected = try expectedID(in: directory)
            guard (expected == saved.id || (repairLegacyMismatch && saved.formatVersion == 1)),
                  let bytes = try configurationBytes(in: directory), try matches(bytes, configuration: previous, id: expected),
                  saved.target == nil || saved.target == Target(previous), Target(previous) == Target(corrected) else {
                throw RequestWorkerEvidenceError(cause: "Configuration repair no longer matches its recorded predecessor.")
            }
        } else {
            guard oldID == nil, try expectedID(in: directory) == nil else { throw RequestWorkerOwnershipError() }
            if let bytes = try configurationBytes(in: directory), try !matches(bytes, configuration: previous, id: nil) {
                throw RequestWorkerOwnershipError()
            }
        }
        _ = try rotate(mode: mode, configuration: corrected, in: directory, id: newID, writer: RequestJournalWriter.write)
    }
    static func createRepaired(in directory: URL, mode: String, configuration: ShaderRequestConfiguration, id: UUID) throws {
        if var current = try read(in: directory) {
            guard current.id == id else { throw RequestWorkerOwnershipError() }
            try current.finishBinding(in: directory, writer: RequestJournalWriter.write)
            guard let bytes = try configurationBytes(in: directory), try matches(bytes, configuration: configuration, id: id) else { throw RequestWorkerOwnershipError() }
        } else {
            guard try configurationBytes(in: directory) == nil else { throw RequestWorkerOwnershipError() }
            _ = try rotate(mode: mode, configuration: configuration, in: directory, id: id, writer: RequestJournalWriter.write)
        }
    }
    static func retire(in directory: URL) throws {
        guard var saved = try read(in: directory) else { return }
        try saved.finishBinding(in: directory, writer: RequestJournalWriter.write)
        guard try expectedID(in: directory) == saved.id else { throw RequestWorkerEvidenceError(cause: "Cannot retire an unverified operation binding.") }
        saved.phase = .complete; try saved.save(in: directory)
    }
    static func validateLaunch(id: UUID, configuration: ShaderRequestConfiguration, in directory: URL) throws {
        guard let saved = try read(in: directory), saved.id == id, saved.binding == nil,
              saved.phase == .initial || saved.phase == .retryRunning,
              try expectedID(in: directory) == id,
              let bytes = try configurationBytes(in: directory),
              try matches(bytes, configuration: configuration, id: id) else {
            throw RequestWorkerEvidenceError(cause: "Worker launch does not have a committed configuration binding.")
        }
    }
}

nonisolated enum RequestJournalWriter {
    static func archive(in directory: URL, id: UUID) throws {
        guard RequestProcessIdentity.evidenceExists(directory) else { return }
        let root = open(RequestPaths.canonical(directory), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(root) }
        let name = "detached-" + id.uuidString
        if mkdirat(root, name, 0o700) != 0, errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let archive = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard archive >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(archive) }
        guard fsync(root) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        for file in ["process.json", "children.json", "supervision.json", RequestWorkerOperation.filename, "configuration.json"] {
            var info = stat()
            if fstatat(root, file, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if fstatat(archive, file, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                throw RequestWorkerEvidenceError(cause: "Detachment archive conflicts with a remaining marker: " + file)
            }
            guard renameat(root, file, archive, file) == 0, fsync(archive) == 0, fsync(root) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        // Replay also commits moves whose preceding fsync failed after rename.
        guard fsync(archive) == 0, fsync(root) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    static func appendDiagnostic(_ detail: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Data((detail + "\n").utf8))
    }
    /// Also fsync an already-absent file's parent to finish an interrupted removal.
    static func remove(_ file: URL) throws {
        if unlink(file.path) != 0, errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    static func write(_ data: Data, to file: URL) throws {
        let directory = URL(fileURLWithPath: RequestPaths.canonical(file.deletingLastPathComponent()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".journal-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, directory.appendingPathComponent(file.lastPathComponent).path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
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
        var archiveID: UUID?
        var configurationRepair: ConfigurationRepair?
        var maintenanceRepair: MaintenanceRepair?
        var primaryDiagnostic: String?
        var secondaryDiagnostics: [String]?
        static func bounded(_ text: String, bytes: Int) -> String {
            var result = text
            if result.utf8.count > bytes {
                result = String(decoding: result.utf8.prefix(bytes), as: UTF8.self)
                while result.utf8.count > bytes || result.last == "\u{fffd}" { result.removeLast() }
            }
            return result
        }
        mutating func appendDiagnostic(_ detail: String) {
            let primary = Self.bounded(primaryDiagnostic ?? message, bytes: 8192)
            primaryDiagnostic = primary
            let bounded = Self.bounded(detail, bytes: 2048)
            var additional = secondaryDiagnostics ?? []
            if Self.bounded(detail, bytes: 8192) != primary && !additional.contains(bounded) { additional.append(bounded) }
            secondaryDiagnostics = Array(additional.suffix(8))
            message = ([primary] + (secondaryDiagnostics ?? []).map { "Additional recovery error: " + $0 }).joined(separator: "\n")
        }
    }
    struct ConfigurationRepair: Codable, Sendable {
        var previous: ShaderRequestConfiguration
        var corrected: ShaderRequestConfiguration
        var requestIDs: [UUID]
        var updatePreferences: Bool
        var version: Int? = nil
        var participants: [Participant]? = nil
        var preferences: Change? = nil
        struct Change: Codable, Sendable { var previous: ShaderRequestConfiguration; var corrected: ShaderRequestConfiguration }
        struct Participant: Codable, Sendable {
            var requestID: UUID
            var change: Change
            var mode: String
            var oldID: UUID?
            var newID = UUID()
        }
        func applying(to current: ShaderRequestConfiguration, primary: Bool = false) -> ShaderRequestConfiguration {
            var result = current
            if primary || RequestPaths.canonical(URL(fileURLWithPath: current.repository)) == RequestPaths.canonical(URL(fileURLWithPath: previous.repository)) { result.repository = corrected.repository }
            if primary || current.python == previous.python { result.python = corrected.python }
            if primary || current.git == previous.git { result.git = corrected.git }
            return result
        }
    }
    struct MaintenanceRepair: Codable, Sendable {
        var operation: RequestWorkerOperation
        var configuration: ShaderRequestConfiguration
        var archiveID = UUID()
        var replacementID = UUID()
    }
    var formatVersion = 1
    var legacyMigrationComplete = false
    var entries: [String: Entry] = [:]
    mutating func encoded() throws -> Data {
        for key in entries.keys {
            let detail = entries[key]!.primaryDiagnostic ?? entries[key]!.message
            entries[key]?.appendDiagnostic(detail)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var bytes = try encoder.encode(self)
        if bytes.count > CatalogLimits.manifestBytes {
            for key in entries.keys {
                var entry = entries[key]!
                entry.secondaryDiagnostics = []; entry.message = entry.primaryDiagnostic ?? "Checkout recovery required"
                entries[key] = entry
            }
            bytes = try encoder.encode(self)
        }
        if bytes.count > CatalogLimits.manifestBytes {
            for key in entries.keys {
                var entry = entries[key]!
                entry.message = Entry.bounded(entry.primaryDiagnostic ?? entry.message, bytes: 256)
                entry.primaryDiagnostic = nil; entry.secondaryDiagnostics = nil
                entries[key] = entry
            }
            bytes = try encoder.encode(self)
        }
        guard bytes.count <= CatalogLimits.manifestBytes else { throw RequestWorkerEvidenceError(cause: "Recovery metadata exceeds its 2 MiB capacity. Retain the last good journal and resolve existing recovery entries before accepting work.") }
        return bytes
    }
}
#endif
