#if os(macOS)
import Foundation

/// A binding is revocable without an actor hop, including during transport teardown.
nonisolated final class TrustedOwnerPermit: @unchecked Sendable {
    let serverID: UUID
    let generation: UInt64
    let authority: UUID
    private let lock = NSLock()
    private var valid = true
    init(serverID: UUID, generation: UInt64, authority: UUID) {
        self.serverID = serverID; self.generation = generation; self.authority = authority
    }
    var isCurrent: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}

/// One authority per trusted backend. Replay belongs to the store, not its current transport.
actor TrustedApprovalsCoordinator {
    static let production = TrustedApprovalsCoordinator(
        read: { try LocalSecrets.read("mac-library-approved-tvs") },
        write: { try LocalSecrets.write($0, account: "mac-library-approved-tvs") })

    struct Snapshot: Sendable {
        let approvals: [String: ApprovedTV]
        let revocations: [RequestRevocationIntent]
        let diagnostic: String?
    }
    struct Binding: Sendable {
        let permit: TrustedOwnerPermit
        let service: ShaderRequestService?
    }
    enum BindingOutcome: Sendable { case accepted(Binding), superseded }
    struct Registration: Sendable {
        let generation: UInt64
        let completion: RequestPersistence.CommitTicket<BindingOutcome>
        func value() async throws -> BindingOutcome {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { completion.attach($0) }
            } onCancel: { completion.cancel() }
        }
    }
    struct Observation: Sendable {
        let requestedGeneration: UInt64
        let acceptedGeneration: UInt64?
        let queuedGeneration: UInt64?
        let preparingGeneration: UInt64?
        let mutationWaiters: Int
        let encodings: Int
        let writes: Int
        let transitionActive: Bool
    }
    struct Approval: Sendable {
        let record: ApprovedTV
        let token: String
    }
    struct Owner: Sendable {
        let serverID: UUID
        let service: ShaderRequestService?
        let changed: @Sendable (Snapshot, Binding) async -> Void
        let retired: @Sendable () async -> Void
        let beforeReplay: @Sendable (RequestRevocationIntent) async throws -> Void
    }
    private struct Request {
        let owner: Owner
        let registration: Registration
    }
    private struct Accepted { let owner: Owner; let binding: Binding }
    private struct Waiter {
        let id: UUID
        let mutation: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Failure: LocalizedError, Sendable {
        let primary: String
        private var secondary: [String] = []
        var message: String { ([primary] + secondary.map { "Additional trusted failure: " + $0 }).joined(separator: "\n") }
        var errorDescription: String? { message }
        init(_ error: Error) { primary = RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192) }
        func appending(_ error: Error) -> Self {
            let detail = RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 2048)
            guard detail != RequestRecoveryStore.Entry.bounded(primary, bytes: 2048), !secondary.contains(detail) else { return self }
            var result = self
            result.secondary = Array((secondary + [detail]).suffix(8)); return result
        }
    }
    nonisolated let id = UUID()
    private let read: @Sendable () throws -> Data?
    private let write: @Sendable (Data) throws -> Void
    private var envelope = TrustedTVApprovals()
    private var bytes: Data?
    private var loaded = false
    private var sequence: UInt64 = 0
    private var accepted: Accepted?
    private var service: ShaderRequestService?
    private var generation: UInt64 = 0
    private var pending: Request?
    private var preparing: UInt64?
    private var registrationTask: Task<Void, Never>?
    private var failedRegistration: Owner?
    private var lane: UUID?
    private var waiters: [Waiter] = []
    private var encodings = 0, writes = 0
    private var failures: [UUID: Failure] = [:]
    private var mutationFailure: (operation: UUID, message: String)?
    private var replayTask: Task<Void, Never>?
    private var replayWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var replayAll: [CheckedContinuation<Void, Error>] = []

    init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        self.read = read; self.write = write
    }
    var observation: Observation {
        .init(requestedGeneration: generation, acceptedGeneration: accepted?.binding.permit.generation,
              queuedGeneration: pending?.registration.generation, preparingGeneration: preparing,
              mutationWaiters: waiters.filter(\.mutation).count, encodings: encodings, writes: writes,
              transitionActive: lane != nil)
    }
    private var revision: TrustedRevocationRevision { .init(coordinator: id, sequence: sequence) }
    private var snapshot: Snapshot {
        .init(approvals: Dictionary(envelope.approvals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }), revocations: envelope.revocations, diagnostic: mutationFailure.map { "Trusted TV operation \($0.operation): " + $0.message })
    }
    static func unavailable(_ message: String) -> ShaderRequestError { .unavailable(message) }
    private func validate(_ permit: TrustedOwnerPermit) throws {
        guard permit.isCurrent, accepted?.binding.permit === permit else {
            throw Self.unavailable("This catalog server was replaced. Use its accepted replacement before changing TV access.")
        }
    }
    private func acquire(permit: TrustedOwnerPermit? = nil, cancellable: Bool = true,
                         registration: Bool = false, mutation: Bool = false) async throws -> UUID {
        let token = UUID()
        return try await withTaskCancellationHandler {
            while lane != nil || (!registration && pending != nil) {
                if cancellable { try Task.checkCancellation() }
                try await withCheckedThrowingContinuation { c in waiters.append(.init(id: token, mutation: mutation, continuation: c)) }
            }
            if cancellable { try Task.checkCancellation() }
            if let permit { try validate(permit) }
            lane = token; return token
        } onCancel: {
            if cancellable { Task { await self.cancelWaiter(token) } }
        }
    }
    private func cancelWaiter(_ token: UUID) {
        let cancelled = waiters.filter { $0.id == token }; waiters.removeAll { $0.id == token }
        cancelled.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }
    private func release(_ token: UUID) {
        precondition(lane == token)
        lane = nil
        let waiting = waiters; waiters.removeAll()
        waiting.forEach { $0.continuation.resume() }
    }
    /// Admission is synchronous on the authority actor; scheduling cannot reorder these generations.
    func register(_ owner: Owner, onlyIfVacant: Bool = false) throws -> Registration {
        if onlyIfVacant, accepted != nil || pending != nil || preparing != nil {
            throw Self.unavailable("Catalog server handoff is pending. Wait for its accepted binding.")
        }
        failedRegistration = nil
        generation &+= 1
        let receipt = Registration(generation: generation, completion: .init())
        pending?.registration.completion.complete(.success(.superseded))
        pending = Request(owner: owner, registration: receipt)
        if registrationTask == nil { registrationTask = Task { await self.drainRegistrations() } }
        return receipt
    }
    private func configure(_ target: ShaderRequestService) async {
        await target.registerRevocationCoordinator(id: id) { [weak self] in
            guard let self else { throw Self.unavailable("The trusted approval authority is unavailable.") }
            try await self.retry()
        }
    }
    private func retry() async throws {
        if let failedRegistration {
            let ticket = try register(failedRegistration)
            _ = try await ticket.value()
        }
        try await replay()
    }
    private func readFresh(target: ShaderRequestService?) async throws {
        do {
            let read = read
            let current = try await Task.detached { try read() }.value
            let candidate = try current.map(TrustedTVApprovals.decode) ?? TrustedTVApprovals()
            let next = sequence &+ (current == bytes ? 0 : 1)
            let revision = TrustedRevocationRevision(coordinator: id, sequence: next)
            if let target { try await target.loadTrustedRevocations(candidate.revocations, revision: revision) }
            if let service, service !== target { try await service.loadTrustedRevocations(candidate.revocations, revision: revision) }
            let changed = current != bytes
            envelope = candidate; bytes = current; sequence = next; loaded = true
            if changed { await notify() }
            let ids = Set(candidate.revocations.map(\.operationID)); failures = failures.filter { ids.contains($0.key) }
            if let target {
                for intent in candidate.revocations {
                    if let failure = failures[intent.operationID] { await target.revocationReplayFailed(failure, intent: intent, revision: revision) }
                }
            }
        } catch {
            loaded = false
            if let target { await target.revocationReplayFailed(error, revision: revision) }
            else if let service { await service.revocationReplayFailed(error, revision: revision) }
            throw error
        }
    }
    private func drainRegistrations() async {
        while pending != nil {
            let token = try! await acquire(cancellable: false, registration: true)
            guard let request = pending else { release(token); continue }
            pending = nil; preparing = request.registration.generation
            do {
                try request.registration.completion.check()
                if let target = request.owner.service { await configure(target) }
                try await readFresh(target: request.owner.service ?? service)
                try request.registration.completion.check()
                guard request.registration.generation == generation else {
                    request.registration.completion.complete(.success(.superseded)); preparing = nil; release(token); continue
                }
                try request.registration.completion.beginMutation()
                let prior = accepted
                let permit = TrustedOwnerPermit(serverID: request.owner.serverID, generation: request.registration.generation, authority: id)
                let binding = Binding(permit: permit, service: request.owner.service)
                prior?.binding.permit.invalidate()
                accepted = Accepted(owner: request.owner, binding: binding)
                if let target = request.owner.service { service = target }
                await request.owner.changed(snapshot, binding)
                if let prior, prior.owner.serverID != request.owner.serverID { await prior.owner.retired() }
                request.registration.completion.complete(.success(.accepted(binding)))
            } catch {
                if request.registration.generation == generation, !(error is CancellationError) { failedRegistration = request.owner }
                request.registration.completion.complete(.failure(error))
            }
            preparing = nil; release(token)
        }
        registrationTask = nil
    }
    private func ensureLoaded() async throws {
        if !loaded { try await readFresh(target: service) }
    }
    private func prepare(_ value: TrustedTVApprovals) throws -> Data {
        let encoded = try value.encoded(); encodings += 1; return encoded
    }
    private func persist(_ value: TrustedTVApprovals, bytes candidate: Data) async throws {
        let write = write
        try await Task.detached { try write(candidate) }.value
        acceptPersisted(value, bytes: candidate)
    }
    private func acceptPersisted(_ value: TrustedTVApprovals, bytes candidate: Data) {
        envelope = value; bytes = candidate; sequence &+= 1; writes += 1
        mutationFailure = nil
    }
    private func recordMutationFailure(_ error: Error, operation: UUID, context: String) async {
        mutationFailure = (operation, RequestRecoveryStore.Entry.bounded(context + ": " + error.localizedDescription, bytes: 8192))
        await notify()
    }
    private func notify() async {
        if let accepted { await accepted.owner.changed(snapshot, accepted.binding) }
    }
    func approve(_ permit: TrustedOwnerPermit,
                 proposal: @Sendable () async throws -> Approval?) async throws -> Approval? {
        let token = try await acquire(permit: permit, mutation: true)
        defer { release(token) }
        try await ensureLoaded(); try Task.checkCancellation()
        guard let proposal = try await proposal() else { return nil }
        try Task.checkCancellation(); try validate(permit)
        var value = envelope
        value.approvals.removeAll { $0.id == proposal.record.id }; value.approvals.append(proposal.record)
        let candidate = try prepare(value)
        try Task.checkCancellation()
        do { try await persist(value, bytes: candidate) }
        catch {
            await recordMutationFailure(error, operation: UUID(), context: "TV approval for " + proposal.record.id)
            throw error
        }
        await notify()
        return proposal
    }
    func revoke(_ device: String, permit: TrustedOwnerPermit,
                beforeCommit: @Sendable (RequestRevocationIntent) async throws -> Void) async throws {
        let token = try await acquire(permit: permit, mutation: true)
        let intent: RequestRevocationIntent
        do {
            try await ensureLoaded(); try Task.checkCancellation()
            let existing = envelope.revocations.first { $0.deviceID == device }
            guard envelope.approvals.contains(where: { $0.id == device }) || existing != nil else { release(token); return }
            intent = existing ?? .init(operationID: UUID(), deviceID: device)
            if envelope.approvals.contains(where: { $0.id == device }) {
                var value = envelope
                value.approvals.removeAll { $0.id == device }
                if existing == nil { value.revocations.append(intent) }
                let candidate = try prepare(value)
                try await service?.reserveRevocation(intent, revision: revision)
                do {
                    try await beforeCommit(intent); try Task.checkCancellation()
                    try await persist(value, bytes: candidate)
                } catch {
                    if !(error is CancellationError) {
                        await recordMutationFailure(error, operation: intent.operationID, context: "TV revocation for " + intent.deviceID)
                    }
                    await service?.cancelRevocationReservation(intent, revision: revision); throw error
                }
                await notify()
                try await service?.commitTrustedRevocation(intent, revision: revision)
            }
        } catch { release(token); throw error }
        release(token)
        try await replay(target: intent.operationID)
    }
    func replay(target: UUID? = nil) async throws {
        guard service != nil else { return }
        try await withCheckedThrowingContinuation { c in
            if let target {
                guard envelope.revocations.contains(where: { $0.operationID == target }) else { c.resume(); return }
                replayWaiters[target, default: []].append(c)
            } else { replayAll.append(c) }
            if replayTask == nil { replayTask = Task { await self.drainReplay() } }
        }
    }
    private func record(_ error: Error, intent: RequestRevocationIntent) async -> Failure {
        let failure = failures[intent.operationID]?.appending(error) ?? Failure(error)
        failures[intent.operationID] = failure
        await service?.revocationReplayFailed(failure, intent: intent, revision: revision)
        return failure
    }
    private func drainReplay() async {
        var attempted: Set<UUID> = [], failed: [UUID: Failure] = [:], inspect = true
        while true {
            let token = try! await acquire(cancellable: false)
            let intent: RequestRevocationIntent
            do {
                if inspect { try await readFresh(target: service); inspect = false }
                guard let next = envelope.revocations.first(where: { !attempted.contains($0.operationID) }) else {
                    await service?.revocationReplaySucceeded(revision: revision)
                    finishReplay(failed); release(token); return
                }
                intent = next; attempted.insert(intent.operationID)
            } catch {
                finishReplay(failed, unexpected: Failure(error)); release(token); return
            }
            let hook = accepted?.owner.beforeReplay
            release(token)
            do {
                try await hook?(intent)
                try await service?.applyTrustedRevocation(intent, revision: revision)
                let commit = try! await acquire(cancellable: false)
                do {
                    guard envelope.revocations.contains(intent) else { release(commit); continue }
                    var value = envelope; value.revocations.removeAll { $0.operationID == intent.operationID }
                    let candidate = try prepare(value), write = write
                    guard let service else { release(commit); continue }
                    try await service.acknowledgeTrustedRevocation(intent, revision: revision) { try write(candidate) }
                    acceptPersisted(value, bytes: candidate)
                    failures[intent.operationID] = nil
                    await notify()
                    let waiting = replayWaiters.removeValue(forKey: intent.operationID) ?? []
                    waiting.forEach { $0.resume() }
                } catch {
                    failed[intent.operationID] = await record(error, intent: intent)
                    release(commit); continue
                }
                release(commit)
            } catch {
                failed[intent.operationID] = await record(error, intent: intent)
            }
        }
    }
    private func finishReplay(_ failed: [UUID: Failure], unexpected: Failure? = nil) {
        replayTask = nil
        let waiting = replayWaiters; replayWaiters.removeAll()
        for (id, values) in waiting {
            for value in values {
                if let error = unexpected ?? failed[id] { value.resume(throwing: error) } else { value.resume() }
            }
        }
        let all = replayAll; replayAll.removeAll()
        let error = unexpected ?? failed.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value
        all.forEach { if let error { $0.resume(throwing: error) } else { $0.resume() } }
    }
}
#endif
