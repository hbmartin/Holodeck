#if os(macOS)
import Foundation

struct TrustedRecoveryTaskClosed: LocalizedError, Sendable {
    var errorDescription: String? { "The cancelled recovery phase is still settling; join its successor after settlement." }
}
/// Independent waiters share preparation; the last cancelled waiter stops only
/// work which has not crossed its existing noncancellable acceptance boundary.
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

/// Each waiter owns cancellation; completing a boundary never cancels its owner.
nonisolated final class TrustedCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [UUID: RequestPersistence.CommitTicket<Void>] = [:]
    var waiterCount: Int { lock.withLock { waiters.count } }
    func wait(cancellable: Bool = true) async throws {
        let id = UUID(), receipt = RequestPersistence.CommitTicket<Void>()
        lock.withLock {
            if finished { receipt.complete(.success(())) }
            else { waiters[id] = receipt }
        }
        defer { lock.withLock { _ = waiters.removeValue(forKey: id) } }
        try await receipt.value(cancellable: cancellable)
    }
    func finish() {
        let pending = lock.withLock {
            finished = true
            let pending = Array(waiters.values); waiters.removeAll(); return pending
        }
        pending.forEach { $0.complete(.success(())) }
    }
}
/// Metadata preparation owns its binding only until the local phase settles.
nonisolated final class TrustedLocalPreparation: Sendable {
    let serviceID: UUID
    let authority: UUID?
    let registration: UUID
    let attempt: UUID
    let generation: UInt64
    let requiresTrustedPass: Bool
    private let completion = TrustedCompletionSignal()
    init(serviceID: UUID, authority: UUID?, registration: UUID, attempt: UUID, generation: UInt64, consumerAuthority: UUID?) {
        self.serviceID = serviceID; self.authority = authority; self.registration = registration
        self.attempt = attempt; self.generation = generation
        requiresTrustedPass = consumerAuthority != nil && consumerAuthority == authority
    }
    var waiterCount: Int { completion.waiterCount }
    func wait(cancellable: Bool = true) async throws { try await completion.wait(cancellable: cancellable) }
    func finish() { completion.finish() }
}
struct TrustedLocalPreparationPending: Error, Sendable { let preparation: TrustedLocalPreparation }

/// The authority records this exact target before the service publishes it.
nonisolated final class TrustedTargetInstallation: @unchecked Sendable {
    let serviceID: UUID
    let authority: UUID
    let predecessorAuthority: UUID?
    let predecessorRegistration: UUID
    let registration: UUID
    private let lock = NSLock()
    private var published: Bool
    init(serviceID: UUID, authority: UUID, predecessorAuthority: UUID?, predecessorRegistration: UUID) {
        self.serviceID = serviceID; self.authority = authority
        self.predecessorAuthority = predecessorAuthority; self.predecessorRegistration = predecessorRegistration
        registration = predecessorAuthority == authority ? predecessorRegistration : UUID()
        published = predecessorAuthority == authority
    }
    var isPublished: Bool { lock.withLock { published } }
    func publish() { lock.withLock { published = true } }
}

struct TrustedDepartureRetirement: Sendable, Equatable {
    let serviceID: UUID
    let registration: UUID
    let authority: UUID?
    let metadataRevision: UInt64
    let ownershipGeneration: UInt64
    let recoveryGeneration: UInt64
    let executionID: UUID?
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
