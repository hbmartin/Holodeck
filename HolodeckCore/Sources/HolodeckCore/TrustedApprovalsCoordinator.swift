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
enum TrustedRecoveryPhase: Sendable {
    case completed, refused(String), failed(String), interrupted(String)
    var failure: String? {
        switch self { case .completed: nil; case .refused(let detail), .failed(let detail), .interrupted(let detail): detail }
    }
}
struct TrustedLocalRecovery: Sendable {
    let phase: TrustedRecoveryPhase
    var receipt: TrustedLocalRecoveryReceipt? = nil
    var initiatingError: (any Error)? = nil
    var failure: String? { phase.failure }
    var completed: Bool { if case .completed = phase { return true }; return false }
}
struct TrustedSetupPending: LocalizedError, Sendable {
    var errorDescription: String? { "Shader request setup is still loading. The accepted TV authority was retained; finish setup and explicitly retry registration." }
}
struct TrustedRecoveryAdmissionError: LocalizedError, Sendable {
    var errorDescription: String? { "Wait for active checkout work or recovery to finish." }
}
struct TrustedRegistrationInterrupted: LocalizedError, Sendable {
    let lifetimeEnded: Bool
    var errorDescription: String? {
        lifetimeEnded ? "TV server registration ended before acceptance because its server lifetime ended. Explicitly register the intended server again." :
            "TV server registration preparation was cancelled before acceptance. The accepted binding was retained; explicitly retry registration."
    }
}
struct TrustedRecoveryInterrupted: LocalizedError, Sendable {
    var errorDescription: String? { "Local recovery was interrupted because checkout maintenance ownership changed. Retain its evidence and retry after Detach or maintenance finishes." }
}
struct TrustedRecoveryCompletion: Sendable { let completedServices: [UUID] }
struct TrustedPartialRecovery: LocalizedError, Sendable {
    let completedServices: [UUID]
    let remaining: [String]
    var errorDescription: String? {
        remaining.joined(separator: "\n") + "\nPartial recovery: completed phases were committed; unresolved local or trusted recovery remains."
    }
}
struct TrustedDepartureRecoveryError: LocalizedError, Sendable, TrustedReportedDiagnostic {
    let diagnosticID: UUID
    let serviceID: UUID
    var errorDescription: String? {
        "Authority departure " + diagnosticID.uuidString + " for service " + serviceID.uuidString +
        " requires receipt recovery. Retain its evidence and choose Retry Recovery; unverifiable receipts require manual repair."
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
        let preparation: TrustedRegistrationPreparation
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
        let recoverySubscriptions: Int
        let targets: Int
        let inspections: Int
        let obligations: Int
        let departures: Int
        let queuedRevocations: Int
        let admissionResumes: Int
        let admissionAdvances: Int
        let progressWaiters: Int
        let recoveryPasses: Int
        let recoveryParticipants: Int
        let successorParticipants: Int
        let departureInspectionWaiters: Int
        let departureRecoveryParticipants: Int
        let departureRecoverySuccessors: Int
        let pendingLocalOutcomes: Int
        let applicationRecoveryTargets: Int
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
    private enum Admission: CaseIterable {
        case progress, revocation, departure, replacement, client
    }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    /// Indexed FIFO removal makes cancellation and a single grant constant work.
    private struct AdmissionQueue {
        private struct Node { var previous: UUID?; var next: UUID?; let waiter: Waiter }
        private var nodes: [UUID: Node] = [:]
        private(set) var first: UUID?
        private var last: UUID?
        var count: Int { nodes.count }
        mutating func append(_ waiter: Waiter) {
            nodes[waiter.id] = Node(previous: last, next: nil, waiter: waiter)
            if let last { nodes[last]?.next = waiter.id } else { first = waiter.id }
            last = waiter.id
        }
        mutating func remove(_ id: UUID) -> Waiter? {
            guard let node = nodes.removeValue(forKey: id) else { return nil }
            if let previous = node.previous { nodes[previous]?.next = node.next } else { first = node.next }
            if let next = node.next { nodes[next]?.previous = node.previous } else { last = node.previous }
            return node.waiter
        }
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
    private let beforeRemovalFinalization: (@Sendable (UUID, UUID) async throws -> Void)?
    private let beforeDepartureRetirementAdmission: (@Sendable (UUID) async throws -> Void)?
    private let afterTargetInstallation: (@Sendable (UUID) async throws -> Void)?
    private let beforeReplayApplication: (@Sendable (UUID) async throws -> Void)?
    private let beforeRecoverySealing: @Sendable () async throws -> Void
    private let beforeInspectionRead: @Sendable () async throws -> Void
    private let beforeAuthorityPreparation: @Sendable (UUID) async throws -> Void
    private let beforeTargetInspection: @Sendable (UUID) async throws -> Void
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
    private var recoverySubscriptions: [UUID: TrustedRecoverySubscription] = [:]
    private func retainRecovery(_ target: ShaderRequestService, subscription: TrustedRecoverySubscription, revision: UInt64, required: Bool) {
        guard recoverySubscriptions[target.runtimeID] === subscription, subscription.isCurrent,
              targets.keys.contains(where: { $0.service == target.runtimeID && $0.registration == subscription.registrationID }) else { return }
        guard revision >= (recoveryHandles[target.runtimeID]?.revision ?? 0) else { return }
        recoveryHandles[target.runtimeID] = .init(reference: .init(target), revision: revision, pin: required ? target : nil)
        updateRetention()
    }
    private var targets: [TargetKey: Target] = [:]
    private var targetInstallations: [TargetKey: TrustedTargetInstallation] = [:]
    // Each successful target inspection proves this exact accepted baseline and
    // registration. Consumers must not infer inspection from registration success.
    private var inspections: [TargetKey: UInt64] = [:]
    private var baseline: UInt64 = 0
    private var departureRecovery: [UUID: TrustedAuthorityDeparture] = [:]
    private struct DepartureRecoveryJob {
        let id = UUID()
        let serviceID: UUID
        var participants: [UUID: RequestPersistence.CommitTicket<Void>] = [:]
        var closing = false
        var task: Task<Void, Never>?
    }
    private var departureRecoveryTasks: [UUID: DepartureRecoveryJob] = [:]
    private var departureRecoverySuccessors: [UUID: DepartureRecoveryJob] = [:]
    private var departures: [UUID: TrustedAuthorityDeparture] = [:]
    private var departureEndpoints: [UUID: TrustedAuthorityRecoveryEndpoint] = [:]
    private var endpointTargets: [UUID: [UUID: WeakRequestService]] = [:]
    private var queuedRevocations: Int { admissions[.revocation]?.count ?? 0 }
    private var required: [UUID: Set<TargetKey>] = [:]
    private var applications: [UUID: [TargetKey: TrustedRevocationApplication]] = [:]
    private var recoveryEpochs: [TargetKey: UUID] = [:]
    private var preparingRecovery: [TargetKey: UUID] = [:]
    private struct PendingRecoveryOutcome {
        let attempt: UUID
        var intents: Set<UUID>
    }
    private var pendingRecoveryOutcomes: [TargetKey: PendingRecoveryOutcome] = [:]
    private var applicationEpochs: [Attempt: UUID] = [:]
    // A trusted removal may have committed even when a target rejected its stale completion.
    // Retain that outcome and its pins until exact fence finalization succeeds.
    private var removals: [UUID: TrustedRevocationRemoval] = [:]
    private var finalizedRemovals: [UUID: Set<TargetKey>] = [:]
    private struct RemovalAdmission {
        let keys: Set<TargetKey>
        let completion = TrustedCompletionSignal()
    }
    private var removalAdmissions: [UUID: RemovalAdmission] = [:]
    private var recoveryTargets: Set<TargetKey> = []
    private struct ApplicationBlocker {
        let generation: UInt64
        let localAttempt: UUID?
        let diagnostic: String
    }
    private var applicationBlockerGeneration: UInt64 = 0
    private var failedApplications: [Attempt: ApplicationBlocker] = [:]
    private var failedRemovalWrites: Set<UUID> = []
    private var generation: UInt64 = 0
    private var pending: Request?
    private var preparing: UInt64?
    private var registrationTask: Task<Void, Never>?
    private var failedRegistration: Owner?
    private var lane: UUID?
    private var admissions: [Admission: AdmissionQueue] = [:]
    private var admissionResumes = 0
    private var admissionAdvances = 0
    private var encodings = 0, writes = 0
    private var failures: [UUID: Failure] = [:]
    private var mutationFailure: (operation: UUID, message: String)?
    private var replayTask: Task<Void, Never>?
    private enum RecoveryPassState { case collecting, sealed, replaying, finishing, finished }
    private struct RecoveryParticipant {
        let requester: UUID
        let local: TrustedLocalRecovery
        let receipt: RequestPersistence.CommitTicket<RecoveryResult>
        let sequence: UInt64
    }
    private struct RecoveryPass {
        let id = UUID()
        var state = RecoveryPassState.collecting
        var participants: [UUID: RecoveryParticipant] = [:]
        var task: Task<Void, Never>?
        var inputs: [UUID: TrustedLocalRecovery] {
            let latest = Dictionary(participants.values.map { ($0.requester, $0) }, uniquingKeysWith: {
                $0.sequence > $1.sequence ? $0 : $1
            })
            return latest.mapValues(\.local)
        }
    }
    private struct RecoveryResult: Sendable {
        let completed: [UUID]
        let errors: [String]
    }
    private var recoveryPass: RecoveryPass?
    private var successorRecoveryPass: RecoveryPass?
    private var recoveryPassCount = 0
    private var recoveryParticipantSequence: UInt64 = 0
    private var replayWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var replayAll: [CheckedContinuation<Void, Error>] = []
    private var departureReplay: [UUID: [CheckedContinuation<Void, Error>]] = [:]

    init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void,
         retainEvidence: @escaping @Sendable (TrustedApprovalsCoordinator, Bool) -> Void = { _, _ in },
         beforeReservation: @escaping @Sendable (UUID) async throws -> Void = { _ in },
         beforeTargetInspection: @escaping @Sendable (UUID) async throws -> Void = { _ in },
         beforeAuthorityPreparation: @escaping @Sendable (UUID) async throws -> Void = { _ in },
         beforeInspectionRead: @escaping @Sendable () async throws -> Void = {},
         beforeRecoverySealing: @escaping @Sendable () async throws -> Void = {},
         beforeReplayApplication: (@Sendable (UUID) async throws -> Void)? = nil,
         afterTargetInstallation: (@Sendable (UUID) async throws -> Void)? = nil,
         beforeRemovalFinalization: (@Sendable (UUID, UUID) async throws -> Void)? = nil,
         beforeDepartureRetirementAdmission: (@Sendable (UUID) async throws -> Void)? = nil) {
        self.beforeRemovalFinalization = beforeRemovalFinalization
        self.beforeDepartureRetirementAdmission = beforeDepartureRetirementAdmission
        self.afterTargetInstallation = afterTargetInstallation
        self.beforeReplayApplication = beforeReplayApplication
        self.beforeRecoverySealing = beforeRecoverySealing
        self.beforeInspectionRead = beforeInspectionRead
        self.beforeAuthorityPreparation = beforeAuthorityPreparation
        self.beforeTargetInspection = beforeTargetInspection
        self.beforeReservation = beforeReservation
        self.read = read; self.write = write; self.retainEvidence = retainEvidence
    }
    private func updateRetention() {
        targets = targets.filter { $0.value.service != nil }
        inspections = inspections.filter { targets[$0.key] != nil }
        recoveryEpochs = recoveryEpochs.filter { targets[$0.key] != nil }
        preparingRecovery = preparingRecovery.filter { targets[$0.key] != nil }
        pendingRecoveryOutcomes = pendingRecoveryOutcomes.filter { targets[$0.key] != nil }
        applicationEpochs = applicationEpochs.filter { targets[$0.key.target] != nil && required[$0.key.intent] != nil }
        recoveryHandles = recoveryHandles.filter { $0.value.reference.value != nil }
        for (serviceID, subscription) in recoverySubscriptions where !targets.keys.contains(where: { $0.service == serviceID && $0.registration == subscription.registrationID }) {
            subscription.invalidate(); recoverySubscriptions[serviceID] = nil
        }
        retainEvidence(self, recoveryHandles.values.contains(where: { $0.pin != nil }) || !envelope.revocations.isEmpty || !failures.isEmpty || mutationFailure != nil || !targetPins.isEmpty || !departureRecovery.isEmpty)
    }
    var observation: Observation {
        .init(requestedGeneration: generation, acceptedGeneration: accepted?.binding.permit.generation,
              queuedGeneration: pending?.registration.generation, preparingGeneration: preparing,
              mutationWaiters: (admissions[.client]?.count ?? 0) + queuedRevocations, encodings: encodings, writes: writes,
              transitionActive: lane != nil, recoveryPins: recoveryHandles.values.filter { $0.pin != nil }.count, recoverySubscriptions: recoverySubscriptions.count,
              targets: targets.count, inspections: inspections.values.filter { $0 == baseline }.count, obligations: required.count, departures: departures.count, queuedRevocations: queuedRevocations, admissionResumes: admissionResumes, admissionAdvances: admissionAdvances, progressWaiters: admissions[.progress]?.count ?? 0, recoveryPasses: recoveryPassCount, recoveryParticipants: recoveryPass?.inputs.count ?? 0, successorParticipants: successorRecoveryPass?.participants.count ?? 0, departureInspectionWaiters: departures.values.reduce(0) { $0 + $1.inspectionWaiterCount }, departureRecoveryParticipants: departureRecoveryTasks.values.reduce(0) { $0 + $1.participants.count },
              departureRecoverySuccessors: departureRecoverySuccessors.values.reduce(0) { $0 + $1.participants.count },
              pendingLocalOutcomes: pendingRecoveryOutcomes.count, applicationRecoveryTargets: recoveryTargets.count)
    }
    private var outstandingIntents: [RequestRevocationIntent] {
        envelope.revocations + removals.values.map(\.intent).sorted { $0.operationID.uuidString < $1.operationID.uuidString }
    }
    private func readTrustedBytes() async throws -> Data? {
        let read = read
        return try await Task.detached { try read() }.value
    }
    private var revision: TrustedRevocationRevision { .init(coordinator: id, sequence: sequence) }
    private var snapshot: Snapshot {
        let first = failures.min { $0.key.uuidString < $1.key.uuidString }
        return .init(approvals: Dictionary(envelope.approvals.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
            diagnostic: mutationFailure.map { "Trusted TV operation \($0.operation): " + $0.message }
                ?? first.map { "Trusted TV intent \($0.key): " + $0.value.message },
            diagnosticID: mutationFailure?.operation ?? first?.key)
    }
    static func unavailable(_ message: String) -> ShaderRequestError { .unavailable(message) }
    private func validate(_ permit: TrustedOwnerPermit) throws {
        guard permit.lifetime.isCurrent, let current = accepted?.binding.permit, current.isCurrent,
              current.lifetime === permit.lifetime else {
            throw Self.unavailable("This catalog server was replaced. Use its accepted replacement before changing TV access.")
        }
    }
    /// Only new client mutations wait for registration. Progress required to
    /// complete that registration must remain independent of client admission.
    private func acquire(_ admission: Admission, cancellable: Bool = true,
                         permit: TrustedOwnerPermit? = nil) async throws -> UUID {
        let token = UUID()
        return try await withTaskCancellationHandler {
            if cancellable { try Task.checkCancellation() }
            let granted = try await withCheckedThrowingContinuation { continuation in
                admissions[admission, default: AdmissionQueue()].append(.init(id: token, continuation: continuation))
                advanceAdmission()
            }
            do {
                if cancellable { try Task.checkCancellation() }
                if admission != .progress && admission != .replacement { try requireAuthorityReady() }
                if let permit { try validate(permit) }
                return granted
            } catch { release(granted); throw error }
        } onCancel: {
            if cancellable { Task { await self.cancelWaiter(token) } }
        }
    }
    private func requireAuthorityReady() throws {
        if let ticket = departureRecovery.values.min(by: { $0.id.uuidString < $1.id.uuidString }) {
            throw TrustedDepartureRecoveryError(diagnosticID: ticket.id, serviceID: ticket.serviceID)
        }
    }
    private func invalidateBaseline() {
        baseline &+= 1
        for departure in departures.values { departure.invalidatePreparation() }
    }
    private func evidence(for key: TargetKey) -> TrustedAuthorityDeparture.Evidence {
        .init(baseline: baseline, registration: key.registration,
              obligations: Set(required.filter { $0.value.contains(key) }.keys))
    }
    private func require(_ intent: RequestRevocationIntent, on key: TargetKey, target: ShaderRequestService) {
        if required[intent.operationID, default: []].insert(key).inserted {
            departures[key.service]?.invalidatePreparation()
        }
        // Eligibility is target-wide: obligations admitted after local completion
        // remain covered until that exact outcome enters a trusted pass.
        if var pending = pendingRecoveryOutcomes[key] {
            pending.intents.insert(intent.operationID); pendingRecoveryOutcomes[key] = pending
        }
        targetPins[key] = target
    }
    private func retired(_ key: TargetKey) -> Bool {
        departures[key.service]?.activated == true || departureRecovery[key.service]?.registrationID == key.registration
    }
    private func acquireProgress() async -> UUID { try! await acquire(.progress, cancellable: false) }
    private func acquireReplacement() async -> UUID { try! await acquire(.replacement, cancellable: false) }
    private func acquireDeparture() async throws -> UUID { try await acquire(.departure) }
    private func acquireRevocation(_ permit: TrustedOwnerPermit) async throws -> UUID {
        try await acquire(.revocation, permit: permit)
    }
    private func cancelWaiter(_ token: UUID) {
        for kind in Admission.allCases {
            if let waiter = admissions[kind]?.remove(token) {
                waiter.continuation.resume(throwing: CancellationError())
                advanceAdmission(); return
            }
        }
    }
    private func advanceAdmission() {
        guard lane == nil else { return }
        admissionAdvances += 1
        // An ineligible client never stands in the way of its own dependency.
        // Ready revocations precede both new departure preparation and activation.
        let eligible: [Admission] = [.progress] + (departures.isEmpty ? [.revocation] : []) +
            (queuedRevocations == 0 ? [.departure] : []) + [.replacement] +
            (pending == nil && preparing == nil ? [.client] : [])
        for kind in eligible {
            if let head = admissions[kind]?.first, let waiter = admissions[kind]?.remove(head) {
                lane = head; admissionResumes += 1
                waiter.continuation.resume(returning: head); return
            }
        }
    }
    private func release(_ token: UUID) {
        precondition(lane == token)
        lane = nil
        updateRetention()
        advanceAdmission()
    }
    /// Admission is synchronous on the authority actor; scheduling cannot reorder these generations.
    func register(_ owner: Owner, onlyIfVacant: Bool = false) throws -> Registration {
        guard owner.eligibility.isCurrent else { throw Self.unavailable("The proposed catalog server lifetime ended before registration.") }
        if onlyIfVacant, accepted != nil || pending != nil || preparing != nil {
            throw Self.unavailable("Catalog server handoff is pending. Wait for its accepted binding.")
        }
        failedRegistration = nil
        generation &+= 1
        let preparation = TrustedRegistrationPreparation()
        let receipt = Registration(generation: generation, completion: .init(onCancellation: { preparation.changed.finish() }), preparation: preparation)
        preparingRegistration?.preparation.supersede()
        pending?.registration.completion.complete(.success(.superseded))
        pending = Request(owner: owner, registration: receipt)
        if registrationTask == nil { registrationTask = Task { await self.drainRegistrations() } }
        return receipt
    }
    private func configure(_ target: ShaderRequestService, transfer: ShaderRequestService.AuthorityTransfer? = nil,
                           admitActivation: @Sendable () throws -> Void = {}) async throws {
        let serviceID = target.runtimeID
        guard departures[serviceID] == nil else {
            throw Self.unavailable("This request service has a trusted authority handoff pending; retry registration after it finishes.")
        }
        let callback: @Sendable (TrustedLocalRecovery) async throws -> TrustedRecoveryCompletion = { [weak self] local in
            guard let self else { throw Self.unavailable("The trusted approval authority is unavailable.") }
            return try await self.retry(requester: serviceID, local: local)
        }
        let installation = await target.prepareTargetInstallation(authority: id)
        let registration = installation.registration
        let key = TargetKey(service: serviceID, registration: registration)
        // The service may admit local preparation before this actor resumes from
        // installation. Its exact target must already exist when that happens.
        targets[key] = Target(service: target, key: key)
        targetInstallations[key] = installation
        if recoveryEpochs[key] == nil { recoveryEpochs[key] = UUID() }
        for intent in outstandingIntents { require(intent, on: key, target: target) }
        defer {
            if targetInstallations[key] === installation {
                targetInstallations[key] = nil
                if !installation.isPublished {
                    targets[key] = nil; inspections[key] = nil; recoveryEpochs[key] = nil; targetPins[key] = nil
                    for intent in Array(required.keys) where required[intent]?.contains(key) == true {
                        required[intent]?.remove(key)
                        if required[intent]?.isEmpty == true { required[intent] = nil }
                    }
                }
            }
        }
        var inspection: TrustedRevocationInspection?
        if let transfer {
            (_, inspection) = try await target.installTrustedAuthority(transfer, id: id,
                intents: outstandingIntents, revision: revision, completion: callback, authority: self, installation: installation, admitActivation: admitActivation)
        } else { _ = try await target.installRevocationCoordinator(authority: self, installation: installation, recovery: callback) }
        let previous = targets.keys.filter { $0.service == serviceID && $0 != key }
        for old in previous {
            targets[old] = nil; inspections[old] = nil; targetPins[old] = nil; recoveryTargets.remove(old)
            recoveryEpochs[old] = nil; preparingRecovery[old] = nil; pendingRecoveryOutcomes[old] = nil
            applicationEpochs = applicationEpochs.filter { $0.key.target != old }
            failedApplications = failedApplications.filter { $0.key.target != old }
            for intent in required.keys where required[intent]?.contains(old) == true {
                required[intent]?.remove(old); required[intent]?.insert(key); targetPins[key] = target
                applications[intent]?[old] = nil; finalizedRemovals[intent]?.remove(old)
            }
        }
        targets[key] = Target(service: target, key: key)
        if recoveryEpochs[key] == nil { recoveryEpochs[key] = UUID() }
        if inspection?.registrationID == registration { inspections[key] = baseline }
        // A new target cannot disappear from the quorum while fresh inspection awaits.
        for intent in outstandingIntents {
            require(intent, on: key, target: target)
        }
        if let afterTargetInstallation { try await afterTargetInstallation(serviceID) }
        await target.rememberTrustedAuthority(self)
        let subscription = TrustedRecoverySubscription(authority: id, serviceID: serviceID, registrationID: registration)
        recoverySubscriptions[serviceID]?.invalidate(); recoverySubscriptions[serviceID] = subscription
        await target.observeHostRecovery(subscription) { [weak self] service, revision, required in
            await self?.retainRecovery(service, subscription: subscription, revision: revision, required: required)
        }
    }
    /// Target-local preparation runs outside the authority lane, but publishes
    /// its epoch before it can mutate metadata or invalidate application evidence.
    func beginTargetRecovery(_ target: ShaderRequestService, preparation: TrustedLocalPreparation) async throws -> Bool {
        let registration = preparation.registration, attempt = preparation.attempt
        let key = TargetKey(service: target.runtimeID, registration: registration)
        // Read-only lane holders cannot delay a local fence. An already-admitted
        // removal, however, owns these exact proofs until its write settles.
        while let admission = removalAdmissions.values.first(where: { $0.keys.contains(key) }) {
            try await admission.completion.wait()
        }
        try Task.checkCancellation()
        guard preparation.authority == id, preparation.serviceID == target.runtimeID,
              targets[key]?.service === target, targetInstallations[key]?.isPublished != false else { return false }
        // An exact exceptional target whose binding is still current may repair
        // metadata without authorizing its retired cancellation proofs.
        if retired(key), departureRecovery[key.service]?.registrationID != key.registration ||
            required.values.contains(where: { $0.contains(key) }) { return false }
        recoveryEpochs[key] = attempt; preparingRecovery[key] = attempt
        pendingRecoveryOutcomes[key] = nil
        for intent in required.keys where required[intent]?.contains(key) == true && removals[intent] == nil {
            applications[intent]?[key] = nil
            applicationEpochs[.init(intent: intent, target: key)] = nil
            // Preparation is provisional, not an application failure. Keep an
            // existing diagnostic instead of overwriting it with transient text.
            recoveryTargets.insert(key)
        }
        return true
    }
    func endTargetRecovery(serviceID: UUID, registration: UUID, attempt: UUID, outcome: TrustedLocalRecovery?, requiresTrustedPass: Bool = false) async {
        let key = TargetKey(service: serviceID, registration: registration)
        guard preparingRecovery[key] == attempt else { return }
        preparingRecovery[key] = nil
        if let outcome {
            if outcome.completed {
                if requiresTrustedPass, required.values.contains(where: { $0.contains(key) }) {
                    pendingRecoveryOutcomes[key] = .init(attempt: attempt, intents: Set(required.filter { $0.value.contains(key) }.keys))
                }
                clearApplicationBlockers(on: key) { _, blocker in blocker.localAttempt == attempt }
            } else { suppressApplications(to: key, outcome: outcome) }
        } else {
            suppressApplications(to: key, outcome: .init(phase: .interrupted("Local recovery was cancelled. Choose Retry Recovery to complete it.")))
        }
    }
    private func applicationIsCurrent(_ attempt: Attempt, epoch: UUID) -> Bool {
        recoveryEpochs[attempt.target] == epoch && preparingRecovery[attempt.target] == nil && pendingRecoveryOutcomes[attempt.target] == nil &&
            failedApplications[attempt] == nil && !retired(attempt.target)
    }
    private struct InspectionPass {
        let baseline: UInt64
        let targets: Set<TargetKey>
    }
    private func currentInspection() -> InspectionPass? {
        let current = Set(targets.keys.filter { !retired($0) })
        guard loaded, current.allSatisfy({ inspections[$0] == baseline }) else { return nil }
        return .init(baseline: baseline, targets: current)
    }
    private func matches(_ pass: InspectionPass?) -> Bool {
        guard let pass, let current = currentInspection() else { return false }
        return pass.baseline == current.baseline && pass.targets == current.targets
    }
    private func retry(requester: UUID, local: TrustedLocalRecovery) async throws -> TrustedRecoveryCompletion {
        try Task.checkCancellation()
        let participantID = UUID(), receipt = RequestPersistence.CommitTicket<RecoveryResult>()
        recoveryParticipantSequence &+= 1
        let participant = RecoveryParticipant(requester: requester, local: local, receipt: receipt, sequence: recoveryParticipantSequence)
        let passID: UUID
        if recoveryPass == nil {
            recoveryPass = RecoveryPass()
            recoveryPass!.participants[participantID] = participant
            passID = recoveryPass!.id
            startRecoveryPass()
        } else if recoveryPass?.state == .collecting, recoveryPass?.task?.isCancelled != true {
            recoveryPass!.participants[participantID] = participant
            passID = recoveryPass!.id
        } else {
            if successorRecoveryPass == nil { successorRecoveryPass = RecoveryPass() }
            successorRecoveryPass!.participants[participantID] = participant
            passID = successorRecoveryPass!.id
        }
        let result: RecoveryResult
        do {
            result = try await withTaskCancellationHandler {
                try await receipt.value()
            } onCancel: { Task { await self.cancelRecoveryParticipant(participantID, pass: passID) } }
        } catch {
            // Retire on this actor before the caller can re-enter. The callback
            // remains necessary to wake a suspended participant promptly.
            cancelRecoveryParticipant(participantID, pass: passID)
            throw error
        }
        if !result.errors.isEmpty {
            throw TrustedPartialRecovery(completedServices: result.completed,
                remaining: Array(result.errors.prefix(9)).map { BoundedDiagnostics.bounded($0, bytes: 8192) })
        }
        return .init(completedServices: result.completed)
    }
    private func cancelRecoveryParticipant(_ id: UUID, pass: UUID) {
        if recoveryPass?.id == pass {
            recoveryPass?.participants.removeValue(forKey: id)
            if recoveryPass?.participants.isEmpty == true {
                // Close admission before cancellation; the successor cannot start
                // until the existing task has released its holds and settlement.
                recoveryPass?.state = .finishing
                recoveryPass?.task?.cancel()
            }
        } else if successorRecoveryPass?.id == pass {
            successorRecoveryPass?.participants.removeValue(forKey: id)
            if successorRecoveryPass?.participants.isEmpty == true { successorRecoveryPass = nil }
        }
    }
    private func startRecoveryPass() {
        guard let pass = recoveryPass, pass.task == nil else { return }
        recoveryPassCount += 1
        recoveryPass?.task = Task {
            let result: Result<RecoveryResult, Error>
            do { result = .success(try await self.recoverTrusted(pass.id)) }
            catch { result = .failure(error) }
            self.completeRecoveryPass(pass.id, result: result)
        }
    }
    private func completeRecoveryPass(_ id: UUID, result: Result<RecoveryResult, Error>) {
        guard recoveryPass?.id == id else { return }
        recoveryPass?.state = .finished
        let waiting = recoveryPass!.participants.values.map(\.receipt)
        recoveryPass = successorRecoveryPass; successorRecoveryPass = nil
        waiting.forEach { $0.complete(result) }
        startRecoveryPass()
    }
    private func recoverTrusted(_ passID: UUID) async throws -> RecoveryResult {
        var completed: Set<UUID> = [], errors: [String] = []
        var completedReceipts: [UUID: TrustedLocalRecoveryReceipt] = [:]
        var heldTargets: [UUID: ShaderRequestService] = [:]
        do {
            var registrationInspection: InspectionPass?
            try Task.checkCancellation()
            if let candidate = failedRegistration {
                if candidate.eligibility.isCurrent {
                    do {
                        switch try await register(candidate).value() {
                        case .accepted(let binding):
                            if binding.permit.isCurrent { registrationInspection = currentInspection() }
                        case .superseded: break
                        }
                    } catch {
                        try Task.checkCancellation()
                        let detail = error is CancellationError ? TrustedRegistrationInterrupted(lifetimeEnded: !candidate.eligibility.isCurrent).localizedDescription : error.localizedDescription
                        errors.append("Registration: " + detail)
                    }
                } else { failedRegistration = nil }
            }
            try Task.checkCancellation()
            let obligated = Set(required.values.flatMap { $0 })
            recoveryTargets.formIntersection(obligated)
            // Explicit callers supply their local phase; another target is recovered
            // only when an actual cancellation obligation requires that recovery.
            let inputServices = Set(recoveryPass?.id == passID ? recoveryPass!.inputs.keys : Dictionary<UUID, TrustedLocalRecovery>().keys)
            let recovering = recoveryTargets.union(obligated.filter { inputServices.contains($0.service) })
            for key in recovering.sorted(by: { ($0.service.uuidString, $0.registration.uuidString) < ($1.service.uuidString, $1.registration.uuidString) }) {
                try Task.checkCancellation()
                guard let target = targets[key]?.service else { continue }
                let priorBlockers = failedApplications.filter { $0.key.target == key }
                let outcome: TrustedLocalRecovery
                if let supplied = recoveryPass?.id == passID ? recoveryPass?.inputs[key.service] : nil {
                    heldTargets[key.service] = target
                    outcome = await target.validateTrustedRecovery(supplied, pass: passID)
                } else {
                    heldTargets[key.service] = target
                    outcome = try await target.trustedRecoveryOutcome(pass: passID, authority: id)
                }
                let commit = try await acquire(.progress)
                guard targets[key]?.service === target else { release(commit); continue }
                applyRecoveryOutcome(outcome, to: key, priorBlockers: priorBlockers)
                if outcome.completed, let receipt = outcome.receipt {
                    completed.insert(key.service); completedReceipts[key.service] = receipt
                }
                release(commit)
            }
            try Task.checkCancellation()
            let inspection = try await acquire(.progress)
            if !matches(registrationInspection) {
                do { try await readFresh(target: service) }
                catch { errors.append("Inspection: " + error.localizedDescription) }
            }
            release(inspection)
            try Task.checkCancellation()
            try await beforeRecoverySealing()
            try Task.checkCancellation()
            // Seal synchronously on the authority actor. Later callers belong
            // only to the successor, even while this pass is awaiting a target.
            if recoveryPass?.id == passID { recoveryPass?.state = .sealed }
            let sealedInputs = recoveryPass?.id == passID ? recoveryPass!.inputs : [:]
            for (serviceID, input) in sealedInputs {
                for key in targets.keys.filter({ $0.service == serviceID }) {
                    guard let target = targets[key]?.service else { continue }
                    heldTargets[serviceID] = target
                    let priorBlockers = failedApplications.filter { $0.key.target == key }
                    let commit = try await acquire(.progress)
                    let outcome = await target.validateTrustedRecovery(input, pass: passID)
                    if targets[key]?.service === target {
                        applyRecoveryOutcome(outcome, to: key, priorBlockers: priorBlockers)
                        if outcome.completed, let receipt = outcome.receipt {
                            completed.insert(serviceID); completedReceipts[serviceID] = receipt
                        } else { completed.remove(serviceID); completedReceipts[serviceID] = nil }
                    }
                    release(commit)
                }
            }
            let commit = try await acquire(.progress)
            failedRemovalWrites.removeAll()
            release(commit)
            if recoveryPass?.id == passID { recoveryPass?.state = .replaying }
            if loaded {
                do { try await replay() } catch { errors.append(error.localizedDescription) }
            }
            try Task.checkCancellation()
            let finishing = try await acquire(.progress)
            if recoveryPass?.id == passID { recoveryPass?.state = .finishing }
            completed = completed.filter { serviceID in
                guard let receipt = completedReceipts[serviceID] else { return false }
                let key = TargetKey(service: serviceID, registration: receipt.registrationID)
                return recoveryEpochs[key] == receipt.attemptID && preparingRecovery[key] == nil
            }
            if !errors.isEmpty, !required.isEmpty {
                let remaining = required.sorted { $0.key.uuidString < $1.key.uuidString }.prefix(8).map { intent, targets in
                    "Intent " + intent.uuidString + ": " + targets.map(\.service.uuidString).sorted().joined(separator: ", ")
                }.joined(separator: "\n")
                errors.append("Remaining trusted targets:\n" + remaining)
            }
            release(finishing)
            // Original-target repair must never run while this authority owns
            // the lane or recursively join the trusted pass calling it.
            errors += await finishRecoveredDepartures()
            let readiness = try await acquire(.progress)
            do { try requireAuthorityReady() } catch { errors.append(error.localizedDescription) }
            release(readiness)
        } catch {
            for target in heldTargets.values { await target.finishTrustedRecovery(pass: passID) }
            throw error
        }
        for target in heldTargets.values { await target.finishTrustedRecovery(pass: passID) }
        return .init(completed: completed.sorted { $0.uuidString < $1.uuidString }, errors: errors)
    }
    private func applyRecoveryOutcome(_ outcome: TrustedLocalRecovery, to key: TargetKey, priorBlockers: [Attempt: ApplicationBlocker]) {
        if outcome.completed {
            if pendingRecoveryOutcomes[key]?.attempt == outcome.receipt?.attemptID { pendingRecoveryOutcomes[key] = nil }
            clearApplicationBlockers(on: key) { attempt, blocker in
                priorBlockers[attempt]?.generation == blocker.generation ||
                    (outcome.receipt?.attemptID != nil && blocker.localAttempt == outcome.receipt?.attemptID)
            }
        } else { suppressApplications(to: key, outcome: outcome) }
    }
    private func finishPendingObligation(_ intent: UUID, on key: TargetKey) {
        guard var pending = pendingRecoveryOutcomes[key] else { return }
        pending.intents.remove(intent)
        // Include every still-required obligation, including any added while an
        // already-committed removal was completing on another actor.
        pending.intents.formUnion(required.filter { $0.value.contains(key) }.keys)
        pendingRecoveryOutcomes[key] = pending.intents.isEmpty ? nil : pending
    }
    private func clearApplicationBlockers(on key: TargetKey, matching: (Attempt, ApplicationBlocker) -> Bool) {
        failedApplications = failedApplications.filter { $0.key.target != key || !matching($0.key, $0.value) }
        if !failedApplications.keys.contains(where: { $0.target == key }),
           preparingRecovery[key] == nil, pendingRecoveryOutcomes[key] == nil {
            recoveryTargets.remove(key)
        } else if required.values.contains(where: { $0.contains(key) }) {
            recoveryTargets.insert(key)
        }
    }
    private func suppressApplications(to key: TargetKey, outcome: TrustedLocalRecovery) {
        let intents = required.filter { $0.value.contains(key) }
        guard !intents.isEmpty else { recoveryTargets.remove(key); return }
        for intent in intents {
            let detail = "Service " + key.service.uuidString + ": " + (outcome.failure ?? "Local recovery did not complete.")
            blockApplication(.init(intent: intent.key, target: key), diagnostic: outcome.failure ?? "Local recovery did not complete.", localAttempt: outcome.receipt?.attemptID)
            let error = Self.unavailable(detail)
            failures[intent.key] = failures[intent.key]?.appending(error) ?? Failure(error, diagnosticID: intent.key)
        }
        recoveryTargets.insert(key)
    }
    private func inspect(_ known: Target, intents: [RequestRevocationIntent]) async throws {
        guard let target = known.service else { return }
        let departure = departures[known.key.service]
        let permit = departure?.beginInspection()
        if departure != nil && permit == nil { return } // Activation already owns the target.
        var succeeded = false
        defer { if let permit { departure?.finishInspection(permit, succeeded: succeeded) } }
        let obligations = intents.filter { finalizedRemovals[$0.operationID]?.contains(known.key) != true }
        // Record every obligation before the first fallible target notification.
        for intent in obligations { require(intent, on: known.key, target: target) }
        inspections[known.key] = nil
        do {
            try await beforeTargetInspection(known.key.service)
            let receipt = try await target.loadTrustedRevocations(obligations, revision: revision)
            guard receipt.registrationID == known.key.registration else { throw Self.unavailable("The inspected TV target registration changed; retry recovery.") }
            inspections[known.key] = baseline; succeeded = true
            for intent in obligations {
                if let failure = failures[intent.operationID] {
                    await target.revocationReplayFailed(failure, intent: intent, revision: revision)
                }
            }
        } catch { await target.revocationReplayFailed(error, revision: revision); throw error }
    }
    private func readFresh(target: ShaderRequestService?) async throws {
        // Protect the complete inspection, including its backend read. Acquiring
        // only at target notification leaves activation racing unread evidence.
        let permits = departures.values.compactMap { departure in
            departure.beginInspection().map { (departure, $0) }
        }
        var readSucceeded = false
        defer { for (departure, permit) in permits { departure.finishInspection(permit, succeeded: readSucceeded) } }
        let current: Data?, candidate: TrustedTVApprovals
        do {
            try await beforeInspectionRead()
            current = try await readTrustedBytes()
            candidate = try current.map(TrustedTVApprovals.decode) ?? TrustedTVApprovals()
        } catch {
            loaded = false; invalidateBaseline()
            if let target { await target.revocationReplayFailed(error, revision: revision) }
            throw error
        }
        readSucceeded = true
        let changed = current != bytes
        if changed { invalidateBaseline() }
        envelope = candidate; bytes = current; if changed { sequence &+= 1 }; loaded = true
        let intents = outstandingIntents
        var errors: [Error] = []
        for known in targets.values where !retired(known.key) {
            do { try await inspect(known, intents: intents) } catch { errors.append(error) }
        }
        if changed { await notify() }
        let ids = Set(candidate.revocations.map(\.operationID)).union(removals.keys)
        failures = failures.filter { ids.contains($0.key) }
        if let error = errors.first { throw error }
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
        do { if !loaded || inspections[known.key] != baseline { try await readFresh(target: target) } }
        catch { release(token); await cancelDeparture(serviceID: target.runtimeID, ticket: ticket); throw error }
        let needed = required.values.contains { $0.contains { $0.service == target.runtimeID } }
        release(token)
        do {
            if needed { try await replayDeparture(serviceID: target.runtimeID) }
            try await target.settleTrustedAuthorityDeparture()
            let check = try await acquire(.progress)
            let outstanding = required.values.contains { $0.contains { $0.service == target.runtimeID } }
            departure.validate(evidence(for: known.key))
            if !outstanding, loaded, inspections[known.key] == baseline { departure.prepared(evidence(for: known.key)) }
            release(check)
            guard !outstanding, loaded, inspections[known.key] == baseline else { throw Self.unavailable("The previous trusted authority still requires cancellation or inspection recovery before switching.") }
            return departure
        } catch { await cancelDeparture(serviceID: target.runtimeID, ticket: ticket); throw error }
    }
    func cancelDeparture(serviceID: UUID, ticket: UUID) async {
        let token = await acquireProgress()
        if let departure = departures[serviceID], departure.id == ticket, !departure.activated {
            // A failed inspection must never be cleared by reapplying cached data.
            if let known = targets.values.first(where: { $0.key.service == serviceID }) {
                do {
                    if loaded { try await inspect(known, intents: outstandingIntents) }
                    else { try await readFresh(target: known.service) }
                } catch { await known.service?.revocationReplayFailed(error, revision: revision) }
            }
            departures[serviceID] = nil; departure.close()
        }
        release(token)
    }
    func finishDeparture(serviceID: UUID, ticket: UUID) async {
        let token = await acquireProgress()
        defer { release(token) }
        guard let departure = departures[serviceID], departure.id == ticket, departure.activated else { return }
        let retiredKeys = Set(targets.keys.filter { $0.service == serviceID && $0.registration == departure.registrationID })
        guard !required.values.contains(where: { !$0.isDisjoint(with: retiredKeys) }) else {
            await flagDepartureRecovery(serviceID: serviceID, ticket: ticket)
            return
        }
        await retireDeparture(departure, keys: retiredKeys)
    }
    /// Defensive invariant handling, not a producer of new cancellation obligations.
    func retainDepartureRecovery(serviceID: UUID, ticket: UUID) async {
        let token = await acquireProgress(); defer { release(token) }
        await flagDepartureRecovery(serviceID: serviceID, ticket: ticket)
    }
    private func flagDepartureRecovery(serviceID: UUID, ticket: UUID) async {
        guard let departure = departures[serviceID], departure.id == ticket, departure.activated else { return }
        departureRecovery[serviceID] = departure
        departures[serviceID] = nil; departure.close()
        for key in targets.keys where key.service == serviceID && key.registration == departure.registrationID {
            if let target = targets[key]?.service { targetPins[key] = target }
        }
        await recordMutationFailure(TrustedDepartureRecoveryError(diagnosticID: ticket, serviceID: serviceID), operation: ticket, context: "Authority departure")
        if let target = targets.values.first(where: { $0.key.service == serviceID })?.service { await attachDepartureRecovery(ticket: ticket, to: target) }
        advanceAdmission()
    }
    private func attachDepartureRecovery(ticket: UUID, to target: ShaderRequestService) async {
        guard let departure = departureRecovery.values.first(where: { $0.id == ticket }) else { return }
        let original = targets.values.first { $0.key.service == departure.serviceID && $0.key.registration == departure.registrationID }?.service
        let journal = await original?.trustedRecoveryJournal()
        let endpoint = departureEndpoints[ticket] ?? .init(authority: self, ticketID: ticket, serviceID: departure.serviceID, journal: journal)
        departureEndpoints[ticket] = endpoint
        endpointTargets[ticket, default: [:]][target.runtimeID] = .init(target)
        await target.rememberAuthorityRecovery(endpoint)
    }
    /// No successful registration is required to recover an old authority's exact
    /// ticket. Never apply an old cancellation receipt to a replacement binding.
    func recoverDeparture(serviceID: UUID, ticket: UUID) async throws {
        try Task.checkCancellation()
        guard departureRecoveryTasks[ticket].map({ $0.serviceID == serviceID }) ?? true else {
            throw Self.unavailable("The departure recovery ticket belongs to another exact service.")
        }
        let participant = UUID(), receipt = RequestPersistence.CommitTicket<Void>()
        let jobID: UUID
        if departureRecoveryTasks[ticket] == nil {
            departureRecoveryTasks[ticket] = DepartureRecoveryJob(serviceID: serviceID)
            departureRecoveryTasks[ticket]!.participants[participant] = receipt
            jobID = departureRecoveryTasks[ticket]!.id
            startDepartureRecovery(ticket)
        } else if departureRecoveryTasks[ticket]?.closing == false {
            departureRecoveryTasks[ticket]!.participants[participant] = receipt
            jobID = departureRecoveryTasks[ticket]!.id
        } else {
            if departureRecoverySuccessors[ticket] == nil { departureRecoverySuccessors[ticket] = DepartureRecoveryJob(serviceID: serviceID) }
            departureRecoverySuccessors[ticket]!.participants[participant] = receipt
            jobID = departureRecoverySuccessors[ticket]!.id
        }
        do {
            try await withTaskCancellationHandler {
                try await receipt.value()
            } onCancel: { Task { await self.cancelDepartureRecovery(ticket: ticket, job: jobID, participant: participant) } }
        } catch {
            cancelDepartureRecovery(ticket: ticket, job: jobID, participant: participant)
            throw error
        }
    }
    private func cancelDepartureRecovery(ticket: UUID, job: UUID, participant: UUID) {
        if departureRecoveryTasks[ticket]?.id == job {
            departureRecoveryTasks[ticket]?.participants[participant] = nil
            if departureRecoveryTasks[ticket]?.participants.isEmpty == true {
                departureRecoveryTasks[ticket]?.closing = true
                departureRecoveryTasks[ticket]?.task?.cancel()
                publishDepartureSettlement(ticket, settling: true)
            }
        } else if departureRecoverySuccessors[ticket]?.id == job {
            departureRecoverySuccessors[ticket]?.participants[participant] = nil
            if departureRecoverySuccessors[ticket]?.participants.isEmpty == true { departureRecoverySuccessors[ticket] = nil }
        }
    }
    private func startDepartureRecovery(_ ticket: UUID) {
        guard let job = departureRecoveryTasks[ticket], job.task == nil else { return }
        departureRecoveryTasks[ticket]?.task = Task {
            let result: Result<Void, Error>
            do { try await self.performDepartureRecovery(serviceID: job.serviceID, ticket: ticket); result = .success(()) }
            catch { result = .failure(error) }
            if Task.isCancelled,
               let departure = self.departureRecovery[job.serviceID], departure.id == ticket,
               let target = self.targets[.init(service: job.serviceID, registration: departure.registrationID)]?.service {
                await target.settleCancelledLocalRecovery()
            }
            self.finishedDepartureRecovery(ticket, job: job.id, result: result)
        }
    }
    private func finishedDepartureRecovery(_ ticket: UUID, job: UUID, result: Result<Void, Error>) {
        guard departureRecoveryTasks[ticket]?.id == job else { return }
        let waiting = departureRecoveryTasks[ticket]!.participants.values
        departureRecoveryTasks[ticket] = departureRecoverySuccessors.removeValue(forKey: ticket)
        publishDepartureSettlement(ticket, settling: false)
        waiting.forEach { $0.complete(result) }
        startDepartureRecovery(ticket)
    }
    private func publishDepartureSettlement(_ ticket: UUID, settling: Bool) {
        guard let endpoint = departureEndpoints[ticket], endpoint.setSettling(settling) else { return }
        for target in endpointTargets[ticket]?.values ?? Dictionary<UUID, WeakRequestService>().values {
            if let service = target.value { Task { await service.authorityRecoveryChanged(endpoint) } }
        }
    }
    private func departureObligations(_ keys: Set<TargetKey>) -> Bool {
        required.values.contains { !$0.isDisjoint(with: keys) }
    }
    private func unverifiableDeparture(_ ticket: UUID) -> ShaderRequestError {
        Self.unavailable("Authority departure " + ticket.uuidString + " has unverifiable cancellation receipts for its retired registration. Retain trusted approvals and request journals for manual repair; the replacement authority cannot acknowledge them.")
    }
    private func performDepartureRecovery(serviceID: UUID, ticket: UUID) async throws {
        let capture = try await acquire(.progress)
        guard let departure = departureRecovery[serviceID], departure.id == ticket else { release(capture); return }
        let keys = Set(targets.keys.filter { $0.service == serviceID && $0.registration == departure.registrationID })
        guard !departureObligations(keys) else { release(capture); throw unverifiableDeparture(ticket) }
        let target = keys.compactMap { targets[$0]?.service }.first
        release(capture)
        try Task.checkCancellation()
        guard let target else {
            throw Self.unavailable("Authority departure " + ticket.uuidString + " cannot access its original request service. Retain its exact journal and trusted evidence for manual repair; a replacement folder cannot establish ownership.")
        }
        // Clean, generation-bound ownership can retire while healthy admitted
        // work continues. A real metadata fault still requires original repair.
        if await target.departureRetirementAssessment(authority: id, ticket: ticket) == nil {
            let local = try await target.recoverDepartureLocal()
            guard local.completed else {
                throw TrustedPartialRecovery(completedServices: [], remaining: ["Original departure target " + serviceID.uuidString + ": " + (local.failure ?? "Local recovery is unverified.")])
            }
        }
        try Task.checkCancellation()
        try await target.settleTrustedAuthorityDeparture()
        guard let assessment = await target.departureRetirementAssessment(authority: id, ticket: ticket) else {
            throw Self.unavailable("Original departure target evidence changed before retirement. Retain its exact journal and choose Retry Recovery.")
        }
        let commit = try await acquire(.progress); defer { release(commit) }
        guard departureRecovery[serviceID] === departure else { return }
        guard !departureObligations(keys) else { throw unverifiableDeparture(ticket) }
        if !loaded || keys.contains(where: { inspections[$0] != baseline }) { try await readFresh(target: nil) }
        guard !departureObligations(keys) else { throw unverifiableDeparture(ticket) }
        guard await target.validateDepartureRetirement(assessment, authority: id, ticket: ticket) else {
            throw Self.unavailable("Original departure target evidence changed during retirement inspection. Retain its journal and choose Retry Recovery.")
        }
        if let beforeDepartureRetirementAdmission { try await beforeDepartureRetirementAdmission(serviceID) }
        guard assessment.admit() else {
            throw Self.unavailable("Original departure ownership changed before retirement admission. Retain its journal and choose Retry Recovery.")
        }
        await retireDeparture(departure, keys: keys)
        departureRecovery[serviceID] = nil
        if mutationFailure?.operation == ticket { mutationFailure = nil }
        await notify()
    }
    private func finishRecoveredDepartures() async -> [String] {
        var failures: [String] = []
        let pending = departureRecovery.values.map { ($0.serviceID, $0.id) }
        for (serviceID, ticket) in pending {
            do { try await recoverDeparture(serviceID: serviceID, ticket: ticket) }
            catch { failures.append(error.localizedDescription) }
        }
        return failures
    }
    private func retireDeparture(_ departure: TrustedAuthorityDeparture, keys retiredKeys: Set<TargetKey>) async {
        let serviceID = departure.serviceID
        let target = retiredKeys.compactMap { targets[$0]?.service }.first
        if let subscription = recoverySubscriptions[serviceID], subscription.registrationID == departure.registrationID {
            // Invalidate before the actor hop. A previously queued notification is
            // rejected by both the subscription and authority-side identity check.
            subscription.invalidate(); recoverySubscriptions[serviceID] = nil; recoveryHandles[serviceID] = nil
            await target?.removeHostRecoveryObserver(subscription)
        }
        for key in retiredKeys {
            targets[key] = nil; inspections[key] = nil; targetPins[key] = nil; recoveryTargets.remove(key)
            recoveryEpochs[key] = nil; preparingRecovery[key] = nil; pendingRecoveryOutcomes[key] = nil
        }
        applicationEpochs = applicationEpochs.filter { !retiredKeys.contains($0.key.target) }
        failedApplications = failedApplications.filter { !retiredKeys.contains($0.key.target) }
        if service?.runtimeID == serviceID { service = nil }
        if departures[serviceID]?.id == departure.id { departures[serviceID] = nil }
        departure.close()
        departureEndpoints.removeValue(forKey: departure.id)?.invalidate()
        let recipients = endpointTargets.removeValue(forKey: departure.id) ?? [:]
        for recipient in recipients.values { await recipient.value?.forgetAuthorityRecovery(ticket: departure.id) }
    }
    private var preparingRegistration: (server: UUID, lifetime: TrustedOwnerLifetime, preparation: TrustedRegistrationPreparation)?
    private enum RegistrationAbandoned: Error { case superseded }
    private func drainRegistrations() async {
        while pending != nil {
            var token = await acquireReplacement()
            guard let request = pending else { release(token); continue }
            pending = nil; preparing = request.registration.generation
            preparingRegistration = (request.owner.serverID, request.owner.eligibility, request.registration.preparation)
            var transfer: ShaderRequestService.AuthorityTransfer?
            var admittedService: ShaderRequestService?
            do {
                try requireAuthorityReady()
                if let target = request.owner.service {
                    release(token)
                    do {
                        try await beforeAuthorityPreparation(target.runtimeID)
                        transfer = try await target.prepareTrustedAuthority(id: id)
                    }
                    catch {
                        token = await acquireReplacement()
                        throw error
                    }
                    token = await acquireReplacement()
                }
                try request.registration.completion.check()
                guard request.owner.eligibility.isCurrent else { throw CancellationError() }
                guard !request.owner.requiresService || request.owner.service != nil else {
                    throw Self.unavailable("The proposed request service was released before registration.")
                }
                // A cross-authority binding changes only after a fresh backend inspection.
                if transfer != nil { try await readFresh(target: request.owner.service) }
                try request.registration.completion.check()
                guard request.registration.generation == generation else { throw RegistrationAbandoned.superseded }
                if transfer != nil {
                    let preparedSequence = sequence
                    release(token); token = await acquireReplacement()
                    if !loaded || preparedSequence != sequence { try await readFresh(target: request.owner.service) }
                    try request.registration.completion.check()
                    guard request.registration.generation == generation else { throw RegistrationAbandoned.superseded }
                    admittedService = request.owner.service
                    guard !request.owner.requiresService || admittedService != nil else { throw Self.unavailable("The proposed request service was released before activation.") }
                }
                if let target = admittedService ?? request.owner.service {
                    while true {
                        do {
                            try await configure(target, transfer: transfer, admitActivation: {
                                try request.owner.eligibility.admitWrite {
                                    try request.registration.preparation.admit { try request.registration.completion.beginMutation() }
                                }
                            })
                            break
                        }
                        catch let waiting as TrustedWorkerRetirementPending {
                            release(token)
                            do { try await waiting.retirement.wait(or: request.registration.preparation.changed) }
                            catch { token = await acquireReplacement(); throw error }
                            token = await acquireReplacement()
                            try request.registration.completion.check()
                            guard request.owner.eligibility.isCurrent else { throw CancellationError() }
                            guard request.registration.completion.hasStarted || request.registration.generation == generation else { throw RegistrationAbandoned.superseded }
                            if currentInspection() == nil { try await readFresh(target: target) }
                        }
                        catch let waiting as TrustedLocalPreparationPending {
                            release(token)
                            do { try await waiting.preparation.wait() }
                            catch { token = await acquireReplacement(); throw error }
                            token = await acquireReplacement()
                            try request.registration.completion.check()
                            guard request.registration.completion.hasStarted || request.registration.generation == generation else {
                                throw RegistrationAbandoned.superseded
                            }
                            if currentInspection() == nil { try await readFresh(target: target) }
                        }
                        catch let waiting as TrustedDepartureInspectionPending {
                            release(token)
                            do { try await waiting.departure.waitForInspection() }
                            catch { token = await acquireReplacement(); throw error }
                            token = await acquireReplacement()
                            // Destination evidence may have failed while this
                            // registration was waiting on source inspection.
                            if currentInspection() == nil { try await readFresh(target: target) }
                        }
                    }
                }
                if transfer == nil { try await readFresh(target: request.owner.service ?? service) }
                let preparedSequence = sequence
                if !request.registration.completion.hasStarted {
                    release(token); token = await acquireReplacement()
                    if !loaded || preparedSequence != sequence { try await readFresh(target: request.owner.service ?? service) }
                }
                try request.registration.completion.check()
                guard request.registration.completion.hasStarted || request.registration.generation == generation else {
                    request.registration.completion.complete(.success(.superseded)); preparing = nil; release(token); continue
                }
                if !request.registration.completion.hasStarted {
                    admittedService = request.owner.service
                    guard !request.owner.requiresService || admittedService != nil else { throw Self.unavailable("The proposed request service was released before activation.") }
                    try request.owner.eligibility.admitWrite { try request.registration.completion.beginMutation() }
                }
                let prior = accepted
                let continuing = prior?.owner.serverID == request.owner.serverID && prior?.binding.permit.lifetime.isCurrent == true
                let lifetime = continuing ? prior!.binding.permit.lifetime : TrustedOwnerLifetime()
                let permit = TrustedOwnerPermit(serverID: request.owner.serverID, generation: request.registration.generation, authority: id, lifetime: lifetime)
                if !continuing { prior?.binding.permit.lifetime.invalidate() }
                let binding = Binding(permit: permit, service: admittedService)
                prior?.binding.permit.invalidate()
                accepted = Accepted(owner: request.owner, binding: binding)
                service = request.owner.service
                await request.owner.changed(snapshot, binding)
                if let transfer, let target = admittedService { await target.finishTrustedAuthority(transfer, authority: self) }
                if let prior, prior.owner.serverID != request.owner.serverID { await prior.owner.retired() }
                request.registration.completion.complete(.success(.accepted(binding)))
            } catch {
                if let transfer {
                    release(token)
                    if let target = admittedService ?? request.owner.service { await target.cancelTrustedAuthority(transfer) }
                    else { await transfer.predecessor.cancelDeparture(serviceID: transfer.departure.serviceID, ticket: transfer.id) }
                    token = await acquireReplacement()
                }
                if error is RegistrationAbandoned || error is TrustedRegistrationSuperseded { request.registration.completion.complete(.success(.superseded)) }
                else {
                    if let recovery = error as? TrustedDepartureRecoveryError, let target = request.owner.service {
                        await attachDepartureRecovery(ticket: recovery.diagnosticID, to: target)
                    }
                    if request.registration.generation == generation, request.owner.eligibility.isCurrent, !(error is CancellationError) { failedRegistration = request.owner }
                    request.registration.completion.complete(.failure(error))
                }
            }
            preparing = nil; preparingRegistration = nil; release(token)
        }
        registrationTask = nil
    }
    func withdraw(serverID: UUID, eligibility: TrustedOwnerLifetime) async {
        if preparingRegistration?.server == serverID, preparingRegistration?.lifetime === eligibility { preparingRegistration?.preparation.supersede() }
        let token = await acquireProgress()
        defer { release(token) }
        if failedRegistration?.serverID == serverID, failedRegistration?.eligibility === eligibility { failedRegistration = nil }
        if accepted?.owner.serverID == serverID, accepted?.owner.eligibility === eligibility {
            accepted?.binding.permit.invalidate(); accepted?.binding.permit.lifetime.invalidate()
            accepted = nil; service = nil
        }
    }
    func releaseBinding(_ permit: TrustedOwnerPermit) async {
        let token = await acquireProgress()
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
        if candidate != bytes {
            let predecessor = baseline; baseline &+= 1
            // Relevant new obligations invalidate their own target in require().
            // A known approval or unrelated removal preserves prepared handoffs.
            for departure in departures.values { departure.advanceBaseline(from: predecessor, to: baseline) }
            inspections = inspections.mapValues { $0 == predecessor ? baseline : $0 }
        }
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
        let token = try await acquire(.client, permit: permit)
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
                let actual = try await readTrustedBytes()
                if actual == candidate {
                    acceptPersisted(value, bytes: candidate)
                    await notify(); return proposal
                }
                if actual == predecessor {
                    if permit.lifetime.isCurrent { proposal.eligibility.restoreAfterFailedWrite() }
                } else { throw Self.unavailable("Approval persistence has an uncertain outcome; retain trusted storage and choose Retry Recovery.") }
            } catch {
                loaded = false; invalidateBaseline()
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
                    if let service = target.service { require(intent, on: target.key, target: service) }
                }
                await notify()
                for target in admittedTargets {
                    guard let service = target.service else { continue }
                    do { try await service.commitTrustedRevocation(intent, revision: revision) }
                    catch {
                        inspections[target.key] = nil; recoveryTargets.insert(target.key)
                        _ = await record(error, intent: intent)
                    }
                }
            }
        } catch { release(token); throw error }
        release(token)
        try await replay(target: intent.operationID)
    }
    func replay(target: UUID? = nil) async throws {
        guard targets.values.contains(where: { $0.service != nil }) else {
            if let failure = required.keys.sorted(by: { $0.uuidString < $1.uuidString }).compactMap({ outstandingFailure($0) }).first { throw failure }
            return
        }
        try await withCheckedThrowingContinuation { c in
            if let target {
                guard envelope.revocations.contains(where: { $0.operationID == target }) || removals[target] != nil else { c.resume(); return }
                replayWaiters[target, default: []].append(c)
            } else { replayAll.append(c) }
            if replayTask == nil { replayTask = Task { await self.drainReplay() } }
        }
    }
    private func replayDeparture(serviceID: UUID) async throws {
        guard required.values.contains(where: { $0.contains(where: { $0.service == serviceID }) }) else { return }
        try await withCheckedThrowingContinuation { c in
            departureReplay[serviceID, default: []].append(c)
            if replayTask == nil { replayTask = Task { await self.drainReplay() } }
        }
    }
    private func completeSettledDepartures() {
        for serviceID in Array(departureReplay.keys) {
            guard !required.values.contains(where: { $0.contains(where: { $0.service == serviceID }) }) else { continue }
            departureReplay.removeValue(forKey: serviceID)?.forEach { $0.resume() }
        }
    }
    private func departureFailure(serviceID: UUID) -> Error? {
        let intents = required.filter { $0.value.contains(where: { $0.service == serviceID }) }.keys
        guard !intents.isEmpty else { return nil }
        return intents.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { failures[$0] }.first
            ?? Self.unavailable("The previous authority still has cancellation or shared removal obligations for service " + serviceID.uuidString + ". Choose Retry Recovery.")
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
    private func blockApplication(_ attempt: Attempt, diagnostic: String, localAttempt: UUID? = nil) {
        if let localAttempt, let previous = failedApplications[attempt], previous.localAttempt == localAttempt,
           previous.diagnostic == diagnostic { return }
        applicationBlockerGeneration &+= 1
        failedApplications[attempt] = .init(generation: applicationBlockerGeneration, localAttempt: localAttempt,
            diagnostic: BoundedDiagnostics.bounded(diagnostic, bytes: 8192))
    }
    private func acknowledgeIfReady(_ intent: RequestRevocationIntent) async throws -> Bool {
        guard !failedRemovalWrites.contains(intent.operationID), let needed = required[intent.operationID], !needed.isEmpty else { return false }
        let proofs = applications[intent.operationID] ?? [:]
        guard needed.allSatisfy({ proofs[$0] != nil }) else { return false }
        for key in needed where finalizedRemovals[intent.operationID]?.contains(key) != true {
            guard let target = targets[key]?.service, let proof = proofs[key] else { return false }
            if removals[intent.operationID] == nil {
                let attempt = Attempt(intent: intent.operationID, target: key)
                guard let epoch = applicationEpochs[attempt], applicationIsCurrent(attempt, epoch: epoch) else { return false }
            }
            try await target.validateTrustedRevocation(proof)
        }
        if removals[intent.operationID] == nil {
            guard needed.allSatisfy({ key in
                let attempt = Attempt(intent: intent.operationID, target: key)
                guard let epoch = applicationEpochs[attempt] else { return false }
                return applications[intent.operationID]?[key] == proofs[key] && applicationIsCurrent(attempt, epoch: epoch)
            }) else { return false }
        }
        let removal = try TrustedRevocationRemoval.checked(authority: id, intent: intent,
            proofs: needed.compactMap { proofs[$0] })
        let admission = RemovalAdmission(keys: needed)
        removalAdmissions[intent.operationID] = admission
        defer {
            removalAdmissions[intent.operationID] = nil
            admission.completion.finish()
        }
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
            if let beforeRemovalFinalization { try await beforeRemovalFinalization(intent.operationID, key.service) }
            try await target.finalizeTrustedRevocation(proof, removal: removal)
            finalizedRemovals[intent.operationID, default: []].insert(key)
        }
        finalizedRemovals[intent.operationID] = nil
        required[intent.operationID] = nil; applications[intent.operationID] = nil; removals[intent.operationID] = nil; failures[intent.operationID] = nil
        applicationEpochs = applicationEpochs.filter { $0.key.intent != intent.operationID }
        failedApplications = failedApplications.filter { $0.key.intent != intent.operationID }
        for key in needed {
            finishPendingObligation(intent.operationID, on: key)
            clearApplicationBlockers(on: key) { _, _ in false }
        }
        completeSettledDepartures()
        let retained = Set(required.values.flatMap { $0 })
        targetPins = targetPins.filter { retained.contains($0.key) || departureRecovery[$0.key.service]?.registrationID == $0.key.registration }
        targets = targets.filter { $0.value.service != nil }
        await notify()
        let waiting = replayWaiters.removeValue(forKey: intent.operationID) ?? []
        waiting.forEach { $0.resume() }
        return true
    }
    private func drainReplay() async {
        var attempted: Set<Attempt> = [], failed: [UUID: Failure] = [:], removalAttempted: Set<UUID> = []
        drain: while true {
            let token = await acquireProgress()
            var work: (RequestRevocationIntent, TargetKey, ShaderRequestService, UUID)?
            let remainingIntents = outstandingIntents
            for intent in remainingIntents {
                for key in required[intent.operationID] ?? [] {
                    let attempt = Attempt(intent: intent.operationID, target: key)
                    if !retired(key), applications[intent.operationID]?[key] == nil, !attempted.contains(attempt), failedApplications[attempt] == nil, preparingRecovery[key] == nil, pendingRecoveryOutcomes[key] == nil, let epoch = recoveryEpochs[key], let target = targets[key]?.service {
                        work = (intent, key, target, epoch); attempted.insert(attempt); break
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
            guard let (intent, key, target, epoch) = work else {
                let remaining = Set(envelope.revocations.map(\.operationID)).union(removals.keys)
                failed = failed.filter { remaining.contains($0.key) }
                // A successful target cannot erase another target's unresolved application.
                for id in remaining where failed[id] == nil { failed[id] = outstandingFailure(id) ?? failures[id] }
                finishReplay(failed); release(token); return
            }
            let hook = accepted?.owner.beforeReplay, appliedRevision = revision
            release(token)
            do {
                if let beforeReplayApplication { try await beforeReplayApplication(key.service) }
                try await hook?(intent)
                let admission = await acquireProgress()
                let attempt = Attempt(intent: intent.operationID, target: key)
                let eligible = targets[key]?.service === target && applicationIsCurrent(attempt, epoch: epoch)
                release(admission)
                guard eligible else { throw Self.unavailable("Target recovery evidence changed before cancellation application; retain its intent for the successor recovery pass.") }
                let proof = try await target.applyTrustedRevocation(intent, revision: appliedRevision)
                let commit = await acquireProgress()
                guard targets[key]?.service === target, applicationIsCurrent(attempt, epoch: epoch) else {
                    release(commit)
                    throw Self.unavailable("Target recovery evidence changed during cancellation application; retain its intent for the successor recovery pass.")
                }
                applicationEpochs[attempt] = epoch
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
                let commit = await acquireProgress()
                recoveryTargets.insert(key)
                if recoveryEpochs[key] == epoch || failedApplications[.init(intent: intent.operationID, target: key)] == nil {
                    blockApplication(.init(intent: intent.operationID, target: key), diagnostic: error.localizedDescription)
                }
                failed[intent.operationID] = await record(error, intent: intent)
                release(commit)
            }
        }
    }
    /// Diagnostics explain unresolved obligations; they are not the source of
    /// truth for whether cancellation or removal has actually completed.
    private func outstandingFailure(_ id: UUID) -> Failure? {
        guard let needed = required[id], !needed.isEmpty else { return nil }
        if let original = failures[id] { return original }
        let proofs = applications[id] ?? [:]
        let pending = needed.sorted { $0.service.uuidString < $1.service.uuidString }
        let detail = pending.compactMap { key -> String? in
            if proofs[key] == nil {
                let cause = failedApplications[.init(intent: id, target: key)]?.diagnostic ??
                    (preparingRecovery[key] != nil ? "Target local recovery is still preparing." :
                     pendingRecoveryOutcomes[key] != nil ? "Target local recovery is awaiting its trusted pass admission." : "Cancellation application is unverified.")
                return "Service " + key.service.uuidString + ": " + cause
            }
            return finalizedRemovals[id]?.contains(key) == true ? nil : "Service " + key.service.uuidString + ": trusted removal finalization remains pending."
        }.prefix(8).joined(separator: "\n")
        let unresolved = Self.unavailable("TV intent " + id.uuidString + " remains unresolved. " + detail)
        return Failure(unresolved, diagnosticID: id)
    }
    private func finishReplay(_ failed: [UUID: Failure]) {
        replayTask = nil
        let departures = departureReplay; departureReplay.removeAll()
        for (serviceID, waiting) in departures {
            let error = departureFailure(serviceID: serviceID)
            waiting.forEach { if let error { $0.resume(throwing: error) } else { $0.resume() } }
        }
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
