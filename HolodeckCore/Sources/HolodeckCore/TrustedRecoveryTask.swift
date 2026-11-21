#if os(macOS)
import Foundation

/// Independent waiters share preparation; the last cancelled waiter stops only
/// work which has not crossed its existing noncancellable acceptance boundary.
nonisolated final class TrustedRecoveryTask<Value: Sendable>: @unchecked Sendable {
    private let task: Task<Value, Error>
    private let lock = NSLock()
    private var waiters: Set<UUID> = []
    var isCancelled: Bool { task.isCancelled }
    init(_ work: @escaping @Sendable () async throws -> Value) {
        task = Task { try await work() }
    }
    func value() async throws -> Value {
        try Task.checkCancellation()
        let id = UUID(), receipt = RequestPersistence.CommitTicket<Value>()
        lock.withLock { _ = waiters.insert(id) }
        return try await withTaskCancellationHandler {
            defer { remove(id, cancelling: false) }
            Task { [task] in
                do { receipt.complete(.success(try await task.value)) }
                catch { receipt.complete(.failure(error)) }
            }
            return try await receipt.value()
        } onCancel: { self.remove(id, cancelling: true) }
    }
    private func remove(_ id: UUID, cancelling: Bool) {
        let cancel = lock.withLock { waiters.remove(id) != nil && cancelling && waiters.isEmpty }
        if cancel { task.cancel() }
    }
}

struct TrustedLocalRecoveryReceipt: Sendable {
    let serviceID: UUID
    let registrationID: UUID
    let authority: UUID?
    let attemptID: UUID
    let generation: UInt64
    let metadataRevision: UInt64
    let ownershipGeneration: UInt64
}
#endif
