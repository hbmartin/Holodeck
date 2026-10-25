#if os(macOS)
import Foundation

/// One ordered disk owner. Critical callers await publication; progress may coalesce.
nonisolated final class RequestPersistence: @unchecked Sendable {
    struct File: Sendable { let url: URL; let bytes: Data }
    struct Snapshot: Sendable { let revision: UInt64; let files: [File] }
    private let queue = DispatchQueue(label: "Holodeck.request-persistence", qos: .utility)
    private let recoveryWriter: @Sendable (Data, URL) throws -> Void
    private var committed: [URL: Data] = [:]
    private var failure: Error?
    private var writes: [String: Int] = [:]
    private var applied: UInt64 = 0
    private var progress: Snapshot?
    private var progressScheduled = false
    init(recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = { try RequestJournalWriter.write($0, to: $1) }) {
        self.recoveryWriter = recoveryWriter
    }
    private func apply(_ snapshot: Snapshot) throws {
        if let failure { throw failure }
        guard snapshot.revision > applied else { return }
        do {
            for file in snapshot.files {
                if committed[file.url] == file.bytes { continue }
                if file.url.lastPathComponent == "recovery.json" { try recoveryWriter(file.bytes, file.url) }
                else { try RequestJournalWriter.write(file.bytes, to: file.url) }
                writes[file.url.lastPathComponent, default: 0] += 1
                committed[file.url] = file.bytes
            }
            applied = snapshot.revision
        } catch {
            committed.removeAll() // A failure may follow rename but precede directory synchronization.
            failure = error; throw error
        }
    }
    func commit(_ snapshot: Snapshot, retainingEvidence: Bool = false) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let pending = progress, pending.revision <= snapshot.revision { progress = nil }
                let retainedFailure = failure
                if retainingEvidence, snapshot.files.allSatisfy({ $0.url.lastPathComponent == "recovery.json" }) { failure = nil }
                do {
                    try apply(snapshot)
                    if let retainedFailure { failure = retainedFailure }
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func enqueueProgress(_ snapshot: Snapshot, failed: @escaping @Sendable (Error) -> Void) {
        queue.async { [self] in
            if let failure { failed(failure); return }
            if progress == nil || progress!.revision < snapshot.revision { progress = snapshot }
            guard !progressScheduled else { return }
            progressScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [self] in
                progressScheduled = false
                guard let pending = progress else { return }
                progress = nil
                do { try apply(pending) } catch { failed(error) }
            }
        }
    }
    func statistics() async -> [String: Int] {
        await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: writes) } }
    }
    func resumeAfterExplicitRecovery() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in failure = nil; committed.removeAll(); progress = nil; continuation.resume() }
        }
    }
    /// Other critical files share the ordering barrier, without retaining their bytes in the cache.
    func write(_ bytes: Data, to file: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    if let pending = progress { progress = nil; try apply(pending) }
                    try RequestJournalWriter.write(bytes, to: file)
                    continuation.resume()
                } catch { failure = error; continuation.resume(throwing: error) }
            }
        }
    }
    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
#endif
