#if os(macOS)
import Foundation

/// Independent waiters share preparation; the last cancelled waiter stops only
/// work which has not crossed its existing noncancellable acceptance boundary.
struct TrustedRecoveryTaskClosed: LocalizedError, Sendable {
    var errorDescription: String? { "The cancelled recovery phase is still settling; join its successor after settlement." }
}
nonisolated final class TrustedRecoveryTask<Value: Sendable>: @unchecked Sendable {
    private let task: Task<Value, Error>
    private let lock = NSLock()
    private var waiters: [UUID: RequestPersistence.CommitTicket<Value>] = [:]
    private var result: Result<Value, Error>?
    private var admissionClosed = false
    private let beforeCancellation: @Sendable () -> Void
    var isCancelled: Bool { lock.withLock { admissionClosed } || task.isCancelled }
    var waiterCount: Int { lock.withLock { waiters.count } }
    /// A cancelled owner drains its admitted work without opening subscriptions.
    func settle() async { _ = await task.result }
    init(beforeCancellation: @escaping @Sendable () -> Void = {}, _ work: @escaping @Sendable () async throws -> Value) {
        self.beforeCancellation = beforeCancellation
        task = Task { try await work() }
        // One relay per shared phase, rather than a suspended Task per waiter.
        Task { [weak self, task] in
            do { self?.complete(.success(try await task.value)) }
            catch { self?.complete(.failure(error)) }
        }
    }
    struct Subscription: Sendable {
        fileprivate let owner: TrustedRecoveryTask
        fileprivate let id: UUID
        fileprivate let receipt: RequestPersistence.CommitTicket<Value>
        func value() async throws -> Value {
            try await withTaskCancellationHandler {
                defer { owner.remove(id, cancelling: false) }
                return try await receipt.value()
            } onCancel: { owner.remove(id, cancelling: true) }
        }
    }
    /// Subscribe synchronously before the admitting actor suspends. A cancellation
    /// cannot mistake another admitted, not-yet-scheduled waiter for no participants.
    func subscribe() -> Subscription {
        let id = UUID(), receipt = RequestPersistence.CommitTicket<Value>()
        lock.withLock {
            if let result { receipt.complete(result) }
            else if admissionClosed { receipt.complete(.failure(TrustedRecoveryTaskClosed())) }
            else { waiters[id] = receipt }
        }
        return .init(owner: self, id: id, receipt: receipt)
    }
    private func complete(_ value: Result<Value, Error>) {
        let pending = lock.withLock {
            result = value
            let pending = Array(waiters.values); waiters.removeAll(); return pending
        }
        pending.forEach { $0.complete(value) }
    }
    private func remove(_ id: UUID, cancelling: Bool) {
        let cancel = lock.withLock {
            guard waiters.removeValue(forKey: id) != nil, cancelling, waiters.isEmpty else { return false }
            admissionClosed = true
            return true
        }
        if cancel { beforeCancellation(); task.cancel() }
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
/// Local-only entry point remains callable after the target changed registration.
/// Its weak authority reference cannot keep an otherwise idle account alive.
nonisolated final class TrustedAuthorityRecoveryEndpoint: @unchecked Sendable {
    let authorityID: UUID
    let ticketID: UUID
    let serviceID: UUID
    let journal: URL?
    private weak var authority: TrustedApprovalsCoordinator?
    private let token = TrustedInvalidationToken()
    init(authority: TrustedApprovalsCoordinator, ticketID: UUID, serviceID: UUID, journal: URL?) {
        self.authority = authority; authorityID = authority.id; self.ticketID = ticketID; self.serviceID = serviceID; self.journal = journal
    }
    var isCurrent: Bool { token.isCurrent }
    var message: String { "Authority departure " + ticketID.uuidString + " needs receipt recovery. Choose Retry Recovery; unverifiable receipts require manual repair." }
    func invalidate() { token.invalidate() }
    func retry() async throws {
        guard isCurrent else { return }
        guard let authority else { throw ShaderRequestError.unavailable(message + " The retained authority is unavailable; preserve its trusted approval evidence for manual repair.") }
        try await authority.recoverDeparture(serviceID: serviceID, ticket: ticketID)
    }
}
#endif
