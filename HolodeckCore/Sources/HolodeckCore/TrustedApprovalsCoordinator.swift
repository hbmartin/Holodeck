#if os(macOS)
import Foundation

nonisolated final class TrustedOwnerLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
}

/// A binding is revocable without an actor hop, including during transport teardown.
nonisolated final class TrustedOwnerPermit: @unchecked Sendable {
    let serverID: UUID
    let generation: UInt64
    let authority: UUID
    let lifetime: TrustedOwnerLifetime
    private let lock = NSLock()
    private var valid = true
    init(serverID: UUID, generation: UInt64, authority: UUID, lifetime: TrustedOwnerLifetime) {
        self.serverID = serverID; self.generation = generation; self.authority = authority; self.lifetime = lifetime
    }
    var isCurrent: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}

struct TrustedRevocationApplication: Sendable, Equatable {
    let serviceID: UUID
    let registrationID: UUID
    let authority: UUID
    let intent: RequestRevocationIntent
    let proof = UUID()
}
struct TrustedRevocationRemoval: Sendable {
    let authority: UUID
    let intent: RequestRevocationIntent
    let applications: [UUID: TrustedRevocationApplication]
}

/// One authority per trusted backend. Replay belongs to the store, not its current transport.
actor TrustedApprovalsCoordinator {
    nonisolated static func keychain(namespace: String) -> TrustedApprovalsCoordinator {
        TrustedAuthorityRegistry.shared.authority(account: approvalsAccount(namespace))
    }
    nonisolated static func approvalsAccount(_ namespace: String) -> String { namespace + "-approved-tvs" }

    struct Snapshot: Sendable {
        let approvals: [String: ApprovedTV]
        let revocations: [RequestRevocationIntent]
        let diagnostic: String?
    }
    struct Binding: Sendable {
        let permit: TrustedOwnerPermit
        private let target: WeakRequestService
        var service: ShaderRequestService? { target.value }
        init(permit: TrustedOwnerPermit, service: ShaderRequestService?) { self.permit = permit; target = .init(service) }
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
        let eligibility: TrustedApprovalEligibility
        init(record: ApprovedTV, token: String, eligibility: TrustedApprovalEligibility) {
            self.record = record; self.token = token; self.eligibility = eligibility
        }
    }
    struct Owner: Sendable {
        let serverID: UUID
        private let target: WeakRequestService
        let requiresService: Bool
        var service: ShaderRequestService? { target.value }
        let changed: @Sendable (Snapshot, Binding) async -> Void
        let retired: @Sendable () async -> Void
        let beforeReplay: @Sendable (RequestRevocationIntent) async throws -> Void
        init(serverID: UUID, service: ShaderRequestService?, changed: @escaping @Sendable (Snapshot, Binding) async -> Void,
             retired: @escaping @Sendable () async -> Void, beforeReplay: @escaping @Sendable (RequestRevocationIntent) async throws -> Void) {
            self.serverID = serverID; target = .init(service); requiresService = service != nil; self.changed = changed; self.retired = retired; self.beforeReplay = beforeReplay
        }
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
    private let retainEvidence: @Sendable (TrustedApprovalsCoordinator, Bool) -> Void
    private var envelope = TrustedTVApprovals()
    private var bytes: Data?
    private var loaded = false
    private var sequence: UInt64 = 0
    private var accepted: Accepted?
    private weak var service: ShaderRequestService?
    private struct TargetKey: Hashable { let service: UUID; let registration: UUID }
    private struct Target {
        private let reference: WeakRequestService
        var service: ShaderRequestService? { reference.value }
        let key: TargetKey
        init(service: ShaderRequestService, key: TargetKey) { reference = .init(service); self.key = key }
    }
    // Pins exist only while durable intent or unresolved recovery needs this target.
    private var targetPins: [TargetKey: ShaderRequestService] = [:]
    private var targets: [TargetKey: Target] = [:]
    private var required: [UUID: Set<TargetKey>] = [:]
    private var applications: [UUID: [TargetKey: TrustedRevocationApplication]] = [:]
    private var recoveryTargets: Set<TargetKey> = []
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

    init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void,
         retainEvidence: @escaping @Sendable (TrustedApprovalsCoordinator, Bool) -> Void = { _, _ in }) {
        self.read = read; self.write = write; self.retainEvidence = retainEvidence
    }
    private func updateRetention() {
        targets = targets.filter { $0.value.service != nil }
        retainEvidence(self, !envelope.revocations.isEmpty || !failures.isEmpty || mutationFailure != nil || !targetPins.isEmpty)
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
        guard permit.lifetime.isCurrent, let current = accepted?.binding.permit, current.isCurrent,
              current.lifetime === permit.lifetime else {
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
        updateRetention()
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
        let serviceID = target.runtimeID
        let registration = await target.registerRevocationCoordinator(id: id) { [weak self] in
            guard let self else { throw Self.unavailable("The trusted approval authority is unavailable.") }
            try await self.retry(requester: serviceID)
        }
        let key = TargetKey(service: serviceID, registration: registration)
        let previous = targets.keys.filter { $0.service == serviceID && $0 != key }
        for old in previous {
            targets[old] = nil; targetPins[old] = nil; recoveryTargets.remove(old)
            for intent in required.keys where required[intent]?.contains(old) == true {
                required[intent]?.remove(old); required[intent]?.insert(key)
                applications[intent]?[old] = nil
            }
        }
        targets[key] = Target(service: target, key: key)
    }
    private func retry(requester: UUID) async throws {
        if let failedRegistration {
            let ticket = try register(failedRegistration)
            _ = try await ticket.value()
        }
        for key in recoveryTargets where key.service != requester {
            if let target = targets[key]?.service { try await target.retryReconciliation(replayTrusted: false) }
        }
        let token = try await acquire()
        do { try await readFresh(target: service); release(token) }
        catch { release(token); throw error }
        try await replay()
    }
    private func readFresh(target: ShaderRequestService?) async throws {
        do {
            let read = read
            let current = try await Task.detached { try read() }.value
            let candidate = try current.map(TrustedTVApprovals.decode) ?? TrustedTVApprovals()
            let next = sequence &+ (current == bytes ? 0 : 1)
            let revision = TrustedRevocationRevision(coordinator: id, sequence: next)
            for known in targets.values {
                guard let target = known.service else { continue }
                try await target.loadTrustedRevocations(candidate.revocations, revision: revision)
                for intent in candidate.revocations { required[intent.operationID, default: []].insert(known.key); targetPins[known.key] = target }
            }
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
                guard !request.owner.requiresService || request.owner.service != nil else {
                    throw Self.unavailable("The proposed request service was released before registration.")
                }
                if let target = request.owner.service { await configure(target) }
                try await readFresh(target: request.owner.service ?? service)
                try request.registration.completion.check()
                guard request.registration.generation == generation else {
                    request.registration.completion.complete(.success(.superseded)); preparing = nil; release(token); continue
                }
                try request.registration.completion.beginMutation()
                let prior = accepted
                let continuing = prior?.owner.serverID == request.owner.serverID && prior?.binding.permit.lifetime.isCurrent == true
                let lifetime = continuing ? prior!.binding.permit.lifetime : TrustedOwnerLifetime()
                let permit = TrustedOwnerPermit(serverID: request.owner.serverID, generation: request.registration.generation, authority: id, lifetime: lifetime)
                if !continuing { prior?.binding.permit.lifetime.invalidate() }
                let binding = Binding(permit: permit, service: request.owner.service)
                prior?.binding.permit.invalidate()
                accepted = Accepted(owner: request.owner, binding: binding)
                service = request.owner.service
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
    func releaseBinding(_ permit: TrustedOwnerPermit) async {
        let token = try! await acquire(cancellable: false)
        defer { release(token) }
        guard accepted?.binding.permit === permit else { return }
        permit.invalidate(); permit.lifetime.invalidate()
        accepted = nil; service = nil
        if failedRegistration?.serverID == permit.serverID { failedRegistration = nil }
        targets = targets.filter { $0.value.service != nil }
    }
    func discardTestingCacheIfIdle() {
        guard accepted == nil, pending == nil, preparing == nil, lane == nil, replayTask == nil else { return }
        envelope = .init(); bytes = nil; loaded = false
        required.removeAll(); applications.removeAll(); failures.removeAll(); recoveryTargets.removeAll(); targetPins.removeAll()
        mutationFailure = nil; failedRegistration = nil
        updateRetention()
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
        try Task.checkCancellation(); try validate(permit); try proposal.eligibility.check()
        var value = envelope
        value.approvals.removeAll { $0.id == proposal.record.id }; value.approvals.append(proposal.record)
        let candidate = try prepare(value)
        try Task.checkCancellation(); try proposal.eligibility.beginWrite()
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
                for target in targets.values { try await target.service?.reserveRevocation(intent, revision: revision) }
                do {
                    try await beforeCommit(intent); try Task.checkCancellation()
                    try await persist(value, bytes: candidate)
                } catch {
                    if !(error is CancellationError) {
                        await recordMutationFailure(error, operation: intent.operationID, context: "TV revocation for " + intent.deviceID)
                    }
                    for target in targets.values { await target.service?.cancelRevocationReservation(intent, revision: revision) }
                    throw error
                }
                await notify()
                for target in targets.values {
                    guard let service = target.service else { continue }
                    try await service.commitTrustedRevocation(intent, revision: revision)
                    required[intent.operationID, default: []].insert(target.key); targetPins[target.key] = service
                }
            }
        } catch { release(token); throw error }
        release(token)
        try await replay(target: intent.operationID)
    }
    func replay(target: UUID? = nil) async throws {
        guard targets.values.contains(where: { $0.service != nil }) else { return }
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
        for key in required[intent.operationID] ?? [] {
            await targets[key]?.service?.revocationReplayFailed(failure, intent: intent, revision: revision)
        }
        return failure
    }
    private struct Attempt: Hashable { let intent: UUID; let target: TargetKey }
    private func acknowledgeIfReady(_ intent: RequestRevocationIntent) async throws -> Bool {
        guard let needed = required[intent.operationID], !needed.isEmpty else { return false }
        let proofs = applications[intent.operationID] ?? [:]
        guard needed.allSatisfy({ proofs[$0] != nil }) else { return false }
        for key in needed {
            guard let target = targets[key]?.service, let proof = proofs[key] else { return false }
            try await target.validateTrustedRevocation(proof)
        }
        var value = envelope; value.revocations.removeAll { $0.operationID == intent.operationID }
        let candidate = try prepare(value)
        try await persist(value, bytes: candidate)
        let removal = TrustedRevocationRemoval(authority: id, intent: intent,
            applications: Dictionary(uniqueKeysWithValues: needed.compactMap { key in proofs[key].map { (key.service, $0) } }))
        for key in needed {
            if let target = targets[key]?.service, let proof = proofs[key] { try await target.finalizeTrustedRevocation(proof, removal: removal) }
        }
        required[intent.operationID] = nil; applications[intent.operationID] = nil; failures[intent.operationID] = nil
        let retained = Set(required.values.flatMap { $0 })
        targetPins = targetPins.filter { retained.contains($0.key) }
        targets = targets.filter { $0.value.service != nil }
        await notify()
        let waiting = replayWaiters.removeValue(forKey: intent.operationID) ?? []
        waiting.forEach { $0.resume() }
        return true
    }
    private func drainReplay() async {
        var attempted: Set<Attempt> = [], failed: [UUID: Failure] = [:], removalAttempted: Set<UUID> = []
        drain: while true {
            let token = try! await acquire(cancellable: false)
            var work: (RequestRevocationIntent, TargetKey, ShaderRequestService)?
            for intent in envelope.revocations {
                for key in required[intent.operationID] ?? [] {
                    let attempt = Attempt(intent: intent.operationID, target: key)
                    if applications[intent.operationID]?[key] == nil, !attempted.contains(attempt), let target = targets[key]?.service {
                        work = (intent, key, target); attempted.insert(attempt); break
                    }
                }
                if work != nil { break }
                if !removalAttempted.contains(intent.operationID) {
                    do {
                        if try await acknowledgeIfReady(intent) { failed[intent.operationID] = nil; release(token); continue drain }
                    } catch { failed[intent.operationID] = await record(error, intent: intent) }
                    removalAttempted.insert(intent.operationID)
                }
            }
            guard let (intent, key, target) = work else {
                let remaining = Set(envelope.revocations.map(\.operationID))
                failed = failed.filter { remaining.contains($0.key) }
                // A successful target cannot erase another target's unresolved application.
                for id in remaining where failed[id] == nil { failed[id] = failures[id] }
                for known in targets.values { await known.service?.revocationReplaySucceeded(revision: revision) }
                finishReplay(failed); release(token); return
            }
            let hook = accepted?.owner.beforeReplay, appliedRevision = revision
            release(token)
            do {
                try await hook?(intent)
                let proof = try await target.applyTrustedRevocation(intent, revision: appliedRevision)
                let commit = try! await acquire(cancellable: false)
                applications[intent.operationID, default: [:]][key] = proof
                recoveryTargets.remove(key)
                removalAttempted.remove(intent.operationID)
                do {
                    if try await acknowledgeIfReady(intent) { failed[intent.operationID] = nil }
                } catch {
                    removalAttempted.insert(intent.operationID)
                    failed[intent.operationID] = await record(error, intent: intent)
                }
                release(commit)
            } catch {
                let commit = try! await acquire(cancellable: false)
                recoveryTargets.insert(key)
                failed[intent.operationID] = await record(error, intent: intent)
                release(commit)
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
