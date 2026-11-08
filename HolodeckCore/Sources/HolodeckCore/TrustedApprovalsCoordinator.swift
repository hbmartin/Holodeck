#if os(macOS)
import Foundation

nonisolated final class TrustedOwnerLifetime: @unchecked Sendable {
    private let token = TrustedInvalidationToken()
    var isCurrent: Bool { token.isCurrent }
    func invalidate() { token.invalidate() }
    func admitWrite(_ start: () throws -> Void = {}) throws {
        guard let _ = try token.withCurrent(start) else {
            throw ShaderRequestError.unavailable("This catalog server was replaced before its trusted write was admitted.")
        }
    }
}

/// A binding is revocable without an actor hop, including during transport teardown.
nonisolated final class TrustedOwnerPermit: @unchecked Sendable {
    let serverID: UUID
    let generation: UInt64
    let authority: UUID
    let lifetime: TrustedOwnerLifetime
    private let token = TrustedInvalidationToken()
    init(serverID: UUID, generation: UInt64, authority: UUID, lifetime: TrustedOwnerLifetime) {
        self.serverID = serverID; self.generation = generation; self.authority = authority; self.lifetime = lifetime
    }
    var isCurrent: Bool { token.isCurrent }
    func invalidate() { token.invalidate() }
}

protocol TrustedReportedDiagnostic: Error { var diagnosticID: UUID { get } }
struct TrustedPartialRecovery: LocalizedError, Sendable {
    let completedServices: [UUID]
    let remaining: [String]
    var errorDescription: String? {
        remaining.joined(separator: "\n") + "\nPartial recovery: local progress was committed; unresolved trusted targets remain."
    }
}
struct TrustedRevocationApplication: Sendable, Equatable {
    let serviceID: UUID
    let registrationID: UUID
    let authority: UUID
    let intent: RequestRevocationIntent
    let proof = UUID()
}
struct TrustedRevocationReservation: Sendable {
    let serviceID: UUID
    let registrationID: UUID
    let intent: RequestRevocationIntent
    let authority: UUID
    let token = UUID()
}
struct TrustedRevocationInspection: Sendable {
    let registrationID: UUID
    let revision: TrustedRevocationRevision
}
struct TrustedRevocationRemoval: Sendable {
    let authority: UUID
    let intent: RequestRevocationIntent
    let applications: [UUID: TrustedRevocationApplication]
    static func checked(authority: UUID, intent: RequestRevocationIntent, proofs: [TrustedRevocationApplication]) throws -> Self {
        var applications: [UUID: TrustedRevocationApplication] = [:]
        for proof in proofs {
            guard proof.authority == authority, proof.intent == intent, applications[proof.serviceID] == nil else {
                throw ShaderRequestError.unavailable("Conflicting trusted cancellation receipts; retain the intent and retry recovery.")
            }
            applications[proof.serviceID] = proof
        }
        return .init(authority: authority, intent: intent, applications: applications)
    }
}

