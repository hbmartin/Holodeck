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
    var isFinished: Bool { lock.withLock { finished } }
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
/// Wait only for a boundary; cancellation never cancels its shared owner.
nonisolated enum TrustedBoundaryWait {
    static func run(changes: [TrustedCompletionSignal], _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            for signal in changes { group.addTask { try await signal.wait() } }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
struct TrustedDepartureYielded: LocalizedError, Sendable {
    var errorDescription: String? { "TV revocation has priority; authority handoff will resume after cancellation settles." }
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

/// A retirement batch is verified before it becomes an activation wait.
nonisolated final class TrustedWorkerRetirement: Sendable {
    let id = UUID()
    let executions: [UUID: UUID]
    let completion = TrustedCompletionSignal()
    init(_ executions: [UUID: UUID]) { self.executions = executions }
    func wait(or changed: TrustedCompletionSignal) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.completion.wait() }
            group.addTask { try await changed.wait() }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
struct TrustedWorkerRetirementPending: Error, Sendable { let retirement: TrustedWorkerRetirement }
struct TrustedRegistrationSuperseded: Error, Sendable {}
/// Supersession and the first binding mutation have one synchronous ordering point.
nonisolated final class TrustedRegistrationPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var superseded = false, admitted = false
    let changed = TrustedCompletionSignal()
    func supersede() {
        lock.withLock { if !admitted { superseded = true } }
        changed.finish()
    }
    func check() throws {
        try lock.withLock {
            if superseded { throw TrustedRegistrationSuperseded() }
            if !admitted && changed.isFinished { throw CancellationError() }
        }
    }
    func admit(_ action: () throws -> Void) throws {
        try lock.withLock {
            guard !superseded else { throw TrustedRegistrationSuperseded() }
            try action(); admitted = true
        }
    }
}

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

/// All ticket receipts observe one ownership generation. Consuming a ticket
/// cannot invalidate another authority's independently verified retirement.
nonisolated final class TrustedDepartureOwnership: Sendable {
    let evidence: TrustedDepartureRetirement.Evidence
    private let validity = TrustedInvalidationToken()
    init(_ evidence: TrustedDepartureRetirement.Evidence) { self.evidence = evidence }
    var isCurrent: Bool { validity.isCurrent }
    func invalidate() { validity.invalidate() }
    func admit(_ receipt: TrustedInvalidationToken) -> Bool {
        validity.withCurrent { receipt.consume() } ?? false
    }
}
nonisolated final class TrustedDepartureRetirement: Sendable {
    struct Evidence: Sendable, Equatable {
        let serviceID: UUID
        let registration: UUID
        let authority: UUID?
        let ownershipGeneration: UInt64
        let recoveryGeneration: UInt64
        let executionID: UUID?
        let processID: ObjectIdentifier?
    }
    let authority: UUID?
    let ticket: UUID
    let ownership: TrustedDepartureOwnership
    var evidence: Evidence { ownership.evidence }
    private let admission = TrustedInvalidationToken()
    init(_ ownership: TrustedDepartureOwnership, authority: UUID?, ticket: UUID) {
        self.ownership = ownership; self.authority = authority; self.ticket = ticket
    }
    var isCurrent: Bool { ownership.isCurrent && admission.isCurrent }
    func admit() -> Bool { ownership.admit(admission) }
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
    private let lock = NSLock()
    private var settling = false
    init(authority: TrustedApprovalsCoordinator, ticketID: UUID, serviceID: UUID, journal: URL?) {
        self.authority = authority; authorityID = authority.id; self.ticketID = ticketID; self.serviceID = serviceID; self.journal = journal
    }
    var isCurrent: Bool { token.isCurrent }
    var message: String {
        if lock.withLock({ settling }) {
            return "Authority departure " + ticketID.uuidString + " is settling retained recovery work. Retry Recovery waits for settlement; cancelling releases only this caller."
        }
        return "Authority departure " + ticketID.uuidString + " needs receipt recovery. Choose Retry Recovery; unverifiable receipts require manual repair."
    }
    func setSettling(_ value: Bool) -> Bool {
        lock.withLock { guard settling != value else { return false }; settling = value; return true }
    }
    func invalidate() { token.invalidate() }
    func retry() async throws {
        guard isCurrent else { return }
        guard let authority else { throw ShaderRequestError.unavailable(message + " The retained authority is unavailable; preserve its trusted approval evidence for manual repair.") }
        try await authority.recoverDeparture(serviceID: serviceID, ticket: ticketID)
    }
}
#endif
