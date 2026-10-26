#if os(macOS)
import Foundation
import Darwin

nonisolated enum RequestStorageContext {
    @TaskLocal static var mutation: UUID?
}

/// One ordered disk owner. Before-images are deliberately retained only in this process.
nonisolated final class RequestPersistence: @unchecked Sendable {
    struct File: Sendable {
        let url: URL
        let encode: @Sendable () throws -> Data
        init(url: URL, bytes: Data) { self.url = url; self.encode = { bytes } }
        init(url: URL, encode: @escaping @Sendable () throws -> Data) { self.url = url; self.encode = encode }
        init<T: Encodable & Sendable>(url: URL, value: T) {
            self.init(url: url) {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return try encoder.encode(value)
            }
        }
    }
    struct Snapshot: Sendable { let revision: UInt64; let files: [File] }
    struct Fault: Codable, Sendable, LocalizedError {
        let id: UUID
        let generation: UInt64
        let operation: String
        var paths: [String]
        let primary: String
        var secondary: [String] = []
        var manualRepairRequired: Bool?
        var expected: [String: String] = [:] // SHA-256, or "absent"; never contains rollback bytes.
        var errorDescription: String? {
            "Storage recovery required for " + operation + ": " + primary +
            (paths.isEmpty ? "" : " Affected files: " + paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")) +
            (secondary.isEmpty ? "" : " Additional storage errors: " + secondary.joined(separator: "; "))
        }
    }
    private enum Image: Sendable {
        case absent, file(Data)
        var bytes: Data? { if case .file(let bytes) = self { return bytes }; return nil }
        var hash: String { bytes.map(CatalogHash.sha256) ?? "absent" }
    }
    private struct Transaction { let operation: String; var before: [URL: Image] = [:]; var candidates: [URL: Set<String>] = [:] }
    private let queue = DispatchQueue(label: "Holodeck.request-persistence", qos: .utility)
    private let recoveryWriter: @Sendable (Data, URL) throws -> Void
    private let directory: URL?
    private var committed: [URL: Data] = [:]
    private var failure: Fault?
    private var generation: UInt64 = 0
    private var undo: [URL: Image] = [:], candidates: [URL: Set<String>] = [:]
    private var transactions: [UUID: Transaction] = [:]
    private var recoveryAllowed = false
    private var writes: [String: Int] = [:]
    private var applied: [URL: UInt64] = [:]
    private var encodings = 0
    private struct Pending { let revision: UInt64; let file: File }
    private var progress: [URL: Pending] = [:]
    private var progressScheduled = false
    init(directory: URL? = nil, recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = { try RequestJournalWriter.write($0, to: $1) }) {
        self.directory = directory; self.recoveryWriter = recoveryWriter
    }
    private var faultFile: URL? { directory?.appendingPathComponent("storage-recovery.json") }
    private func image(_ file: URL) throws -> Image {
        guard RequestProcessIdentity.evidenceExists(file) else { return .absent }
        return .file(try BoundedCatalogReader(root: file.deletingLastPathComponent()).read(file.lastPathComponent, limit: 128 * 1024 * 1024).bytes)
    }
    private func summarize() {
        guard var fault = failure else { return }
        fault.expected = Dictionary(uniqueKeysWithValues: undo.map { ($0.key.path, $0.value.hash) })
        failure = fault
        guard let file = faultFile else { return }
        do {
            var bytes = try JSONEncoder().encode(fault)
            if bytes.count > 65536 {
                fault.expected = [:]; fault.paths = Array(fault.paths.prefix(16)).map { RequestRecoveryStore.Entry.bounded($0, bytes: 2048) }
                fault.secondary = []; fault.manualRepairRequired = true
                bytes = try JSONEncoder().encode(fault)
            }
            guard bytes.count <= 65536 else { return }
            try RequestJournalWriter.write(bytes, to: file)
        }
        catch { /* Storage may be unavailable. RAM evidence and the blocking gate remain. */ }
    }
    private func fail(_ error: Error, operation: String, files: [URL], before: [URL: Image], proposed: [URL: Set<String>]) -> Fault {
        if let previous = failure {
            if error is Fault { return previous }
            generation &+= 1
            var next = Fault(id: UUID(), generation: generation, operation: previous.operation,
                paths: Array(Set(previous.paths + files.map(\.path))).sorted(), primary: previous.primary)
            next.secondary = Array((previous.secondary + [RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 2048)]).suffix(8))
            failure = next; recoveryAllowed = false; summarize(); return failure!
        }
        generation &+= 1
        failure = Fault(id: UUID(), generation: generation, operation: operation, paths: files.map(\.path).sorted(),
            primary: RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192))
        undo = before; candidates = proposed; recoveryAllowed = false
        summarize()
        return failure!
    }
    private func replace(_ bytes: Data, at file: URL) throws {
        if file.lastPathComponent == "recovery.json" { try recoveryWriter(bytes, file) }
        else { try RequestJournalWriter.write(bytes, to: file) }
        writes[file.lastPathComponent, default: 0] += 1
        if ["journal.json", "recovery.json", "detached-checkouts.json"].contains(file.lastPathComponent) { committed[file] = bytes }
    }
    private func apply(_ snapshot: Snapshot, transaction: UUID? = nil, retainingEvidence: Bool = false) throws {
        if retainingEvidence, !snapshot.files.allSatisfy({ $0.url.lastPathComponent == "recovery.json" }) { throw RequestWorkerOwnershipError() }
        if let failure, !recoveryAllowed && !retainingEvidence { throw failure }
        let files = snapshot.files.filter { snapshot.revision > applied[$0.url, default: 0] }
        var before: [URL: Image] = [:], proposed: [URL: Data] = [:], encoded: [URL: Data] = [:]
        do {
            for file in files {
                encodings += 1; encoded[file.url] = try file.encode()
                guard committed[file.url] != encoded[file.url] else { continue }
                before[file.url] = try committed[file.url].map(Image.file) ?? image(file.url)
                proposed[file.url] = encoded[file.url]
                if let transaction, transactions[transaction]?.before[file.url] == nil { transactions[transaction]?.before[file.url] = before[file.url] }
                if let transaction, let bytes = encoded[file.url] { transactions[transaction]?.candidates[file.url, default: []].insert(CatalogHash.sha256(bytes)) }
            }
            for file in files {
                if let bytes = proposed[file.url] { try replace(bytes, at: file.url) }
                applied[file.url] = snapshot.revision
            }
            if files.allSatisfy({ $0.url.lastPathComponent == "recovery.json" }) {
                // Durable recovery/Detach intent is independent of a caller's rejected mutation.
                for id in transactions.keys {
                    for (url, bytes) in encoded { transactions[id]?.before[url] = .file(bytes); transactions[id]?.candidates[url] = [CatalogHash.sha256(bytes)] }
                }
                if failure != nil {
                    for (url, bytes) in encoded { undo[url] = .file(bytes); candidates[url] = [CatalogHash.sha256(bytes)] }
                    summarize()
                }
            }
        } catch {
            committed.removeAll()
            let tx = transaction.flatMap { transactions[$0] }
            throw fail(error, operation: tx?.operation ?? "request metadata", files: files.map(\.url), before: tx?.before ?? before, proposed: tx?.candidates ?? proposed.mapValues { [CatalogHash.sha256($0)] })
        }
    }
    private func drainProgress() throws {
        let pending = progress; progress = [:]
        for revision in Set(pending.values.map(\.revision)).sorted() {
            let files = pending.values.filter { $0.revision == revision }.map(\.file).sorted {
                if $0.url.lastPathComponent == "recovery.json" { return true }
                if $1.url.lastPathComponent == "recovery.json" { return false }
                return $0.url.path < $1.url.path
            }
            try apply(.init(revision: revision, files: files))
        }
    }
    func begin(_ id: UUID, operation: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async { [self] in
            if let failure { c.resume(throwing: failure) } else { transactions[id] = .init(operation: operation); c.resume() }
        } }
    }
    func accept(_ id: UUID) async {
        await withCheckedContinuation { c in queue.async { [self] in transactions[id] = nil; c.resume() } }
    }
    /// The caller has already durably accepted this intent. Advancing its RAM
    /// rollback boundary cannot reject it, even if a separate fault just arrived.
    func checkpoint(_ id: UUID, operation: String) async {
        await withCheckedContinuation { c in queue.async { [self] in transactions[id] = .init(operation: operation); c.resume() } }
    }
    private func restore(_ images: [URL: Image], proposed: [URL: Set<String>]) throws {
        for (file, old) in images.sorted(by: { $0.key.path < $1.key.path }) {
            let current = try image(file)
            guard current.hash == old.hash || proposed[file]?.contains(current.hash) == true || current.bytes == nil else {
                throw RequestWorkerEvidenceError(cause: "Storage file changed outside the rejected operation: " + file.path)
            }
            if current.hash == old.hash { continue }
            if let bytes = old.bytes { try replace(bytes, at: file) }
            else {
                try FileManager.default.removeItem(at: file)
                let fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
                guard fsync(fd) == 0 else { throw POSIXError(.EIO) }; committed[file] = nil
            }
        }
    }
    func reject(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async { [self] in
            guard let tx = transactions.removeValue(forKey: id) else { c.resume(); return }
            do { try restore(tx.before, proposed: tx.candidates); c.resume() }
            catch {
                if failure == nil { _ = fail(error, operation: tx.operation, files: Array(tx.before.keys), before: tx.before, proposed: tx.candidates) }
                else { _ = fail(error, operation: tx.operation, files: Array(tx.before.keys), before: tx.before, proposed: tx.candidates) }
                c.resume(throwing: failure!)
            }
        } }
    }
    func commit(_ snapshot: Snapshot, retainingEvidence: Bool = false, transaction: UUID? = RequestStorageContext.mutation) async throws {
        try await withCheckedThrowingContinuation { c in queue.async { [self] in
            for file in snapshot.files where progress[file.url].map({ $0.revision <= snapshot.revision }) == true { progress[file.url] = nil }
            do { try apply(snapshot, transaction: transaction, retainingEvidence: retainingEvidence); c.resume() }
            catch { c.resume(throwing: error) }
        } }
    }
    func enqueueProgress(_ snapshot: Snapshot, failed: @escaping @Sendable (Error) -> Void) {
        queue.async { [self] in
            if let failure { failed(failure); return }
            for file in snapshot.files where snapshot.revision > applied[file.url, default: 0] && snapshot.revision > (progress[file.url]?.revision ?? 0) {
                progress[file.url] = Pending(revision: snapshot.revision, file: file)
            }
            guard !progressScheduled else { return }; progressScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
                progressScheduled = false
                do { try drainProgress() } catch { failed(error) }
            }
        }
    }
    func statistics() async -> [String: Int] {
        await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: writes.merging(["encodings": encodings, "retainedBytes": committed.values.reduce(0) { $0 + $1.count }]) { _, value in value }) } }
    }
    func fault() async -> Fault? {
        await withCheckedContinuation { c in queue.async { [self] in c.resume(returning: failure) } }
    }
    func loadFault() async throws -> Fault? {
        try await perform { [self] in
            if let file = faultFile, RequestProcessIdentity.evidenceExists(file) {
                do {
                    failure = try JSONDecoder().decode(Fault.self, from: BoundedCatalogReader(root: file.deletingLastPathComponent()).read(file.lastPathComponent, limit: 65536).bytes)
                } catch {
                    failure = Fault(id: UUID(), generation: generation + 1, operation: "read storage recovery evidence", paths: [file.path],
                        primary: "Storage recovery evidence is unreadable. Retain it and repair the journal manually: " + error.localizedDescription, manualRepairRequired: true)
                }
                generation = failure!.generation
            }
            return failure
        }
    }
    func restoreForRecovery() async throws -> UUID? {
        try await perform { [self] in
            guard let fault = failure else { return nil }
            guard fault.manualRepairRequired != true else { throw RequestWorkerEvidenceError(cause: fault.localizedDescription) }
            if undo.isEmpty {
                for path in fault.paths {
                    guard let directory, RequestPaths.canonical(URL(fileURLWithPath: path)).hasPrefix(RequestPaths.canonical(directory) + "/") else { throw RequestWorkerOwnershipError() }
                    _ = try image(URL(fileURLWithPath: path))
                }
                for (path, expected) in fault.expected {
                    guard let directory, RequestPaths.canonical(URL(fileURLWithPath: path)).hasPrefix(RequestPaths.canonical(directory) + "/"), try image(URL(fileURLWithPath: path)).hash == expected else {
                        throw RequestWorkerEvidenceError(cause: "In-session rollback data is unavailable. Restore the accepted journal files manually before retrying storage recovery: " + path)
                    }
                }
            } else {
                do { try restore(undo, proposed: candidates) }
                catch { throw fail(error, operation: fault.operation, files: undo.keys.sorted { $0.path < $1.path }, before: undo, proposed: candidates) }
            }
            recoveryAllowed = true; committed.removeAll(); progress = [:]
            return fault.id
        }
    }
    func finishRecovery(_ expected: UUID?) async throws {
        try await perform { [self] in
            guard failure?.id == expected else { throw RequestWorkerEvidenceError(cause: "Storage recovery was superseded by a newer fault.") }
            if let file = faultFile, RequestProcessIdentity.evidenceExists(file) {
                do {
                    try FileManager.default.removeItem(at: file)
                    let fd = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }; guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
                } catch { throw fail(error, operation: failure?.operation ?? "finish storage recovery", files: [file], before: undo, proposed: candidates) }
            }
            failure = nil; undo = [:]; candidates = [:]; recoveryAllowed = false
        }
    }
    func resumeAfterExplicitRecovery() async throws {
        let id = try await restoreForRecovery(); try await finishRecovery(id)
    }
    func write(_ bytes: Data, to file: URL, transaction: UUID? = RequestStorageContext.mutation) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in queue.async { [self] in
            if let failure, !recoveryAllowed { c.resume(throwing: failure); return }
            var before: [URL: Image] = [:]
            do {
                try drainProgress()
                before[file] = try committed[file].map(Image.file) ?? image(file)
                if let transaction, transactions[transaction]?.before[file] == nil { transactions[transaction]?.before[file] = before[file] }
                if let transaction { transactions[transaction]?.candidates[file, default: []].insert(CatalogHash.sha256(bytes)) }
                try replace(bytes, at: file); c.resume()
            } catch {
                let tx = transaction.flatMap { transactions[$0] }
                c.resume(throwing: fail(error, operation: tx?.operation ?? "write " + file.lastPathComponent, files: [file], before: tx?.before ?? before, proposed: tx?.candidates ?? [file: [CatalogHash.sha256(bytes)]]))
            }
        } }
    }
    /// Binding/archival coordinators retain their own durable intent; never roll those
    /// ownership transitions back as a side effect of rejecting caller preferences.
    func journal<T: Sendable>(_ operation: String, files: [URL], _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await perform { [self] in
            do { return try body() }
            catch {
                let value = error as NSError
                guard error is POSIXError || value.domain == NSCocoaErrorDomain else { throw error }
                throw fail(error, operation: operation, files: files, before: [:], proposed: [:])
            }
        }
    }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async {
            do { c.resume(returning: try operation()) } catch { c.resume(throwing: error) }
        } }
    }
}
#endif