/// One authority per trusted backend. Replay belongs to the store, not its current transport.
actor TrustedApprovalsCoordinator {
    nonisolated static func keychain(namespace: String) -> TrustedApprovalsCoordinator {
        TrustedAuthorityRegistry.shared.authority(account: approvalsAccount(namespace))
    }
    nonisolated static func approvalsAccount(_ namespace: String) -> String { namespace + "-approved-tvs" }

    struct Snapshot: Sendable {
        let approvals: [String: ApprovedTV]
        let diagnostic: String?
        let diagnosticID: UUID?
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
            try await completion.value()
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
        let recoveryPins: Int
        let targets: Int
        let inspections: Int
        let obligations: Int
        let departures: Int
        let queuedRevocations: Int
    }
    struct Approval: Sendable {
        let record: ApprovedTV
        let token: String
        let eligibility: TrustedApprovalEligibility
    }
    struct Owner: Sendable {
        let serverID: UUID
        let eligibility: TrustedOwnerLifetime
        private let target: WeakRequestService
        let requiresService: Bool
        var service: ShaderRequestService? { target.value }
        let changed: @Sendable (Snapshot, Binding) async -> Void
        let retired: @Sendable () async -> Void
        let beforeReplay: @Sendable (RequestRevocationIntent) async throws -> Void
        init(serverID: UUID, service: ShaderRequestService?, changed: @escaping @Sendable (Snapshot, Binding) async -> Void,
             retired: @escaping @Sendable () async -> Void, beforeReplay: @escaping @Sendable (RequestRevocationIntent) async throws -> Void,
             eligibility: TrustedOwnerLifetime = .init()) {
            self.eligibility = eligibility
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
    private struct Failure: LocalizedError, Sendable, TrustedReportedDiagnostic {
        let diagnosticID: UUID
        let primary: String
        private var secondary: [String] = []
        var message: String { ([primary] + secondary.map { "Additional trusted failure: " + $0 }).joined(separator: "\n") }
        var errorDescription: String? { message }
        init(_ error: Error, diagnosticID: UUID) { self.diagnosticID = diagnosticID; primary = RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192) }
        func appending(_ error: Error) -> Self {
            var result = self
            result.secondary = BoundedDiagnostics.appending(error.localizedDescription, primary: primary, secondary: secondary)
            return result
        }
    }
    nonisolated let id = UUID()
    private let beforeReservation: @Sendable (UUID) async throws -> Void
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
    private struct RecoveryHandle {
        let reference: WeakRequestService
        let revision: UInt64
        let pin: ShaderRequestService?
    }
    private var recoveryHandles: [UUID: RecoveryHandle] = [:]
    private func retainRecovery(_ target: ShaderRequestService, revision: UInt64, required: Bool) {
        guard revision >= (recoveryHandles[target.runtimeID]?.revision ?? 0) else { return }
        recoveryHandles[target.runtimeID] = .init(reference: .init(target), revision: revision, pin: required ? target : nil)
        updateRetention()
    }
    private var targets: [TargetKey: Target] = [:]
    private var inspected: [TargetKey: TrustedRevocationInspection] = [:]
    private var departures: [UUID: TrustedAuthorityDeparture] = [:]
    private var queuedRevocations: [UUID] = []
    private var required: [UUID: Set<TargetKey>] = [:]
    private var applications: [UUID: [TargetKey: TrustedRevocationApplication]] = [:]
    // A trusted removal may have committed even when a target rejected its stale completion.
    // Retain that outcome and its pins until exact fence finalization succeeds.
    private var removals: [UUID: TrustedRevocationRemoval] = [:]
    private var finalizedRemovals: [UUID: Set<TargetKey>] = [:]
    private var recoveryTargets: Set<TargetKey> = []
    private var failedApplications: Set<Attempt> = []
    private var failedRemovalWrites: Set<UUID> = []
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
         retainEvidence: @escaping @Sendable (TrustedApprovalsCoordinator, Bool) -> Void = { _, _ in },
         beforeReservation: @escaping @Sendable (UUID) async throws -> Void = { _ in }) {
        self.beforeReservation = beforeReservation
        self.read = read; self.write = write; self.retainEvidence = retainEvidence
    }
    private func updateRetention() {
        targets = targets.filter { $0.value.service != nil }
        inspected = inspected.filter { targets[$0.key] != nil }
        recoveryHandles = recoveryHandles.filter { $0.value.reference.value != nil }
        retainEvidence(self, recoveryHandles.values.contains(where: { $0.pin != nil }) || !envelope.revocations.isEmpty || !failures.isEmpty || mutationFailure != nil || !targetPins.isEmpty)
    }
    var observation: Observation {
        .init(requestedGeneration: generation, acceptedGeneration: accepted?.binding.permit.generation,
              queuedGeneration: pending?.registration.generation, preparingGeneration: preparing,
              mutationWaiters: waiters.filter(\.mutation).count, encodings: encodings, writes: writes,
              transitionActive: lane != nil, recoveryPins: recoveryHandles.values.filter { $0.pin != nil }.count,
              targets: targets.count, inspections: inspected.count, obligations: required.count, departures: departures.count, queuedRevocations: queuedRevocations.count)
    }
    private var revision: TrustedRevocationRevision { .init(coordinator: id, sequence: sequence) }
    private var snapshot: Snapshot {
        .init(approvals: Dictionary(envelope.approvals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }), diagnostic: mutationFailure.map { "Trusted TV operation \($0.operation): " + $0.message } ?? failures.sorted { $0.key.uuidString < $1.key.uuidString }.first.map { "Trusted TV intent \($0.key): " + $0.value.message },
              diagnosticID: mutationFailure?.operation ?? failures.sorted { $0.key.uuidString < $1.key.uuidString }.first?.key)
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
        guard owner.eligibility.isCurrent else { throw Self.unavailable("The proposed catalog server lifetime ended before registration.") }
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
    private func configure(_ target: ShaderRequestService, transfer: ShaderRequestService.AuthorityTransfer? = nil) async throws {
        let serviceID = target.runtimeID
        guard departures[serviceID] == nil else {
            throw Self.unavailable("This request service has a trusted authority handoff pending; retry registration after it finishes.")
        }
        let callback: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw Self.unavailable("The trusted approval authority is unavailable.") }
            try await self.retry(requester: serviceID)
        }
        let registration: UUID
        var inspection: TrustedRevocationInspection?
        if let transfer {
            (registration, inspection) = try await target.installTrustedAuthority(transfer, id: id,
                intents: envelope.revocations + removals.values.map(\.intent), revision: revision, coordinator: callback)
        } else { registration = await target.registerRevocationCoordinator(id: id, callback) }
        let key = TargetKey(service: serviceID, registration: registration)
        let previous = targets.keys.filter { $0.service == serviceID && $0 != key }
        for old in previous {
            targets[old] = nil; inspected[old] = nil; targetPins[old] = nil; recoveryTargets.remove(old)
            failedApplications = failedApplications.filter { $0.target != old }
            for intent in required.keys where required[intent]?.contains(old) == true {
                required[intent]?.remove(old); required[intent]?.insert(key); targetPins[key] = target
                applications[intent]?[old] = nil; finalizedRemovals[intent]?.remove(old)
            }
        }
        targets[key] = Target(service: target, key: key)
        if let inspection { inspected[key] = inspection }
        // A new target cannot disappear from the quorum while fresh inspection awaits.
        for intent in envelope.revocations + removals.values.map(\.intent) {
            required[intent.operationID, default: []].insert(key); targetPins[key] = target
        }
        await target.rememberTrustedAuthority(self)
        await target.observeHostRecovery(id: id) { [weak self] service, revision, required in
            await self?.retainRecovery(service, revision: revision, required: required)
        }
    }
    private func retry(requester: UUID) async throws {
        var completed: [UUID] = [requester], errors: [String] = []
        var inspectedDuringRegistration = false
        if let candidate = failedRegistration {
            if candidate.eligibility.isCurrent {
                do { _ = try await register(candidate).value(); inspectedDuringRegistration = true }
                catch { errors.append("Registration: " + error.localizedDescription) }
            } else { failedRegistration = nil }
        }
        for key in recoveryTargets.sorted(by: { $0.service.uuidString < $1.service.uuidString }) {
            do {
                if key.service != requester {
                    guard let target = targets[key]?.service else { continue }
                    try await target.retryReconciliation(replayTrusted: false)
                    completed.append(key.service)
                }
                failedApplications = failedApplications.filter { $0.target != key }
            } catch { errors.append("Service \(key.service): " + error.localizedDescription) }
        }
        if !inspectedDuringRegistration {
            let token = try await acquire()
            do { try await readFresh(target: service) }
            catch { errors.append("Inspection: " + error.localizedDescription) }
            release(token)
        }
        failedRemovalWrites.removeAll()
        if loaded {
            do { try await replay() } catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty {
            throw TrustedPartialRecovery(completedServices: completed,
                remaining: Array(errors.prefix(9)).map { BoundedDiagnostics.bounded($0, bytes: 8192) })
        }
    }
    private func inspect(_ known: Target, intents: [RequestRevocationIntent]) async throws {
        guard let target = known.service else { return }
        let obligations = intents.filter { finalizedRemovals[$0.operationID]?.contains(known.key) != true }
        // Record every obligation before the first fallible target notification.
        for intent in obligations { required[intent.operationID, default: []].insert(known.key); targetPins[known.key] = target }
        inspected[known.key] = nil
        do { inspected[known.key] = try await target.loadTrustedRevocations(obligations, revision: revision) }
        catch { await target.revocationReplayFailed(error, revision: revision); throw error }
    }
    private func readFresh(target: ShaderRequestService?) async throws {
        // A read can reveal new obligations or fail. It cannot race an already
        // prepared departure into activation on the strength of an older baseline.
        for departure in departures.values { departure.invalidatePreparation() }
        let current: Data?, candidate: TrustedTVApprovals
        do {
            let read = read
            current = try await Task.detached { try read() }.value
            candidate = try current.map(TrustedTVApprovals.decode) ?? TrustedTVApprovals()
        } catch {
            loaded = false
            if let target { await target.revocationReplayFailed(error, revision: revision) }
            throw error
        }
        let changed = current != bytes
        envelope = candidate; bytes = current; if changed { sequence &+= 1 }; loaded = true
        let intents = candidate.revocations + removals.values.map(\.intent)
        var errors: [Error] = []
        for known in targets.values where departures[known.key.service]?.activated != true {
            do { try await inspect(known, intents: intents) } catch { errors.append(error) }
        }
        if changed { await notify() }
        let ids = Set(candidate.revocations.map(\.operationID)).union(removals.keys)
        failures = failures.filter { ids.contains($0.key) }
        if let error = errors.first { throw error }
    }
    private func wakeAdmissions() {
        let waiting = waiters; waiters.removeAll()
        waiting.forEach { $0.continuation.resume() }
    }
    /// Revocations wait before preparing any trusted candidate or reservation.
    /// Keeping the admission in this list until lane acquisition prevents later
    /// departures from repeatedly overtaking it. Duplicate devices still share
    /// the existing durable intent once the first writer has been admitted.
    private func acquireRevocation(_ permit: TrustedOwnerPermit) async throws -> UUID {
        let admission = UUID(); queuedRevocations.append(admission)
        defer { queuedRevocations.removeAll { $0 == admission }; wakeAdmissions() }
        return try await withTaskCancellationHandler {
            while !departures.isEmpty || queuedRevocations.first != admission {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { c in
                    waiters.append(.init(id: admission, mutation: true, continuation: c))
                }
            }
            return try await acquire(permit: permit, mutation: true)
        } onCancel: { Task { await self.cancelWaiter(admission) } }
    }
    private func acquireDeparture() async throws -> UUID {
        let admission = UUID()
        return try await withTaskCancellationHandler {
            while true {
                while !queuedRevocations.isEmpty {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { c in
                        waiters.append(.init(id: admission, mutation: false, continuation: c))
                    }
                }
                let token = try await acquire()
                if queuedRevocations.isEmpty { return token }
                release(token)
            }
        } onCancel: { Task { await self.cancelWaiter(admission) } }
    }
    // Cross-authority preparation never holds both authorities' mutation lanes.
    func prepareDeparture(_ target: ShaderRequestService, ticket: UUID) async throws -> TrustedAuthorityDeparture {
        let token = try await acquireDeparture()
        guard departures[target.runtimeID] == nil,
              let known = targets.values.first(where: { $0.key.service == target.runtimeID }) else {
            release(token); throw Self.unavailable("A trusted authority handoff is already pending or its registration is unavailable.")
        }
        let departure = TrustedAuthorityDeparture(id: ticket, serviceID: target.runtimeID, registrationID: known.key.registration)
        departures[target.runtimeID] = departure
        do { if !loaded { try await readFresh(target: target) } }
        catch { release(token); await cancelDeparture(serviceID: target.runtimeID, ticket: ticket); throw error }
        let needed = required.values.contains { $0.contains { $0.service == target.runtimeID } }
        release(token)
        do {
            if needed { try await replay() }
            try await target.settleTrustedAuthorityDeparture()
            let check = try await acquire()
            let outstanding = required.values.contains { $0.contains { $0.service == target.runtimeID } }
            if !outstanding, loaded { departure.prepared() }
            release(check)
            guard !outstanding, loaded else { throw Self.unavailable("The previous trusted authority still requires cancellation or inspection recovery before switching.") }
            return departure
        } catch { await cancelDeparture(serviceID: target.runtimeID, ticket: ticket); throw error }
    }
    func cancelDeparture(serviceID: UUID, ticket: UUID) async {
        let token = try! await acquire(cancellable: false)
        if let departure = departures[serviceID], departure.id == ticket, !departure.activated {
            // A failed inspection must never be cleared by reapplying cached data.
            if let known = targets.values.first(where: { $0.key.service == serviceID }) {
                do {
                    if loaded { try await inspect(known, intents: envelope.revocations + removals.values.map(\.intent)) }
                    else { try await readFresh(target: known.service) }
                } catch { await known.service?.revocationReplayFailed(error, revision: revision) }
            }
            departures[serviceID] = nil; departure.close()
        }
        release(token)
    }
    func finishDeparture(_ target: ShaderRequestService, ticket: UUID) async {
        let token = try! await acquire(cancellable: false)
        if let departure = departures[target.runtimeID], departure.id == ticket, departure.activated {
            departures[target.runtimeID] = nil; departure.close()
            for key in targets.keys.filter({ $0.service == target.runtimeID }) { targets[key] = nil; inspected[key] = nil }
            if service === target { service = nil }
        }
        release(token)
    }
    private func drainRegistrations() async {
        while pending != nil {
            var token = try! await acquire(cancellable: false, registration: true)
            guard let request = pending else { release(token); continue }
            pending = nil; preparing = request.registration.generation
            var transfer: ShaderRequestService.AuthorityTransfer?
            do {
                if let target = request.owner.service {
                    release(token)
                    do { transfer = try await target.prepareTrustedAuthority(id: id) }
                    catch {
                        token = try! await acquire(cancellable: false, registration: true)
                        throw error
                    }
                    token = try! await acquire(cancellable: false, registration: true)
                }
                try request.registration.completion.check()
                guard request.owner.eligibility.isCurrent else { throw CancellationError() }
                guard !request.owner.requiresService || request.owner.service != nil else {
                    throw Self.unavailable("The proposed request service was released before registration.")
                }
                // A cross-authority binding changes only after a fresh backend inspection.
                if transfer != nil { try await readFresh(target: request.owner.service) }
                try request.registration.completion.check()
                guard request.registration.generation == generation else { throw CancellationError() }
                if transfer != nil { try request.owner.eligibility.admitWrite { try request.registration.completion.beginMutation() } }
                if let target = request.owner.service { try await configure(target, transfer: transfer) }
                if let transfer, let target = request.owner.service {
                    await target.finishTrustedAuthority(transfer, authority: self)
                } else { try await readFresh(target: request.owner.service ?? service) }
                try request.registration.completion.check()
                guard request.registration.completion.hasStarted || request.registration.generation == generation else {
                    request.registration.completion.complete(.success(.superseded)); preparing = nil; release(token); continue
                }
                if !request.registration.completion.hasStarted {
                    try request.owner.eligibility.admitWrite { try request.registration.completion.beginMutation() }
                }
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
                if let transfer, let target = request.owner.service {
                    release(token); await target.cancelTrustedAuthority(transfer)
                    token = try! await acquire(cancellable: false, registration: true)
                }
                if request.registration.generation == generation, request.owner.eligibility.isCurrent, !(error is CancellationError) { failedRegistration = request.owner }
                request.registration.completion.complete(.failure(error))
            }
            preparing = nil; release(token)
        }
        registrationTask = nil
    }
    func withdraw(serverID: UUID, eligibility: TrustedOwnerLifetime) async {
        let token = try! await acquire(cancellable: false)
        defer { release(token) }
        if failedRegistration?.serverID == serverID, failedRegistration?.eligibility === eligibility { failedRegistration = nil }
        if pending?.owner.serverID == serverID, pending?.owner.eligibility === eligibility {
            pending?.registration.completion.cancel(); pending = nil
        }
        if accepted?.owner.serverID == serverID, accepted?.owner.eligibility === eligibility {
            accepted?.binding.permit.invalidate(); accepted?.binding.permit.lifetime.invalidate()
            accepted = nil; service = nil
        }
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
        required.removeAll(); applications.removeAll(); removals.removeAll(); finalizedRemovals.removeAll(); failures.removeAll(); recoveryTargets.removeAll(); failedApplications.removeAll(); failedRemovalWrites.removeAll(); targetPins.removeAll()
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
        let candidate = try prepare(value), predecessor = bytes
        try Task.checkCancellation(); try permit.lifetime.admitWrite { try proposal.eligibility.beginWrite() }
        do { try await persist(value, bytes: candidate) }
        catch {
            let initiating = error
            do {
                let read = read
                let actual = try await Task.detached { try read() }.value
                if actual == candidate {
                    acceptPersisted(value, bytes: candidate)
                    await notify(); return proposal
                }
                if actual == predecessor {
                    if permit.lifetime.isCurrent { proposal.eligibility.restoreAfterFailedWrite() }
                } else { throw Self.unavailable("Approval persistence has an uncertain outcome; retain trusted storage and choose Retry Recovery.") }
            } catch {
                loaded = false
                await service?.revocationReplayFailed(error, revision: revision)
            }
            await recordMutationFailure(initiating, operation: UUID(), context: "TV approval for " + proposal.record.id)
            throw initiating
        }
        await notify()
        return proposal
    }
    func revoke(_ device: String, permit: TrustedOwnerPermit,
                beforeCommit: @Sendable (RequestRevocationIntent) async throws -> Void) async throws {
        let token = try await acquireRevocation(permit)
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
                var reservations: [(ShaderRequestService, TrustedRevocationReservation)] = []
                var admittedTargets: [Target] = []
                var writeAdmitted = false
                do {
                    for target in targets.values.sorted(by: { $0.key.service.uuidString < $1.key.service.uuidString }) {
                        try await beforeReservation(target.key.service)
                        guard let service = target.service else { continue }
                        let receipt = try await service.reserveRevocation(intent, revision: revision)
                        reservations.append((service, receipt)); admittedTargets.append(target)
                    }
                    try await beforeCommit(intent); try Task.checkCancellation(); try validate(permit)
                    try permit.lifetime.admitWrite { writeAdmitted = true }
                    try await persist(value, bytes: candidate)
                } catch {
                    if !(error is CancellationError), writeAdmitted || permit.lifetime.isCurrent {
                        await recordMutationFailure(error, operation: intent.operationID, context: "TV revocation for " + intent.deviceID)
                    }
                    for (service, receipt) in reservations { await service.cancelRevocationReservation(receipt) }
                    throw error
                }
                for target in admittedTargets {
                    required[intent.operationID, default: []].insert(target.key)
                    if let service = target.service { targetPins[target.key] = service }
                }
                await notify()
                for target in admittedTargets {
                    guard let service = target.service else { continue }
                    do { try await service.commitTrustedRevocation(intent, revision: revision) }
                    catch {
                        inspected[target.key] = nil; recoveryTargets.insert(target.key)
                        _ = await record(error, intent: intent)
                    }
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
                guard envelope.revocations.contains(where: { $0.operationID == target }) || removals[target] != nil else { c.resume(); return }
                replayWaiters[target, default: []].append(c)
            } else { replayAll.append(c) }
            if replayTask == nil { replayTask = Task { await self.drainReplay() } }
        }
    }
    private func record(_ error: Error, intent: RequestRevocationIntent) async -> Failure {
        let failure = failures[intent.operationID]?.appending(error) ?? Failure(error, diagnosticID: intent.operationID)
        failures[intent.operationID] = failure
        for key in required[intent.operationID] ?? [] {
            await targets[key]?.service?.revocationReplayFailed(failure, intent: intent, revision: revision)
        }
        await notify()
        return failure
    }
    private struct Attempt: Hashable { let intent: UUID; let target: TargetKey }
    private func acknowledgeIfReady(_ intent: RequestRevocationIntent) async throws -> Bool {
        guard !failedRemovalWrites.contains(intent.operationID), let needed = required[intent.operationID], !needed.isEmpty else { return false }
        let proofs = applications[intent.operationID] ?? [:]
        guard needed.allSatisfy({ proofs[$0] != nil }) else { return false }
        for key in needed where finalizedRemovals[intent.operationID]?.contains(key) != true {
            guard let target = targets[key]?.service, let proof = proofs[key] else { return false }
            try await target.validateTrustedRevocation(proof)
        }
        let removal = try TrustedRevocationRemoval.checked(authority: id, intent: intent,
            proofs: needed.compactMap { proofs[$0] })
        if removals[intent.operationID] == nil {
            var value = envelope; value.revocations.removeAll { $0.operationID == intent.operationID }
            do { try await persist(value, bytes: prepare(value)) }
            catch { failedRemovalWrites.insert(intent.operationID); throw error }
        }
        removals[intent.operationID] = removal
        for key in needed where finalizedRemovals[intent.operationID]?.contains(key) != true {
            guard let target = targets[key]?.service, let proof = proofs[key] else {
                throw Self.unavailable("The target of a committed trusted removal is unavailable. Retain its recovery evidence.")
            }
            try await target.finalizeTrustedRevocation(proof, removal: removal)
            finalizedRemovals[intent.operationID, default: []].insert(key)
        }
        finalizedRemovals[intent.operationID] = nil
        required[intent.operationID] = nil; applications[intent.operationID] = nil; removals[intent.operationID] = nil; failures[intent.operationID] = nil
        failedApplications = failedApplications.filter { $0.intent != intent.operationID }
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
            let remainingIntents = envelope.revocations + removals.values.map(\.intent)
            for intent in remainingIntents {
                for key in required[intent.operationID] ?? [] {
                    let attempt = Attempt(intent: intent.operationID, target: key)
                    if applications[intent.operationID]?[key] == nil, !attempted.contains(attempt), !failedApplications.contains(attempt), let target = targets[key]?.service {
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
                let remaining = Set(envelope.revocations.map(\.operationID)).union(removals.keys)
                failed = failed.filter { remaining.contains($0.key) }
                // A successful target cannot erase another target's unresolved application.
                for id in remaining where failed[id] == nil { failed[id] = failures[id] }
                for (key, receipt) in inspected {
                    await targets[key]?.service?.revocationReplaySucceeded(inspection: receipt)
                }
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
                failedApplications.insert(.init(intent: intent.operationID, target: key))
                failed[intent.operationID] = await record(error, intent: intent)
                release(commit)
            }
        }
    }
    private func finishReplay(_ failed: [UUID: Failure]) {
        replayTask = nil
        let waiting = replayWaiters; replayWaiters.removeAll()
        for (id, values) in waiting {
            for value in values {
                if let error = failed[id] { value.resume(throwing: error) } else { value.resume() }
            }
        }
        let all = replayAll; replayAll.removeAll()
        let error = failed.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value
        all.forEach { if let error { $0.resume(throwing: error) } else { $0.resume() } }
    }
}
#endif
