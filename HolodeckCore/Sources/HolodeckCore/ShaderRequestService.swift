#if os(macOS)
import Foundation
import Darwin

nonisolated enum RequestPaths {
    static func canonical(_ url: URL, remainingLinks: Int = 40) -> String {
        if let path = realpath(url.path, nil) { defer { free(path) }; return String(cString: path) }
        if remainingLinks > 0, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let destination = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : url.deletingLastPathComponent().appendingPathComponent(target)
            return canonical(destination.standardizedFileURL, remainingLinks: remainingLinks - 1)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.standardizedFileURL.path }
        return URL(fileURLWithPath: canonical(parent, remainingLinks: remainingLinks)).appendingPathComponent(url.lastPathComponent).path
    }
}

nonisolated struct DetachedCheckoutAcknowledgement: Codable, Sendable, Equatable {
    var requestID: UUID
    var directory: String
    var repository: String
    var checkoutID: String?
}

nonisolated public struct ShaderRequestConfiguration: Codable, Sendable, Equatable {
    public var repository: String
    public var codex: String
    public var python: String
    public var git: String
    public var shaderTool: String
    public var model: String
    public var reasoning: String
    public var checkoutID: String?
    var detachedOwner: DetachedCheckoutAcknowledgement?
    public var enabled: Bool
    private enum CodingKeys: String, CodingKey {
        case repository, codex, python, git, shaderTool, model, reasoning, checkoutID, detachedOwner, enabled
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repository = try values.decode(String.self, forKey: .repository)
        codex = try values.decode(String.self, forKey: .codex)
        python = try values.decode(String.self, forKey: .python)
        git = try values.decode(String.self, forKey: .git)
        shaderTool = try values.decode(String.self, forKey: .shaderTool)
        model = try values.decode(String.self, forKey: .model)
        reasoning = try values.decode(String.self, forKey: .reasoning)
        checkoutID = try values.decodeIfPresent(String.self, forKey: .checkoutID)
        detachedOwner = try values.decodeIfPresent(DetachedCheckoutAcknowledgement.self, forKey: .detachedOwner)
        enabled = try values.decode(Bool.self, forKey: .enabled)
    }
    /// Only preferences and their UserDefaults copy support these two legacy omissions.
    /// Captured requests, operation bindings and recovery evidence use strict Codable.
    public static func decodePreferences(_ bytes: Data) throws -> Self {
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return try JSONDecoder().decode(Self.self, from: bytes)
        }
        if object["shaderTool"] == nil { object["shaderTool"] = "" }
        if object["reasoning"] == nil { object["reasoning"] = "high" }
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
    public init(repository: String = "", codex: String = "/opt/homebrew/bin/codex", python: String = "/usr/bin/python3",
                git: String = "/usr/bin/git", shaderTool: String = "", model: String = "", reasoning: String = "high", enabled: Bool = false) {
        self.repository = repository; self.codex = codex; self.python = python; self.git = git
        self.shaderTool = shaderTool; self.model = model; self.reasoning = reasoning; self.enabled = enabled
    }
}

nonisolated struct RequestWorkerEvent: Decodable, Sendable {
    var event: String
    var recoveryRequired: Bool?
    var failureKind: String?
    var retryable: Bool?
    var stage: String?
    var message: String?
    var question: String?
    var options: [String]?
    var requiredPreviewShaderIDs: [String]?
    var checkoutID: String?
    var result: ShaderRequestResult?
    var failureError: Error? {
        guard event == "failure" else { return nil }
        let detail = message ?? "Shader worker failed"
        if recoveryRequired == true { return RequestWorkerTeardownError(cause: detail) }
        if failureKind == "supervision" || failureKind == "interrupted" {
            return RequestWorkerSupervisionError(message: detail, retryable: failureKind == "supervision" && retryable != false)
        }
        return ShaderRequestError.unavailable(detail)
    }
}

public enum ShaderCheckoutDetachTarget: Sendable {
    case request(UUID)
    case recovery(UUID)
    case selectedCheckout
}

public struct ShaderRequestRecoveryStatus: Sendable, Identifiable {
    public enum Kind: Sendable { case cleanup, reconciliation, persistence }
    public let id: UUID
    public let kind: Kind
    public let repository: String
    public let python: String
    public let git: String
    public let message: String
    public let isRunning: Bool
    public var requestID: UUID? = nil
    public var journal: URL? = nil
    public var checkout: ShaderRequestConfiguration? = nil
    public var disposition: ShaderRequestRecoveryDisposition? = nil
    public var isRetrying = false
    public var repairConfiguration: ShaderRequestConfiguration? = nil
    public var blocksCheckoutWork = true
}

public struct ShaderRequestPublicationStatus: Sendable {
    public let revision: String
    public let sequence: UInt64
    public let warnings: [ShaderPreviewWarning]
}

/// Local publication failures are separate from the TV request protocol.
public struct ShaderRequestPublicationFailure: LocalizedError, Sendable, Equatable {
    public let generation: UUID
    public let operationSequence: UInt64
    public let message: String
    public let recoveryRequired: Bool
    public var correlationID: UUID? = nil
    public var errorDescription: String? { message }
}

public struct ShaderRequestPublicationOperationStatus: Sendable, Equatable {
    public enum Phase: Sendable { case idle, preparing, failed }
    public let sequence: UInt64
    public let phase: Phase
    public let failure: ShaderRequestPublicationFailure?
    /// Set only when this operation successfully restores or installs this revision.
    public let revision: String?
    public var correlationID: UUID? = nil
}

public struct ShaderRequestPublicationEvent: Sendable {
    public let generation: UUID
    public let operation: ShaderRequestPublicationOperationStatus
    public let publication: ShaderRequestPublicationStatus?
    public let unresolvedFailure: ShaderRequestPublicationFailure?
}

public struct ShaderRepositorySelection: Sendable {
    public let configuration: ShaderRequestConfiguration
    public let publication: CatalogReloadResult
}

/// Local accepted setup; draft fields and blocked initialization are never preferences.
public struct ShaderRequestSetupSnapshot: Sendable, Equatable {
    public enum Phase: Sendable { case blockedInitialization, accepted, requiresVerification }
    public let revision: UInt64
    public let phase: Phase
    public let configuration: ShaderRequestConfiguration?
    public let blocked: Bool
}

public struct ShaderRequestLocalState: Sendable {
    public let jobs: [ShaderRequestStatus]
    public let recoveries: [ShaderRequestRecoveryStatus]
    public let pendingCleanup: Bool
    public let canDisableRequests: Bool
    public let setup: ShaderRequestSetupSnapshot
}

public actor ShaderRequestService {
    nonisolated private let hostOwners = RequestServiceOwners()
    nonisolated public func retainOwner() -> RequestServiceOwnerLease {
        let id = hostOwners.acquire()
        Task { [weak self] in await self?.hostOwnershipChanged() }
        return RequestServiceOwnerLease { [self] in
            hostOwners.release(id)
            Task { await self.hostOwnershipChanged() }
        }
    }
    private func hostOwnershipChanged() { emitUpdates(); kick() }
    private func pauseOwnerlessPublication() {
        if let request = pendingPublication {
            pendingPublication = nil
            retryPublicationForce = (retryPublicationForce ?? false) || request.force
            let error = ShaderRequestError.unavailable("Library preparation is paused until a local host reconnects.")
            for waiter in request.waiters { waiter.continuation.resume(throwing: error) }
        }
    }

    private struct DispatchState: Codable, Sendable, Equatable {
        let executionID: UUID
        var workerOperationID: UUID?
        var launched = false
        var retirementPending = false
        let priorStage: ShaderRequestStatus.Stage
    }
    private struct Record: Codable, Sendable, Equatable {
        var status: ShaderRequestStatus
        var configuration: ShaderRequestConfiguration
        var revoked = false
        var deliveryNonce: String?
        var cleanupPending: Bool?
        var cleanupFailure: String?
        var cleanupMessage: String?
        var interrupted: Bool?
        var executionID: UUID?
        var detached: Bool?
        var deletionPending: Bool?
        var deletionFailure: String?
        var dispatch: DispatchState?
    }
    private let directory: URL
    private let catalog: DirectoryCatalog
    private let workerScript: URL?
    private var recoveryRevision: UInt64 = 0
    private var recovery = RequestRecoveryStore() { didSet { recoveryRevision &+= 1 } }
    private struct ProposalInput: Equatable, Sendable {
        let id: UUID; let journal: String; let generation: UInt64; let configuration: ShaderRequestConfiguration
    }
    private struct MaintenanceProposal: Sendable { let input: ProposalInput; let configuration: ShaderRequestConfiguration? }
    private var maintenanceProposals: [UUID: MaintenanceProposal] = [:]
    private var proposalGenerations: [String: UInt64] = [:]
    private var proposalTask: Task<Void, Never>?
    private(set) var maintenanceProposalReadCount = 0
    private let readMaintenanceProposal: @Sendable (URL) throws -> RequestWorkerOperation?
    private let waitForWorker: @Sendable (RequestWorkerProcess) async throws -> Void
    private let reconcileWorker: @Sendable (URL) async throws -> Void
    private let metadataAdmission = RequestPersistence.MetadataAdmission()
    private let persistence: RequestPersistence
    private var persistenceRevision: UInt64 = 0
    private var resolvedPersistenceGeneration: UInt64 = 0
    private var pendingCommits = 0
    private var persistenceFault: RequestPersistence.Fault?
    private var validationBlocker: RequestPersistence.ValidationBlocker?
    private var resolvedValidationRevision: UInt64 = 0
    private struct MetadataIssue: LocalizedError, Sendable {
        let id = UUID()
        let file: String
        let reason: String
        var preferencesOnly = false
        var errorDescription: String? {
            "Request metadata is unreadable or unsupported at " + file + ": " + reason +
            " Retain this file and restore or repair it, then choose Retry Recovery. Checkout work stays disabled; the cached library remains available."
        }
    }
    private var metadataIssue: MetadataIssue?
    private var startupFinalizationFailure: String?
    private let beforeStartupFinalization: @Sendable () async throws -> Void
    // Inspection completion releases shared load waiters; only a fully decoded
    // baseline and an inspected fault marker authorize metadata mutation.
    private var acceptedMetadataAvailable = false
    private var storageFaultInspected = false
    private var metadataRecoveryAttempt: UUID?
    private var metadataRecoveryIssueID: UUID?
    private enum MetadataAuthority { @TaskLocal static var recovery: UUID? }
    @discardableResult private func admitMetadataMutation() throws -> RequestPersistence.MetadataAdmission.Permit {
        guard acceptedMetadataAvailable, storageFaultInspected,
              metadataIssue == nil || (metadataRecoveryAttempt != nil && MetadataAuthority.recovery == metadataRecoveryAttempt && metadataIssue?.id == metadataRecoveryIssueID) else {
            throw MetadataUnavailable(message: metadataIssue?.localizedDescription ?? "Request metadata inspection has not established an accepted baseline. Choose Retry Recovery.")
        }
        return try metadataAdmission.permit(recovery: MetadataAuthority.recovery)
    }
    private func inspectStorage() async throws {
        let root = directory
        do { try await persistence.perform { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } }
        catch { throw MetadataIssue(file: root.path, reason: error.localizedDescription) }
        if !storageFaultInspected {
            if let fault = try await persistence.loadFault() { publishStorageFault(fault) }
            storageFaultInspected = true; metadataAdmission.inspectedStorage()
        }
    }
    private var persistenceFailure: String? { persistenceFault?.localizedDescription ?? metadataIssue?.localizedDescription ?? validationBlocker?.message }
    private func publishMetadataIssue(_ error: Error, file: String, preferencesOnly: Bool = false) {
        var issue = error as? MetadataIssue ?? MetadataIssue(file: file, reason: RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 4096))
        issue.preferencesOnly = preferencesOnly
        metadataIssue = issue; metadataAdmission.block()
        if !acceptedMetadataAvailable { startupWasBlocked = true }
        activeProcess?.shutdown(); failPendingPublicationForRecovery(metadataIssue!.localizedDescription); emitUpdates()
    }
    private struct MetadataUnavailable: LocalizedError { let message: String; var errorDescription: String? { message } }
    private var settledExecutions: Set<UUID> = []
    private var pendingRetirements: [UUID: UUID] = [:]
    private var verifiedRetirements: Set<UUID> = []
    private var retirementTask: Task<Void, Never>?

    private var schedulingWakeupPending = false
    private var schedulingDeferred = false
    /// Caller drafts never enter accepted state while the writer is suspended.
    private struct StorageProposal {
        var records: [UUID: Record] = [:]
        var configuration: ShaderRequestConfiguration?
        var acknowledgements: [DetachedCheckoutAcknowledgement]?
        var files: [RequestPersistence.File] = []
    }
    private enum RecordCommand {
        case stage(ShaderRequestStatus.Stage, String)
        case cleanupPending(String), cleanupComplete, cleanupFailure(String?)
        case configuration(ShaderRequestConfiguration, ShaderRequestConfiguration)
        case detached, interrupted, revoked, ownedRecovery
        case launchBinding(UUID, UUID), launch(UUID, Bool)
        case clarification(ShaderClarification), result(ShaderRequestResult), deliveredHash(String)
        case metadataPause(UUID), finish(UUID, interrupted: Bool, settled: Bool), retired(UUID)
    }
    private typealias RecordReceipt = RequestPersistence.CommitTicket<Record?>
    private enum RecordApplication {
        case immediate(Result<Record?, Error>)
        case queued(RecordReceipt)
    }
    private struct RecordTransition {
        let id: UUID; let command: RecordCommand; let execution: UUID?; let receipt: RecordReceipt?
    }
    private var recordTransitions: [RecordTransition] = []
    private var recordTicketAllocations = 0
    /// Immediate facts return directly; only queued, awaited transitions need a ticket.
    @discardableResult private func transitionRecord(_ id: UUID, _ command: RecordCommand, execution: UUID? = nil, awaiting: Bool = false) -> RecordApplication {
        if storageCommit != nil {
            let receipt = awaiting ? RecordReceipt() : nil
            if receipt != nil { recordTicketAllocations += 1 }
            recordTransitions.append(RecordTransition(id: id, command: command, execution: execution, receipt: receipt))
            return receipt.map(RecordApplication.queued) ?? .immediate(.success(nil))
        }
        return .immediate(applyRecordTransition(RecordTransition(id: id, command: command, execution: execution, receipt: nil)))
    }
    private func appliedRecord(_ id: UUID, _ command: RecordCommand, execution: UUID? = nil) async throws -> Record? {
        switch transitionRecord(id, command, execution: execution, awaiting: true) {
        case .immediate(let result): return try result.get()
        case .queued(let receipt): return try await withCheckedThrowingContinuation { receipt.attach($0) }
        }
    }
    private func completeTransition(_ transition: RecordTransition, _ result: Result<Record?, Error>) -> Result<Record?, Error> {
        transition.receipt?.complete(result); return result
    }
    @discardableResult private func applyRecordTransition(_ transition: RecordTransition) -> Result<Record?, Error> {
        let id = transition.id
        guard var record = records[id], record.deletionPending != true,
              transition.execution == nil || record.executionID == transition.execution else {
            switch transition.command {
            case .finish(let operation, _, let settled):
                if records[id]?.executionID == nil || records[id]?.executionID == operation {
                    pendingRetirements[id] = operation
                    if settled { verifiedRetirements.insert(operation) }
                    scheduleRetirement(); scheduleWakeup()
                }
            case .retired(let operation):
                if pendingRetirements[id] == operation, records[id]?.executionID == nil || records[id]?.executionID == operation {
                    if recoveryID == id { recoveryID = nil }
                    scheduleWakeup()
                }
            default: break
            }
            return completeTransition(transition, .success(nil))
        }
        var finished = false
        switch transition.command {
        case .stage(let stage, let message):
            if !record.status.stage.terminal || stage.terminal { Self.setStatus(&record, stage: stage, message: message) }
        case .cleanupPending(let message): record.cleanupPending = true; record.cleanupMessage = message
        case .cleanupFailure(let message): record.cleanupFailure = message
        case .cleanupComplete:
            record.cleanupPending = false; record.cleanupFailure = nil
            if record.status.result == nil || (record.status.stage != .awaitingActivation && record.status.stage != .completed) {
                Self.setStatus(&record, stage: .failed, message: record.cleanupMessage ?? "Owned checkout cleanup completed; see the retained request diagnostic")
            }
        case .configuration(let previous, let corrected):
            guard record.configuration == previous || record.configuration == corrected else { return completeTransition(transition, .failure(RequestWorkerOwnershipError())) }
            record.configuration = corrected
        case .detached:
            let wasDetached = record.detached == true
            record.detached = true; record.interrupted = true; record.cleanupPending = false; record.cleanupFailure = nil
            if !wasDetached, !record.status.stage.terminal { Self.setStatus(&record, stage: .failed, message: "Checkout detached; unpublished files and evidence were retained") }
        case .interrupted: record.interrupted = true
        case .revoked: Self.markRevoked(&record, active: activeID == id)
        case .ownedRecovery:
            if record.detached != true {
                recoveryID = id
                let stage = record.status.stage
                if stage.terminal || stage == .awaitingActivation || stage == .awaitingClarification {
                    record.cleanupPending = true; record.cleanupMessage = "Cleaning interrupted owned work; pushed commits are retained"
                    if !stage.terminal && stage != .awaitingActivation { Self.setStatus(&record, stage: .failed, message: "Interrupted checkout cleanup is required") }
                } else if stage != .repairing { Self.setStatus(&record, stage: .repairing, message: "Recovering interrupted owned work") }
            }
        case .launchBinding(let operation, let worker):
            if record.dispatch?.executionID == operation { record.dispatch?.workerOperationID = worker }
        case .launch(let operation, let launched):
            if record.dispatch?.executionID == operation { record.dispatch?.launched = launched }
        case .clarification(let clarification):
            record.status.clarification = clarification
            if record.revoked {
                record.cleanupPending = true; record.cleanupMessage = "TV access was revoked; any pushed commit remains"
                Self.setStatus(&record, stage: .failed, message: "Discarding revoked unpublished work")
            } else if !record.status.stage.terminal { Self.setStatus(&record, stage: .awaitingClarification, message: "Waiting for a TV answer") }
        case .result(let result): record.status.result = result
        case .deliveredHash(let hash): record.status.result?.deliveredSourceHash = hash
        case .metadataPause(let operation):
            if record.dispatch?.executionID == operation, record.dispatch?.launched == true,
               !record.status.stage.terminal, ![.awaitingActivation, .awaitingClarification].contains(record.status.stage) {
                Self.setStatus(&record, stage: .repairing, message: "Waiting for metadata recovery; unpublished work was retained")
                recoveryID = id
            }
        case .finish(let operation, let interrupted, let settled):
            finished = true
            if record.dispatch?.executionID == operation {
                let retained = record.detached != true && (record.cleanupPending == true || (interrupted && !record.status.stage.terminal))
                if retained { recoveryID = id }
                if !(retained && record.dispatch?.launched == true) {
                    if record.dispatch?.launched == false, !record.status.stage.terminal, let prior = record.dispatch?.priorStage { record.status.stage = prior }
                    if settled || record.dispatch?.launched != true {
                        pendingRetirements[id] = operation; verifiedRetirements.insert(operation)
                        record.dispatch?.retirementPending = true
                    }
                }
            }
        case .retired(let operation):
            guard record.executionID == nil || record.executionID == operation else { return completeTransition(transition, .success(record)) }
            if record.dispatch?.executionID == operation { record.dispatch = nil }
            if recoveryID == id, record.status.stage != .repairing, record.cleanupPending != true { recoveryID = nil }
        }
        records[id] = record
        if finished { scheduleRetirement(); if !suspended { kick() } }
        return completeTransition(transition, .success(record))
    }
    private func scheduleRetirement() {
        guard !pendingRetirements.isEmpty, persistenceFailure == nil, retirementTask == nil else { return }
        retirementTask = Task { [self] in
            do { try await self.retirePendingWorkers() } catch { self.progressPersistenceFailed(error) }
            self.finishRetirementTask()
        }
    }
    private var storageCommit: UUID?
    private var storageWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let prepareCleanup: @Sendable () async -> Void
    private let removeRecordDirectory: @Sendable (URL) throws -> Void
    private var configuration = ShaderRequestConfiguration()
    private var records: [UUID: Record] = [:]
    private var observers: [UUID: AsyncStream<[ShaderRequestStatus]>.Continuation] = [:]
    private var localObservers: [UUID: AsyncStream<ShaderRequestLocalState>.Continuation] = [:]
    private var localSnapshots = 0, setupQueries = 0
    private var activeID: UUID?
    private var activeProcess: RequestWorkerProcess?
    private var workerTask: Task<Void, Never>?
    private var preparedID: UUID? { didSet { if preparedID == nil { preparedAttemptID = nil } } }
    private var preparedAttemptID: UUID?
    private struct Execution {
        let id = UUID()
        var interrupted = false
        // Verified history across attempts, independent of provisional dispatch launch state.
        var checkoutLaunched = false
        var processID: ObjectIdentifier?
    }
    private var execution: Execution?
    private var selectingRepository = false
    private var acceptingRepository = false
    private var maintenanceLease: UUID?
    private var detaching = false
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceBusy: Bool { maintenanceLease != nil || detaching }
    private struct ReconciliationResult: Sendable { var owner: UUID?; var acknowledgements: [DetachedCheckoutAcknowledgement] }
    private struct ReconciliationAttempt { let id = UUID(); let epoch: UInt64; let task: Task<ReconciliationResult, Error> }
    private var reconciliationTask: ReconciliationAttempt?
    private var fullReconciliationRequired = true
    private var dirtyJournals: Set<String> = []
    private var reconciliationEpoch: UInt64 = 0
    private var reconciled: Bool {
        get { !fullReconciliationRequired && dirtyJournals.isEmpty }
        set {
            reconciliationEpoch &+= 1
            fullReconciliationRequired = !newValue
            if newValue { dirtyJournals.removeAll() }
        }
    }
    private func invalidateJournal(_ key: String) {
        dirtyJournals.insert(key); reconciliationEpoch &+= 1
        invalidateMaintenanceProposal(key)
    }
    private var reconciliationKickID: UUID?
    private var reconciliationFailure: String?
    private var reconciliationJournal: URL?
    private var reconciliationConfiguration: ShaderRequestConfiguration?
    private struct ReconciliationError: LocalizedError {
        let journal: URL; let configuration: ShaderRequestConfiguration?; let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }
    private static let persistenceStatusID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let reconciliationStatusID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var latestPublication: ShaderRequestPublicationStatus?
    private var publicationSequence: UInt64 = 0
    private var publicationObservers: [UUID: AsyncStream<ShaderRequestPublicationEvent>.Continuation] = [:]
    private var publicationGeneration = UUID()
    private var unresolvedPublicationFailure: ShaderRequestPublicationFailure?
    private struct PublicationWaiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private struct PublicationRequest {
        var force: Bool
        var waiters: [PublicationWaiter]
        var ownsRetry = false
    }
    // Independent of caller continuations; nil means no recovery-triggered retry.
    private var retryPublicationForce: Bool?
    private var publicationOperation = ShaderRequestPublicationOperationStatus(sequence: 0, phase: .idle, failure: nil, revision: nil)
    private var pendingPublication: PublicationRequest?
    private var activePublication: PublicationRequest?
    private enum ScheduledWork { case execute(UUID), cleanup(UUID), publication }
    private var schedulingActive = false
    private let bundledShaderTool: String?
    private var initialized = false
    private var detachedOwners: [DetachedCheckoutAcknowledgement] = []
    private var suspended = false
    private var loaded = false
    private var loadingTask: Task<Void, Never>?
    private var initializationInput: ShaderRequestConfiguration?
    private var configurationAccepted = false
    private var startupWasBlocked = false
    private var requiresVerification = false
    private var lastSetupSnapshot: ShaderRequestSetupSnapshot?
    private(set) var acceptedMetadataLoadCount = 0
    private(set) var preferencesReadCount = 0
    private var activeRetryJournals: [String: UUID] = [:]
    private var recoveryID: UUID?
    nonisolated let runtimeID = UUID()
    private var hostRecoveryObservers: [UUID: @Sendable (ShaderRequestService, UInt64, Bool) async -> Void] = [:]
    private var hostRecoveryRevision: UInt64 = 0
    private var lastHostRecoveryRequirement: Bool?
    private var requiresHostRecoveryPin: Bool {
        persistenceFailure != nil || startupFinalizationFailure != nil || !recovery.entries.isEmpty || !pendingRetirements.isEmpty || retirementTask != nil
    }
    func observeHostRecovery(id: UUID, changed: @escaping @Sendable (ShaderRequestService, UInt64, Bool) async -> Void) {
        hostRecoveryObservers[id] = changed
        let required = requiresHostRecoveryPin, revision = hostRecoveryRevision
        Task { await changed(self, revision, required) }
    }
    private func publishHostRecoveryRequirement() {
        let required = requiresHostRecoveryPin
        guard required != lastHostRecoveryRequirement else { return }
        lastHostRecoveryRequirement = required; hostRecoveryRevision &+= 1
        let revision = hostRecoveryRevision
        for observer in hostRecoveryObservers.values { Task { await observer(self, revision, required) } }
    }
    struct AuthorityTransfer: Sendable {
        let id: UUID
        let predecessor: TrustedApprovalsCoordinator
        let registration: UUID
    }
    private weak var trustedAuthority: TrustedApprovalsCoordinator?
    private var authorityTransfer: UUID?
    func rememberTrustedAuthority(_ authority: TrustedApprovalsCoordinator) { trustedAuthority = authority }
    func prepareTrustedAuthority(id: UUID) async throws -> AuthorityTransfer? {
        guard let prior = revocationCoordinatorID, prior != id, let predecessor = trustedAuthority, predecessor.id != id else { return nil }
        guard authorityTransfer == nil else { throw ShaderRequestError.unavailable("A trusted authority handoff is pending; retry after it finishes.") }
        let ticket = UUID(); authorityTransfer = ticket; emitUpdates()
        do {
            try await predecessor.prepareDeparture(self, ticket: ticket)
            try Task.checkCancellation()
            return AuthorityTransfer(id: ticket, predecessor: predecessor, registration: revocationRegistration)
        } catch { await predecessor.cancelDeparture(self, ticket: ticket); authorityTransfer = nil; emitUpdates(); throw error }
    }
    func settleTrustedAuthorityDeparture() async throws {
        if let activeID, records[activeID]?.revoked == true, let workerTask { await workerTask.value }
        if let retirementTask { await retirementTask.value }
        guard persistenceFailure == nil, startupFinalizationFailure == nil, recovery.entries.isEmpty,
              pendingRetirements.isEmpty, durableRevocations.isEmpty,
              activeProcess == nil || activeID.map({ records[$0]?.revoked != true }) == true else {
            throw ShaderRequestError.unavailable("Previous TV cancellation or process settlement requires recovery before changing authority.")
        }
    }
    func finishTrustedAuthority(_ transfer: AuthorityTransfer, authority: TrustedApprovalsCoordinator) {
        guard authorityTransfer == transfer.id else { return }
        trustedAuthority = authority; authorityTransfer = nil; emitUpdates()
        Task { await transfer.predecessor.finishDeparture(self, ticket: transfer.id) }
    }
    func cancelTrustedAuthority(_ transfer: AuthorityTransfer) async {
        guard authorityTransfer == transfer.id else { return }
        await transfer.predecessor.cancelDeparture(self, ticket: transfer.id)
        authorityTransfer = nil; emitUpdates()
    }
    private var revocationReservations: [UUID: TrustedRevocationReservation] = [:]
    var trustedReservationCount: Int { revocationReservations.count }
    private var revocationInspection: TrustedRevocationInspection?
    private var revocationRegistration = UUID()
    private var revocationApplications: [UUID: TrustedRevocationApplication] = [:]
    private var pendingRevocations: [UUID: RequestRevocationIntent] = [:]
    private var durableRevocations: Set<UUID> = []
    private var revocationCoordinatorID: UUID?
    private var revocationRevision: UInt64 = 0
    private struct ControlScope: Sendable {
        let id = UUID()
        var users = 0
    }
    private var controlScopes: [String: ControlScope] = [:]
    private var revocationCoordinator: (@Sendable () async throws -> Void)?
    private var revocationInspectionPending = false
    private var revocationFailure: String?
    private var revocationFailures: [UUID: String] = [:]
    private var unknownRevocationBlocker: String? {
        if authorityTransfer != nil { return "TV authority handoff is pending; requests are fenced until cancellation settles." }
        if let revocationFailure { return "TV approval inspection requires recovery: " + revocationFailure }
        return revocationInspectionPending ? "TV approvals have not been inspected. TV requests are paused; choose Retry Recovery." : nil
    }
    private func revocationBlocker(for deviceID: String) -> String? {
        if let unknownRevocationBlocker { return unknownRevocationBlocker }
        guard let intent = pendingRevocations.values.first(where: { $0.deviceID == deviceID }) else { return nil }
        if let failure = revocationFailures[intent.operationID] { return "TV revocation recovery required for " + deviceID + ": " + failure }
        return "TV access revocation is pending for " + deviceID + "; request cancellation must be durably replayed. Choose Retry Recovery if it does not finish."
    }
    private var revocationBlocker: String? {
        if let unknownRevocationBlocker { return unknownRevocationBlocker }
        guard let device = pendingRevocations.values.map(\.deviceID).sorted().first else { return nil }
        return revocationBlocker(for: device)
    }
    private var revocationCheckoutBlocker: String? {
        records.values.first { record in
            guard record.detached != true, revocationBlocker(for: record.status.deviceID) != nil else { return false }
            return record.cleanupPending == true || record.dispatch?.launched == true ||
                (!record.status.stage.terminal && ![.queued, .awaitingActivation].contains(record.status.stage))
        }.map { "TV revocation must settle its owned checkout before starting other checkout work: " + $0.status.deviceID }
    }
    func installTrustedAuthority(_ transfer: AuthorityTransfer, id: UUID, intents: [RequestRevocationIntent], revision: TrustedRevocationRevision,
                                 coordinator: @escaping @Sendable () async throws -> Void) throws -> (UUID, TrustedRevocationInspection) {
        guard authorityTransfer == transfer.id, revocationRegistration == transfer.registration, durableRevocations.isEmpty else {
            throw ShaderRequestError.unavailable("The previous authority changed during handoff; retain its registration and retry recovery.")
        }
        // No suspension between changing registration and loading the validated snapshot.
        let registration = bindRevocationCoordinator(id: id, coordinator)
        return (registration, try loadTrustedRevocations(intents, revision: revision))
    }
    @discardableResult func registerRevocationCoordinator(id: UUID, _ coordinator: @escaping @Sendable () async throws -> Void) async -> UUID {
        bindRevocationCoordinator(id: id, coordinator)
    }
    private func bindRevocationCoordinator(id: UUID, _ coordinator: @escaping @Sendable () async throws -> Void) -> UUID {
        if revocationCoordinatorID == id { revocationCoordinator = coordinator; return revocationRegistration }
        revocationRegistration = UUID(); revocationApplications.removeAll(); revocationInspection = nil
        controlScopes.removeAll()
        revocationCoordinatorID = id; revocationRevision = 0
        revocationCoordinator = coordinator; revocationInspectionPending = true; emitUpdates()
        return revocationRegistration
    }
    private func acceptRevocationRevision(_ revision: TrustedRevocationRevision) throws {
        guard revision.coordinator == revocationCoordinatorID, revision.sequence >= revocationRevision else {
            throw ShaderRequestError.unavailable("The trusted TV revocation coordinator changed; retry recovery.")
        }
        revocationRevision = revision.sequence
    }
    @discardableResult func reserveRevocation(_ intent: RequestRevocationIntent, revision: TrustedRevocationRevision) throws -> TrustedRevocationReservation {
        try acceptRevocationRevision(revision)
        let receipt = TrustedRevocationReservation(serviceID: runtimeID, registrationID: revocationRegistration, intent: intent, authority: revision.coordinator)
        revocationReservations[intent.operationID] = receipt
        pendingRevocations[intent.operationID] = intent; emitUpdates()
        return receipt
    }
    func cancelRevocationReservation(_ receipt: TrustedRevocationReservation) {
        let id = receipt.intent.operationID
        guard receipt.serviceID == runtimeID, revocationReservations[id]?.token == receipt.token else { return }
        revocationReservations[id] = nil
        if !durableRevocations.contains(id), pendingRevocations[id] == receipt.intent { pendingRevocations[id] = nil }
        emitUpdates(); kick()
    }
    func cancelRevocationReservation(_ intent: RequestRevocationIntent, revision: TrustedRevocationRevision) {
        guard (try? acceptRevocationRevision(revision)) != nil else { return }
        if !durableRevocations.contains(intent.operationID), pendingRevocations[intent.operationID] == intent { pendingRevocations[intent.operationID] = nil }
        emitUpdates(); kick()
    }
    func commitTrustedRevocation(_ intent: RequestRevocationIntent, revision: TrustedRevocationRevision) throws {
        try acceptRevocationRevision(revision)
        pendingRevocations[intent.operationID] = intent; durableRevocations.insert(intent.operationID)
        revocationReservations[intent.operationID] = nil
        controlScopes[intent.deviceID] = nil
        if let activeID, records[activeID]?.status.deviceID == intent.deviceID {
            execution?.interrupted = true; activeProcess?.stop()
        }
        emitUpdates()
    }
    @discardableResult func loadTrustedRevocations(_ intents: [RequestRevocationIntent], revision: TrustedRevocationRevision) throws -> TrustedRevocationInspection {
        try acceptRevocationRevision(revision)
        let ids = Set(intents.map(\.operationID))
        // The coordinator holds its mutation lease: absent provisional reservations
        // cannot still publish. Missing durable ownership requires explicit recovery.
        pendingRevocations = pendingRevocations.filter { ids.contains($0.key) || durableRevocations.contains($0.key) }
        revocationReservations = revocationReservations.filter { ids.contains($0.key) }
        for intent in intents { try commitTrustedRevocation(intent, revision: revision) }
        if !durableRevocations.isSubset(of: ids) {
            throw ShaderRequestError.unavailable("Trusted TV storage omitted an unacknowledged durable revocation. Retain the approval evidence and retry recovery.")
        }
        let receipt = TrustedRevocationInspection(registrationID: revocationRegistration, revision: revision)
        revocationInspection = receipt
        revocationInspectionPending = false; revocationFailure = nil; emitUpdates()
        return receipt
    }
    @discardableResult func applyTrustedRevocation(_ intent: RequestRevocationIntent, revision: TrustedRevocationRevision) async throws -> TrustedRevocationApplication {
        guard revision.coordinator == revocationCoordinatorID,
              pendingRevocations[intent.operationID] == intent, durableRevocations.contains(intent.operationID) else {
            throw ShaderRequestError.unavailable("The TV revocation intent changed; retry recovery.")
        }
        let registration = revocationRegistration
        try await revoke(intent.deviceID)
        guard registration == revocationRegistration, revision.coordinator == revocationCoordinatorID else {
            throw ShaderRequestError.unavailable("The trusted TV authority changed during request cancellation. Retain the intent and retry recovery.")
        }
        let proof = TrustedRevocationApplication(serviceID: runtimeID, registrationID: registration, authority: revision.coordinator, intent: intent)
        revocationApplications[intent.operationID] = proof
        return proof
    }
    func validateTrustedRevocation(_ application: TrustedRevocationApplication) throws {
        guard application.serviceID == runtimeID, application.registrationID == revocationRegistration,
              application.authority == revocationCoordinatorID,
              revocationApplications[application.intent.operationID] == application,
              pendingRevocations[application.intent.operationID] == application.intent,
              durableRevocations.contains(application.intent.operationID) else {
            throw ShaderRequestError.unavailable("The TV revocation application no longer belongs to this service registration. Retain the intent and retry recovery.")
        }
    }
    func finalizeTrustedRevocation(_ application: TrustedRevocationApplication, removal: TrustedRevocationRemoval) throws {
        try validateTrustedRevocation(application)
        guard removal.authority == application.authority, removal.intent == application.intent,
              removal.applications[runtimeID] == application else { throw ShaderRequestError.invalidRequest }
        let id = application.intent.operationID
        pendingRevocations[id] = nil; durableRevocations.remove(id); revocationReservations[id] = nil
        revocationApplications[id] = nil; revocationFailures[id] = nil
        emitUpdates(); kick()
    }
    // Compatibility for internal direct callers; production removal is coordinated
    // once across every service application by the trusted authority.
    func acknowledgeTrustedRevocation(_ intent: RequestRevocationIntent, revision: TrustedRevocationRevision,
                                      persistRemoval: @escaping @Sendable () throws -> Void) async throws {
        try acceptRevocationRevision(revision)
        let application: TrustedRevocationApplication
        if let existing = revocationApplications[intent.operationID] { application = existing }
        else { application = try await applyTrustedRevocation(intent, revision: revision) }
        try validateTrustedRevocation(application)
        do { try await Task.detached { try persistRemoval() }.value }
        catch { revocationReplayFailed(error, intent: intent, revision: revision); throw error }
        try finalizeTrustedRevocation(application, removal: .init(authority: revision.coordinator, intent: intent, applications: [runtimeID: application]))
    }
    func revocationReplayFailed(_ error: Error, intent: RequestRevocationIntent? = nil, revision: TrustedRevocationRevision? = nil) {
        if let revision {
            if let intent {
                guard revision.coordinator == revocationCoordinatorID, pendingRevocations[intent.operationID] == intent else { return }
            } else if (try? acceptRevocationRevision(revision)) == nil { return }
            if intent == nil { revocationInspection = nil }
        }
        let detail = RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192)
        if let intent { revocationFailures[intent.operationID] = detail } else { revocationFailure = detail }
        emitUpdates(); kick()
    }
    func revocationReplaySucceeded(inspection: TrustedRevocationInspection) {
        guard inspection.registrationID == revocationRegistration,
              revocationInspection?.registrationID == inspection.registrationID,
              revocationInspection?.revision == inspection.revision,
              (try? acceptRevocationRevision(inspection.revision)) != nil else { return }
        revocationFailure = nil; revocationInspectionPending = false; emitUpdates(); kick()
    }
    // Compatibility for existing internal callers: only an actual inspection can clear this blocker.
    func revocationReplaySucceeded(revision: TrustedRevocationRevision) {
        guard let inspection = revocationInspection, inspection.revision == revision else { return }
        revocationReplaySucceeded(inspection: inspection)
    }
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory; self.workerScript = nil
        self.waitForWorker = { try await $0.waitForExit() }
        self.reconcileWorker = { try RequestWorkerProcess.reconcileOrphan(in: $0) }
        self.persistence = RequestPersistence(directory: directory, metadataAdmission: metadataAdmission)
        self.prepareCleanup = {}
        self.beforeStartupFinalization = {}
        self.removeRecordDirectory = { try FileManager.default.removeItem(at: $0) }
        self.readMaintenanceProposal = { try RequestWorkerOperation.read(in: $0) }
        self.bundledShaderTool = Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path
    }
    init(catalog: DirectoryCatalog, directory: URL, workerScript: URL,
         reconcileWorker: @escaping @Sendable (URL) async throws -> Void = { try RequestWorkerProcess.reconcileOrphan(in: $0) },
         waitForWorker: @escaping @Sendable (RequestWorkerProcess) async throws -> Void = { try await $0.waitForExit() },
         recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = { try RequestJournalWriter.write($0, to: $1) },
         prepareCleanup: @escaping @Sendable () async -> Void = {}, bundledShaderTool: String? = nil,
         beforePersistenceReplacement: @escaping @Sendable (URL) throws -> Void = { _ in },
         readMaintenanceProposal: @escaping @Sendable (URL) throws -> RequestWorkerOperation? = { try RequestWorkerOperation.read(in: $0) },
         removeRecordDirectory: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         beforeStartupFinalization: @escaping @Sendable () async throws -> Void = {}) {
        self.catalog = catalog; self.directory = directory; self.workerScript = workerScript
        self.reconcileWorker = reconcileWorker; self.waitForWorker = waitForWorker; self.persistence = RequestPersistence(directory: directory, metadataAdmission: metadataAdmission, recoveryWriter: recoveryWriter, beforeReplacement: beforePersistenceReplacement)
        self.prepareCleanup = prepareCleanup
        self.beforeStartupFinalization = beforeStartupFinalization
        self.removeRecordDirectory = removeRecordDirectory
        self.readMaintenanceProposal = readMaintenanceProposal
        self.bundledShaderTool = bundledShaderTool ?? Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path
    }
    private func workerProcess() -> RequestWorkerProcess { RequestWorkerProcess(script: workerScript) }
    private func waitForStorageChange(cancellable: Bool = true) async throws {
        if !cancellable {
            while storageCommit != nil {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in storageWaiters.append((UUID(), c)) }
            }
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            while storageCommit != nil {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) }
                    else { storageWaiters.append((id, c)) }
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancelStorageWaiter(id) } }
    }
    private func cancelStorageWaiter(_ id: UUID) {
        let cancelled = storageWaiters.filter { $0.0 == id }
        storageWaiters.removeAll { $0.0 == id }
        cancelled.forEach { $0.1.resume(throwing: CancellationError()) }
    }
    private func releaseStorageCommit() {
        storageCommit = nil
        let transitions = recordTransitions; recordTransitions.removeAll()
        for transition in transitions { applyRecordTransition(transition) }
        let waiting = storageWaiters; storageWaiters.removeAll()
        waiting.forEach { $0.1.resume() }
        emitUpdates(); if schedulingDeferred { scheduleWakeup() }
    }
    private func scheduleWakeup() {
        guard !schedulingWakeupPending else { return }
        schedulingWakeupPending = true
        // Scheduling must not inherit a caller mutation token or its actor context.
        Task.detached { [weak self] in await self?.performSchedulingWakeup() }
    }
    private func performSchedulingWakeup() { schedulingWakeupPending = false; schedulingDeferred = false; kick() }
    private func publishStorageFault(_ error: Error) {
        guard let fault = error as? RequestPersistence.Fault, fault.generation > resolvedPersistenceGeneration else { return }
        guard persistenceFault == nil || fault.generation >= persistenceFault!.generation else { return }
        persistenceFault = fault
        activeProcess?.shutdown()
        failPendingPublicationForRecovery(fault.localizedDescription)
        emitUpdates()
    }
    private func publishValidation(_ error: Error) {
        guard let validation = error as? RequestPersistence.ValidationError,
              let source = validation.revision, let origin = validation.operation,
              source > resolvedValidationRevision,
              validationBlocker == nil || source >= validationBlocker!.revision else { return }
        let detail = "Metadata validation recovery required for " + RequestRecoveryStore.Entry.bounded(origin, bytes: 1024) + ": " + RequestRecoveryStore.Entry.bounded(validation.localizedDescription, bytes: 8192)
        let value = RequestPersistence.ValidationBlocker(revision: source, message: detail)
        validationBlocker = value; persistenceRevision = max(persistenceRevision, source)
        activeProcess?.shutdown(); failPendingPublicationForRecovery(detail)
        persistence.recordValidation(value) { [weak self] error in Task { await self?.progressPersistenceFailed(error) } }
        emitUpdates()
    }
    private func writeFile(to file: URL, bytes: (isolated ShaderRequestService) throws -> Data) async throws {
        try await waitForStorageChange(cancellable: false)
        let permit = try admitMetadataMutation()
        let id = UUID(); storageCommit = id
        defer { releaseStorageCommit() }
        let data = try bytes(self)
        do {
            let writer = persistence
            try await Task.detached { try await writer.write(data, to: file, metadataPermit: permit) }.value
        }
        catch { publishStorageFault(error); throw error }
    }
    private func journalChange<T: Sendable>(_ operation: String, in journal: URL, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let permit = try admitMetadataMutation()
        defer { invalidateMaintenanceProposal(RequestPaths.canonical(journal)) }
        do { return try await persistence.journal(operation, files: [journal.appendingPathComponent(RequestWorkerOperation.filename), journal.appendingPathComponent("configuration.json")], metadataPermit: permit, body) }
        catch { publishStorageFault(error); throw error }
    }
    private func commitProposal(_ operation: String, cancellable: Bool = true, build: (isolated ShaderRequestService) throws -> StorageProposal) async throws {
        try await waitForStorageChange(cancellable: cancellable)
        try admitMetadataMutation()
        if let persistenceFailure { throw persistenceFault as Error? ?? MetadataUnavailable(message: persistenceFailure) }
        let id = UUID(); storageCommit = id
        defer { releaseStorageCommit() }
        try await persistence.begin(id, operation: operation, cancellable: cancellable)
        var proposal: StorageProposal
        do {
            // Revalidate after writer registration: independent facts can arrive
            // while that queue is busy, even though this caller owns the short gate.
            proposal = try build(self)
            proposal.records = proposal.records.filter { records[$0.key] != $0.value }
            if proposal.records.isEmpty, proposal.configuration == nil, proposal.acknowledgements == nil, proposal.files.isEmpty {
                persistence.abandon(id); return
            }
            var rows = records
            proposal.records.forEach { rows[$0.key] = $0.value }
            let acknowledgements = proposal.acknowledgements ?? detachedOwners
            var files = proposal.files
            if !proposal.records.isEmpty || proposal.acknowledgements != nil {
                files += metadataFiles(rows: rows, acknowledgements: acknowledgements, store: recovery)
            }
            try await commitFiles(files, transaction: id, cancellable: cancellable)
            await persistence.accept(id)
        } catch {
            if error is CancellationError { persistence.abandon(id); throw error }
            let original = error
            do { try await persistence.reject(id) } catch { publishStorageFault(error) }
            publishStorageFault(original); throw original
        }
        for (key, value) in proposal.records { records[key] = value }
        if let candidate = proposal.configuration { acceptRepository(candidate); if detaching { configuration.enabled = false } }
        if let acknowledgements = proposal.acknowledgements { detachedOwners = acknowledgements }
    }


    private func beginMaintenance(id: UUID = UUID(), forDetachment: Bool = false) throws -> UUID {
        guard maintenanceLease == nil, !detaching || forDetachment else {
            throw ShaderRequestError.unavailable("Wait for active checkout maintenance to finish.")
        }
        maintenanceLease = id
        emitUpdates()
        return id
    }
    private func checkMaintenance(_ lease: UUID) throws {
        try Task.checkCancellation()
        guard maintenanceLease == lease, !detaching else { throw CancellationError() }
    }
    private func endMaintenance(_ lease: UUID, schedule: Bool = true) {
        if maintenanceLease == lease {
            maintenanceLease = nil
            let waiters = maintenanceWaiters; maintenanceWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        emitUpdates()
        if schedule { kick() }
    }
    private func waitForMaintenance() async {
        while maintenanceLease != nil {
            await withCheckedContinuation { maintenanceWaiters.append($0) }
        }
    }

    public func start(configuration: ShaderRequestConfiguration) async throws {
        try await initialize(configuration: configuration)
        activateScheduling()
    }
    public func initialize(configuration incoming: ShaderRequestConfiguration) async throws {
        // Capture the first proposal before load suspends; concurrent callers cannot
        // replace it with defaults while authoritative preferences are unavailable.
        if initializationInput == nil { initializationInput = incoming }
        let wasInitialized = initialized
        try await load()
        guard !selectingRepository else { throw ShaderRequestError.unavailable("Wait for the selected folder to finish loading.") }
        if acceptedMetadataAvailable, metadataIssue == nil {
            if wasInitialized {
                do {
                    let saved = try await readAcceptedPreferences(reason: "Preferences conflict with the accepted setup. Restore its settings before retrying recovery.")
                    // With authoritative absence, initialize retains its existing
                    // in-session configuration-input contract. A saved or selected
                    // setup always takes precedence over this input.
                    if saved == nil { acceptRepository(incoming) }
                } catch { publishMetadataIssue(error, file: directory.appendingPathComponent("preferences.json").path, preferencesOnly: true) }
            } else if !configurationAccepted {
                configuration = initializationInput ?? incoming; configurationAccepted = true
            }
        }
        // The application may relocate its own bundled executable, never an unrelated tool.
        if let bundledShaderTool, incoming.shaderTool == bundledShaderTool, configurationAccepted { configuration.shaderTool = bundledShaderTool }
        let paths = Self.canonicalRepositories([configuration.repository] + detachedOwners.map(\.repository))
        if detachedOwners.contains(where: { Self.matchesDetachedCheckout(configuration, acknowledgement: $0, paths: paths) }) { configuration.enabled = false }
        if !configuration.enabled { cancelPublicationRequests() }
        initialized = true
        refreshSetupMessage()
        emitUpdates()
        await proposalTask?.value
    }
    private func refreshSetupMessage() {
        setupMessage = requiresVerification ? "Settings restored. Verify setup on the Mac to enable requests." :
            configuration.enabled ? "Ready for shader requests" : "Enable shader requests in Mac Settings."
    }
    private func readAcceptedPreferences(reason: String) async throws -> ShaderRequestConfiguration? {
        let preferences = directory.appendingPathComponent("preferences.json"), tool = bundledShaderTool
        while true {
            let accepted = configuration
            preferencesReadCount += 1
            let saved = try await persistence.perform { try Self.readPreferences(at: preferences) }
            // Initialization may race an independently accepted selection. Validate
            // against one current configuration rather than mixing two revisions.
            if configuration != accepted { continue }
            if let saved, !Self.preferencesMatch(saved, accepted: accepted, bundledTool: tool) {
                throw MetadataIssue(file: preferences.path, reason: reason, preferencesOnly: true)
            }
            return saved
        }
    }
    nonisolated private static func preferencesMatch(_ saved: ShaderRequestConfiguration, accepted: ShaderRequestConfiguration, bundledTool: String?) -> Bool {
        var candidate = saved, current = accepted
        candidate.repository = RequestPaths.canonical(URL(fileURLWithPath: candidate.repository))
        current.repository = RequestPaths.canonical(URL(fileURLWithPath: current.repository))
        if let bundledTool, current.shaderTool == bundledTool, candidate.shaderTool.isEmpty || trustedBundledTool(candidate.shaderTool) { candidate.shaderTool = bundledTool }
        return candidate == current
    }
    nonisolated private static func trustedBundledTool(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/Tools/holodeck-shader-tool")
    }
    public func setupSnapshot() -> ShaderRequestSetupSnapshot { setupQueries += 1; return acceptedSetupSnapshot() }
    private func acceptedSetupSnapshot() -> ShaderRequestSetupSnapshot {
        let phase: ShaderRequestSetupSnapshot.Phase = !acceptedMetadataAvailable || !configurationAccepted ? .blockedInitialization : requiresVerification ? .requiresVerification : .accepted
        let accepted = configurationAccepted ? configuration : nil
        let blocked = persistenceFailure != nil || startupFinalizationFailure != nil
        if let old = lastSetupSnapshot, old.phase == phase, old.configuration == accepted, old.blocked == blocked { return old }
        let value = ShaderRequestSetupSnapshot(revision: (lastSetupSnapshot?.revision ?? 0) &+ 1, phase: phase, configuration: accepted, blocked: blocked)
        lastSetupSnapshot = value; return value
    }
    public func activateScheduling() { schedulingActive = true; kick() }
    private func load() async throws {
        guard !loaded else { return }
        let shared: Task<Void, Never>
        if let loadingTask { shared = loadingTask }
        else {
            let task = Task { await self.performInitialLoad() }
            loadingTask = task; shared = task
        }
        // Cancelling one caller releases that waiter without cancelling the shared
        // metadata inspection or a different caller's exact-journal reconciliation.
        let ticket = RequestPersistence.CommitTicket<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                ticket.attach(c)
                Task { await shared.value; ticket.complete(.success(())) }
            }
        } onCancel: { ticket.cancel() }
    }
    private func performInitialLoad() async {
        defer { loaded = true; loadingTask = nil; emitUpdates() }
        do {
            try await inspectStorage()
            try await reloadAcceptedMetadata()
        } catch {
            if error is MetadataIssue { publishMetadataIssue(error, file: directory.path) }
            else { publishStorageFault(error) }
            return
        }
        guard persistenceFailure == nil else { return }
        do {
            try await beforeStartupFinalization()
            try await persist()
            try await retirePendingWorkers()
            for id in records.keys where records[id]?.deletionPending == true { await finishDeletion(id) }
        } catch {
            // Retirement owns its journal-specific recovery. An operational failure
            // after decoding must never be reported as unreadable shared metadata.
            progressPersistenceFailed(error)
            if !Self.isMetadataBlocker(error), reconciliationFailure == nil {
                startupFinalizationFailure = "Request startup finalization failed: " + RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 8192) + ". Choose Retry Recovery."
                emitUpdates()
            }
        }
    }
    nonisolated private static func readPreferences(at file: URL) throws -> ShaderRequestConfiguration? {
        guard RequestProcessIdentity.evidenceExists(file) else { return nil }
        do {
            return try ShaderRequestConfiguration.decodePreferences(
                BoundedCatalogReader(root: file.deletingLastPathComponent()).read(file.lastPathComponent, limit: CatalogLimits.headBytes).bytes)
        } catch { throw MetadataIssue(file: file.path, reason: RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 4096)) }
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    public func artifacts(for id: UUID) -> URL { folder(id) }
    public func configurationValue() -> ShaderRequestConfiguration {
        return configuration
    }
    var hasPendingStorageChange: Bool { storageCommit != nil }
    var hasActiveCheckoutWork: Bool { activeID != nil || workerTask != nil || maintenanceBusy }
    var isSuspended: Bool { suspended }
    var pendingRecordTransitionCount: Int { recordTransitions.count }
    func persistenceStatistics() async -> [String: Int] {
        var statistics = await persistence.statistics(); statistics["recordTickets"] = recordTicketAllocations
        statistics["localSnapshots"] = localSnapshots; statistics["setupQueries"] = setupQueries
        statistics["controlScopes"] = controlScopes.count
        return statistics
    }
    private func requireRepositorySelection() throws {
        if let startupFinalizationFailure { throw ShaderRequestError.unavailable(startupFinalizationFailure) }
        if let revocationCheckoutBlocker { throw ShaderRequestError.unavailable(revocationCheckoutBlocker) }
        guard !configuration.enabled else { throw ShaderRequestError.unavailable("Disable shader requests before selecting another checkout.") }
        guard activeID == nil, !maintenanceBusy, workerTask == nil else { throw ShaderRequestError.unavailable("Wait for active library preparation or checkout work before selecting another folder.") }
        guard recovery.entries.isEmpty, reconciliationFailure == nil else { throw ShaderRequestError.unavailable(recoveryBlocker ?? "Retry checkout recovery before selecting another folder.") }
        guard !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true }) else {
            throw ShaderRequestError.unavailable("Finish or cancel queued requests before selecting another folder.")
        }
    }
    private func selectedConfiguration(_ repository: URL) -> ShaderRequestConfiguration {
        var selected = configuration
        selected.repository = RequestPaths.canonical(repository)
        if selected.repository != RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) { selected.checkoutID = nil }
        return selected
    }
    private func retireMaintenanceOperations(replacing accepted: ShaderRequestConfiguration) async throws {
        guard !Self.samePublicationCheckout(configuration, accepted) else { return }
        for name in ["setup", "publication"] {
            let journal = directory.appendingPathComponent(name)
            var target: ShaderRequestConfiguration?
            do {
                if let saved = try Self.savedConfiguration(in: journal), Self.samePublicationCheckout(saved, configuration) {
                    target = saved
                    try await journalChange("retire worker operation", in: journal) { try RequestWorkerOperation.retire(in: journal) }
                }
            } catch { await holdForRecovery(journal: journal, configuration: target, error: error); throw error }
        }
    }
    private func acceptRepository(_ accepted: ShaderRequestConfiguration) {
        configurationAccepted = true
        if Self.samePublicationCheckout(configuration, accepted) { configuration = accepted; return }
        cancelPublicationRequests()
        configuration = accepted
        publicationGeneration = UUID(); latestPublication = nil; unresolvedPublicationFailure = nil
        _ = publicationState(.idle)
    }
    @discardableResult public func selectRepository(_ repository: URL) async throws -> ShaderRequestConfiguration {
        try await load()
        if RequestPaths.canonical(repository) == RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) { return configuration }
        try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        let candidate = selectedConfiguration(repository)
        try await retireMaintenanceOperations(replacing: candidate)
        try await commitProposal("select repository") { service in
            try service.checkMaintenance(lease)
            let accepted = service.selectedConfiguration(repository)
            return StorageProposal(configuration: accepted, files: [.init(url: service.directory.appendingPathComponent("preferences.json"), value: accepted)])
        }
        return configuration
    }
    /// Preparation owns the maintenance lease, never the metadata commit gate.
    public func reloadRepository(_ repository: URL) async throws -> ShaderRepositorySelection {
        try await load(); try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); selectingRepository = true
        defer { acceptingRepository = false; selectingRepository = false; endMaintenance(lease) }
        let accepted = selectedConfiguration(repository)
        let prepared = try await catalog.prepare(from: repository)
        do {
            try checkMaintenance(lease)
            try await retireMaintenanceOperations(replacing: accepted)
            try checkMaintenance(lease)
            acceptingRepository = true
            let publication = try await catalog.install(prepared.id)
            do {
                try await commitProposal("reload repository", cancellable: false) { service in
                    guard service.maintenanceLease == lease else { throw RequestWorkerOwnershipError() }
                    return StorageProposal(configuration: accepted, files: [.init(url: service.directory.appendingPathComponent("preferences.json"), value: accepted)])
                }
            } catch { published(publication); throw error }
            published(publication)
            return ShaderRepositorySelection(configuration: configuration, publication: publication)
        } catch { await catalog.discard(prepared.id); throw error }
    }
    public func hasPendingCleanup() -> Bool { records.values.contains { $0.cleanupPending == true } }
    private func isActiveRetry(_ key: String) -> Bool {
        activeRetryJournals[key] == execution?.id && execution?.interrupted == false
    }
    private func refreshReconciliationFailure() {
        if let entry = recovery.entries.values.sorted(by: { $0.journal < $1.journal }).first(where: { !isActiveRetry($0.journal) }) {
            reconciliationFailure = entry.message; reconciliationJournal = URL(fileURLWithPath: entry.journal)
            reconciliationConfiguration = entry.configuration
        } else { reconciliationFailure = nil; reconciliationJournal = nil; reconciliationConfiguration = nil }
    }
    private var recoveryBlocker: String? { checkoutRecoveryBlocker(includeRevokedCleanup: true) }
    private var requestAcceptanceBlocker: String? { checkoutRecoveryBlocker(includeRevokedCleanup: false) }
    private func checkoutRecoveryBlocker(includeRevokedCleanup: Bool) -> String? {
        if let startupFinalizationFailure { return startupFinalizationFailure }
        if let persistenceFailure { return "Mac persistence recovery required: " + persistenceFailure }
        if let entry = recovery.entries.values.sorted(by: { $0.journal < $1.journal }).first(where: { !isActiveRetry($0.journal) }) { return "Mac checkout recovery required: " + entry.message }
        if let reconciliationFailure { return "Mac checkout recovery required: " + reconciliationFailure }
        if let record = records.values.first(where: { $0.cleanupPending == true && (includeRevokedCleanup || !$0.revoked || $0.cleanupFailure != nil) }) {
            return "Mac checkout recovery required: " + (record.cleanupFailure ?? record.cleanupMessage ?? "Checkout cleanup is pending.")
        }
        return nil
    }
    public func publicationStatus() async -> ShaderRequestPublicationStatus? {
        let revision = await catalog.publicationRevisionValue()
        guard let latestPublication, latestPublication.revision == revision else { return nil }
        return latestPublication
    }
    public func isCurrentPublication(_ status: ShaderRequestPublicationStatus, generation: UUID) async -> Bool {
        let revision = await catalog.publicationRevisionValue()
        return publicationGeneration == generation && latestPublication?.sequence == status.sequence &&
            latestPublication?.revision == status.revision && revision == status.revision
    }
    public func publicationOperationStatus() -> ShaderRequestPublicationOperationStatus { publicationOperation }
    public func publicationUpdates() -> AsyncStream<ShaderRequestPublicationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            publicationObservers[id] = continuation; continuation.yield(publicationEvent())
            continuation.onTermination = { [weak self] _ in Task { await self?.removePublicationObserver(id) } }
        }
    }
    private func removePublicationObserver(_ id: UUID) { publicationObservers[id] = nil }
    private func publicationEvent() -> ShaderRequestPublicationEvent {
        .init(generation: publicationGeneration, operation: publicationOperation, publication: latestPublication, unresolvedFailure: unresolvedPublicationFailure)
    }
    private func emitPublication() { for observer in publicationObservers.values { observer.yield(publicationEvent()) } }
    private func resolvePublicationFailure() { unresolvedPublicationFailure = nil; _ = publicationState(.idle) }
    private func publicationState(_ phase: ShaderRequestPublicationOperationStatus.Phase, message: String? = nil,
                                  recoveryRequired: Bool = false, revision: String? = nil,
                                  correlationID: UUID? = nil) -> ShaderRequestPublicationFailure? {
        let sequence = publicationOperation.sequence &+ 1
        let correlationID = correlationID ?? execution?.id
        let failure = message.map { ShaderRequestPublicationFailure(generation: publicationGeneration, operationSequence: sequence,
            message: $0, recoveryRequired: recoveryRequired, correlationID: correlationID) }
        if let failure { unresolvedPublicationFailure = failure }
        if revision != nil { unresolvedPublicationFailure = nil }
        publicationOperation = .init(sequence: sequence, phase: phase, failure: failure, revision: revision, correlationID: correlationID)
        emitPublication()
        return failure
    }
    private func failPendingPublicationForRecovery(_ message: String) {
        guard !suspended || persistenceFailure != nil, let request = pendingPublication else { return }
        pendingPublication = nil
        retryPublicationForce = (retryPublicationForce ?? false) || request.force
        let failure = publicationState(.failed, message: "Library preparation needs checkout recovery: " + message,
                                       recoveryRequired: true)!
        for waiter in request.waiters { waiter.continuation.resume(throwing: failure) }
    }
    private func cancelPublicationRequests() {
        retryPublicationForce = nil
        for waiter in pendingPublication?.waiters ?? [] { waiter.continuation.resume(throwing: CancellationError()) }
        pendingPublication = nil
        for waiter in activePublication?.waiters ?? [] { waiter.continuation.resume(throwing: CancellationError()) }
        if activePublication != nil {
            activePublication?.waiters = []; activePublication?.ownsRetry = false
            execution?.interrupted = true; activeProcess?.stop()
        } else { _ = publicationState(.idle) }
    }
    public func cancelPublication() { cancelPublicationRequests() }
    var pendingPublicationWaiterCount: Int { pendingPublication?.waiters.count ?? 0 }
    private func published(_ publication: CatalogReloadResult) {
        publicationSequence &+= 1
        latestPublication = ShaderRequestPublicationStatus(revision: publication.catalog.publicationRevision,
            sequence: publicationSequence, warnings: publication.previewWarnings)
        unresolvedPublicationFailure = nil
        emitPublication()
    }
    public func recoveryStatuses() -> [ShaderRequestRecoveryStatus] {
        var statuses = records.values.filter { $0.cleanupPending == true }.map {
            ShaderRequestRecoveryStatus(id: $0.status.id, kind: .cleanup, repository: $0.configuration.repository,
                python: $0.configuration.python, git: $0.configuration.git,
                message: $0.cleanupFailure ?? $0.cleanupMessage ?? "Checkout cleanup is pending",
                isRunning: activeID == $0.status.id)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        for entry in recovery.entries.values.sorted(by: { $0.journal < $1.journal }) {
            statuses.append(ShaderRequestRecoveryStatus(id: entry.id, kind: .reconciliation,
                repository: entry.configuration?.repository ?? "", python: entry.configuration?.python ?? "", git: entry.configuration?.git ?? "",
                message: entry.message, isRunning: reconciliationTask != nil || maintenanceBusy || activeID != nil, requestID: entry.requestID,
                journal: URL(fileURLWithPath: entry.journal), checkout: entry.configuration, disposition: entry.disposition, isRetrying: isActiveRetry(entry.journal), repairConfiguration: proposedMaintenanceConfiguration(entry)))
        }
        if recovery.entries.isEmpty, let reconciliationFailure {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.reconciliationStatusID, kind: .reconciliation,
                repository: reconciliationConfiguration?.repository ?? "", python: reconciliationConfiguration?.python ?? "", git: reconciliationConfiguration?.git ?? "",
                message: reconciliationFailure, isRunning: reconciliationTask != nil,
                requestID: records.keys.first { folder($0) == reconciliationJournal }, journal: reconciliationJournal, checkout: reconciliationConfiguration))
        }
        if let startupFinalizationFailure {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.startupStatusID, kind: .persistence,
                repository: "", python: "", git: "", message: startupFinalizationFailure,
                isRunning: maintenanceBusy, journal: directory))
        }
        if let persistenceFailure {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.persistenceStatusID, kind: .persistence,
                repository: "", python: "", git: "", message: persistenceFailure,
                isRunning: maintenanceBusy || activeID != nil, journal: directory))
        }
        for record in records.values where record.deletionPending == true && record.deletionFailure != nil && persistenceFailure == nil {
            statuses.append(ShaderRequestRecoveryStatus(id: record.status.id, kind: .persistence,
                repository: "", python: "", git: "", message: "Record deletion is pending: " + (record.deletionFailure ?? ""),
                isRunning: maintenanceBusy, journal: folder(record.status.id)))
        }
        if let revocationBlocker {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.revocationStatusID, kind: .persistence, repository: "", python: "", git: "", message: revocationBlocker, isRunning: maintenanceBusy, journal: directory, blocksCheckoutWork: revocationCheckoutBlocker != nil))
        }
        return statuses
    }
    private static let startupStatusID = UUID(uuidString: "B61AC7DF-7CEB-44D2-869B-D0FE952F469B")!
    private static let revocationStatusID = UUID(uuidString: "E6DD4EA0-9EB5-4B79-A118-8CE5715BC2B3")!

    private func reconcileWorkers() async throws {
        try admitMetadataMutation()
        guard !reconciled else { return }
        let legacyDetachKeys = recovery.entries.filter { $0.value.disposition == .detach && $0.value.archiveID == nil }.map(\.key)
        for key in legacyDetachKeys { recovery.entries[key]?.archiveID = UUID() }
        // A prior failed write may have left a new archive ID only in memory.
        if recovery.entries.values.contains(where: { $0.disposition == .detach }) { try await persistRecovery() }
        if let entry = recovery.entries.values.first(where: { $0.configurationRepair != nil || $0.maintenanceRepair != nil }) {
            throw RequestWorkerEvidenceError(cause: "A saved cleanup configuration repair must be completed with Retry Recovery: " + entry.journal)
        }
        if reconciliationTask == nil {
            let all = records.values.map { ($0.status.id, $0.configuration, folder($0.status.id), $0.detached == true) }
            let known = all.filter { !$0.3 }
            let retained = recovery.entries
            let legacyRecords = recovery.legacyMigrationComplete ? [] : all.filter { item in
                item.3 && !detachedOwners.contains { $0.requestID == item.0 }
            }
            var folders = Set(known.map { $0.2 })
            folders.formUnion([directory.appendingPathComponent("setup"), directory.appendingPathComponent("publication")])
            folders.formUnion(retained.keys.map { URL(fileURLWithPath: $0) })
            if let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for child in children where UUID(uuidString: child.lastPathComponent) != nil {
                    if Self.hasProcessEvidence(child) { folders.insert(child) }
                }
            }
            let reconcile = reconcileWorker
            reconciliationTask = ReconciliationAttempt(epoch: reconciliationEpoch, task: Task.detached {
                for folder in folders.sorted(by: { $0.path < $1.path }) {
                    do { try await reconcile(folder) }
                    catch {
                        let key = RequestPaths.canonical(folder)
                        if retained[key]?.disposition == .detach, !(error is RequestWorkerTeardownError), !(error is RequestWorkerOwnershipError), !(error is CancellationError) { continue }
                        let target = all.first { RequestPaths.canonical($0.2) == key }?.1 ?? retained[key]?.configuration
                            ?? (try? Self.savedConfiguration(in: folder))
                        throw ReconciliationError(journal: folder, configuration: target, underlying: error)
                    }
                }
                var result = ReconciliationResult(owner: nil, acknowledgements: [])
                // Migration is retryable and never marks completion after an unreadable proof.
                for (id, configuration, job, _) in legacyRecords {
                    do {
                        if let owner = try Self.ownerMarker(configuration), owner.id == id, owner.directory == RequestPaths.canonical(job) {
                            result.acknowledgements.append(Self.acknowledgement(id: id, job: job, configuration: configuration))
                        }
                    } catch { throw ReconciliationError(journal: job, configuration: configuration, underlying: error) }
                }
                var inspected: Set<String> = []
                let paths = Self.canonicalRepositories(known.map { $0.1.repository })
                for (_, configuration, job, _) in known {
                    let key = RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) + "\0" + configuration.git
                    guard inspected.insert(key).inserted, let gitdir = try? Self.gitDirectory(configuration) else { continue }
                    let owner: OwnerMarker?
                    do { owner = try Self.readOwner(in: gitdir) }
                    catch { throw ReconciliationError(journal: job, configuration: configuration, underlying: error) }
                    guard let owner else { continue }
                    if let match = known.first(where: {
                        $0.0 == owner.id && owner.directory == RequestPaths.canonical($0.2) &&
                        Self.samePublicationCheckout($0.1, configuration, paths: paths)
                    }) { result.owner = result.owner ?? match.0 }
                    else if !result.acknowledgements.contains(where: { $0.requestID == owner.id }) {
                        throw ReconciliationError(journal: job, configuration: configuration, underlying:
                            ShaderRequestError.unavailable("Checkout ownership does not match its original path. Restore the original checkout or detach it and select a fresh clean checkout."))
                    }
                }
                return result
            })
        }
        guard let attempt = reconciliationTask else { return }
        do {
            let result = try await attempt.task.value
            try await waitForStorageChange(cancellable: false)
            guard reconciliationTask?.id == attempt.id else { return }
            guard !detaching else { reconciliationTask = nil; throw CancellationError() }
            guard reconciliationEpoch == attempt.epoch else {
                reconciliationTask = nil
                try await reconcileWorkers(); return
            }
            for acknowledgement in result.acknowledgements {
                detachedOwners.removeAll { $0.requestID == acknowledgement.requestID }; detachedOwners.append(acknowledgement)
                if Self.matchesDetachedCheckout(configuration, acknowledgement: acknowledgement) {
                    try await writeFile(to: directory.appendingPathComponent("preferences.json")) { service in
                        if Self.matchesDetachedCheckout(service.configuration, acknowledgement: acknowledgement) { service.configuration.enabled = false }
                        return try JSONEncoder().encode(service.configuration)
                    }
                }
            }
            // Finalization is idempotent; entries remain durable until record/ack writes finish.
            for entry in recovery.entries.values where entry.disposition == .detach { try await finalizeDetachment(entry) }
            for entry in recovery.entries.values {
                if let rollback = entry.preferencesRollback {
                    var applied = false
                    try await writeFile(to: directory.appendingPathComponent("preferences.json")) { service in
                        guard service.recovery.entries[entry.journal]?.preferencesRollback == rollback else { return try JSONEncoder().encode(service.configuration) }
                        applied = true
                        return try JSONEncoder().encode(rollback)
                    }
                    if applied { configuration = rollback; if detaching { configuration.enabled = false } }
                }
                guard let id = entry.requestID, records[id]?.detached != true else { continue }
                switch entry.disposition {
                case .resume:
                    if records[id]?.cleanupPending != true, records[id]?.status.stage != .awaitingClarification,
                       records[id]?.status.stage != .awaitingActivation, records[id]?.status.stage.terminal == false {
                        recoveryID = id; try await update(id, stage: .repairing, message: "Resuming preserved work after process recovery")
                    }
                case .cleanup: transitionRecord(id, .cleanupFailure(nil))
                case .retainResult, .detach: break
                }
            }
            if let owner = result.owner { _ = try await appliedRecord(owner, .ownedRecovery) }
            recovery.legacyMigrationComplete = true
            try await persist()
            guard reconciliationTask?.id == attempt.id, reconciliationEpoch == attempt.epoch, !detaching else { return }
            recovery.entries.removeAll(); try await persist()
            guard reconciliationTask?.id == attempt.id, reconciliationEpoch == attempt.epoch, !detaching else { return }
            reconciled = true; reconciliationTask = nil; refreshReconciliationFailure()
            emitUpdates()
        } catch {
            if detaching, error is CancellationError { throw error }
            if reconciliationTask?.id == attempt.id {
                let detail = error as? ReconciliationError
                reconciliationTask = nil
                if let detail {
                    await holdForRecovery(journal: detail.journal, configuration: detail.configuration, error: detail.underlying)
                } else {
                    await holdForRecovery(journal: reconciliationJournal ?? directory.appendingPathComponent("setup"),
                        configuration: reconciliationConfiguration, error: error)
                }
                failPendingPublicationForRecovery(reconciliationFailure ?? error.localizedDescription)
            }
            throw error
        }
    }

    nonisolated private static func hasProcessEvidence(_ journal: URL) -> Bool {
        ["process.json", "children.json", "supervision.json"].contains { RequestProcessIdentity.evidenceExists(journal.appendingPathComponent($0)) }
    }
    private func persistRecovery(retainingEvidence: Bool = false) async throws {
        try await commitFiles([.init(url: directory.appendingPathComponent("recovery.json"), recovery: recovery, generation: recoveryRevision)], retainingEvidence: retainingEvidence)
    }
    @discardableResult private func commitFiles(_ files: [RequestPersistence.File], retainingEvidence: Bool = false, transaction: UUID? = nil, operation: String = "request metadata", cancellable: Bool = true, recoveryToken: RequestPersistence.RecoveryToken? = nil, metadataPermit: RequestPersistence.MetadataAdmission.Permit? = nil) async throws -> UInt64 {
        let permit = try metadataPermit ?? admitMetadataMutation()
        persistenceRevision &+= 1
        let snapshot = RequestPersistence.Snapshot(revision: persistenceRevision, files: files, operation: operation, metadataPermit: permit)
        pendingCommits += 1
        defer { pendingCommits -= 1; if pendingCommits == 0, schedulingDeferred { scheduleWakeup() } }
        do {
            let submission = persistence.submit(snapshot, retainingEvidence: retainingEvidence, transaction: transaction, recovery: recoveryToken, cancellable: transaction != nil && cancellable)
            let receipt = try await submission.value(cancellable: transaction != nil && cancellable)
            applyPersistenceReceipt(receipt)
            return receipt.revision
        }
        catch {
            publishStorageFault(error)
            if transaction == nil { publishValidation(error) }
            throw error
        }
    }
    private struct AcceptedMetadata: Sendable {
        let records: [Record]
        let acknowledgements: [DetachedCheckoutAcknowledgement]
        let recovery: RequestRecoveryStore
        let configuration: ShaderRequestConfiguration?
        let active: UUID?
        let operations: [UUID: RequestWorkerOperation]
        let launchEvidence: Set<UUID>
        let validation: RequestPersistence.ValidationBlocker?
        let paths: [String: String]
    }
    private func reloadAcceptedMetadata() async throws {
        let root = directory
        let priorRecords = records, priorAcknowledgements = detachedOwners, priorConfiguration = configuration, priorRecoveryRevision = recoveryRevision
        acceptedMetadataLoadCount += 1; preferencesReadCount += 1
        let accepted = try await persistence.perform {
            let reader: BoundedCatalogReader
            do { reader = try BoundedCatalogReader(root: root) }
            catch { throw MetadataIssue(file: root.path, reason: error.localizedDescription) }
            func read<T: Decodable>(_ name: String, as: T.Type, limit: Int = CatalogLimits.manifestBytes) throws -> T? {
                guard RequestProcessIdentity.evidenceExists(root.appendingPathComponent(name)) else { return nil }
                do { return try JSONDecoder().decode(T.self, from: reader.read(name, limit: limit).bytes) }
                catch { throw MetadataIssue(file: root.appendingPathComponent(name).path, reason: RequestRecoveryStore.Entry.bounded(error.localizedDescription, bytes: 4096)) }
            }
            let store = try read("recovery.json", as: RequestRecoveryStore.self) ?? RequestRecoveryStore()
            guard store.formatVersion == 1, store.entries.allSatisfy({ $0.key == $0.value.journal && URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == RequestPaths.canonical(root) }) else { throw MetadataIssue(file: root.appendingPathComponent("recovery.json").path, reason: "Expected recovery format 1 and journal paths belonging to this request directory.") }
            let rows = try read("journal.json", as: [Record].self, limit: 128 * 1024 * 1024) ?? []
            let acknowledgements = try read("detached-checkouts.json", as: [DetachedCheckoutAcknowledgement].self) ?? []
            let configuration = try Self.readPreferences(at: root.appendingPathComponent("preferences.json"))
            var operations: [UUID: RequestWorkerOperation] = [:]
            for row in rows where row.dispatch != nil {
                let journal = root.appendingPathComponent(row.status.id.uuidString)
                if let operation = try? RequestWorkerOperation.read(in: journal) { operations[row.status.id] = operation }
            }
            return AcceptedMetadata(records: rows, acknowledgements: acknowledgements,
                recovery: store, configuration: configuration,
                active: try read("active.json", as: UUID.self), operations: operations,
                launchEvidence: Set(rows.filter { row in
                    if Self.hasProcessEvidence(root.appendingPathComponent(row.status.id.uuidString)) { return true }
                    guard let operationID = row.dispatch?.workerOperationID else { return false }
                    return operations[row.status.id]?.id == operationID && operations[row.status.id]?.phase == .complete
                }.map { $0.status.id }),
                validation: try read("metadata-validation.json", as: RequestPersistence.ValidationBlocker.self, limit: 65536),
                paths: Self.canonicalRepositories((configuration.map { [$0.repository] } ?? []) + acknowledgements.map(\.repository)))
        }
        guard Set(accepted.records.map { $0.status.id }).count == accepted.records.count else { throw MetadataIssue(file: root.appendingPathComponent("journal.json").path, reason: "Duplicate request identities.") }
        try await waitForStorageChange(cancellable: false)
        let changed = Set(Set(priorRecords.keys).union(records.keys).filter { priorRecords[$0] != records[$0] })
        var reconstructed = Dictionary(uniqueKeysWithValues: accepted.records.map { ($0.status.id, $0) })
        for id in changed { reconstructed[id] = records[id] }
        records = reconstructed
        if detachedOwners == priorAcknowledgements { detachedOwners = accepted.acknowledgements }
        if recoveryRevision == priorRecoveryRevision { recovery = accepted.recovery }
        // Full reconstruction is reserved for startup and on-disk storage recovery.
        // Independently accepted facts arriving during inspection take precedence.
        if let id = recoveryID, records[id] == nil { recoveryID = nil }
        maintenanceProposals.removeAll()
        if var restored = accepted.configuration, configuration == priorConfiguration {
            // Initialization's trusted app relocation is launch context, not a
            // rejected preference edit. Captured request configurations stay exact.
            if let bundledShaderTool, configuration.shaderTool == bundledShaderTool || initializationInput?.shaderTool == bundledShaderTool { restored.shaderTool = bundledShaderTool }
            configuration = restored; configurationAccepted = true; requiresVerification = false
        } else if !configurationAccepted, var proposed = initializationInput {
            if startupWasBlocked { proposed.enabled = false; requiresVerification = true }
            configuration = proposed; configurationAccepted = true
        }
        if validationBlocker == nil { validationBlocker = accepted.validation }
        if let validationBlocker { persistenceRevision = max(persistenceRevision, validationBlocker.revision) }
        normalizeAcceptedMetadata(active: accepted.active, operations: accepted.operations, launchEvidence: accepted.launchEvidence, paths: accepted.paths, preserving: changed)
        acceptedMetadataAvailable = true; metadataAdmission.establishBaseline(blocked: metadataIssue != nil)
        reconciled = false; refreshReconciliationFailure()
    }
    private func normalizeAcceptedMetadata(active: UUID?, operations: [UUID: RequestWorkerOperation], launchEvidence: Set<UUID>, paths: [String: String], preserving changed: Set<UUID> = []) {
        if recoveryID.map({ !changed.contains($0) }) ?? true { recoveryID = nil }
        for id in records.keys where !changed.contains(id) {
            guard var record = records[id] else { continue }
            if let dispatch = record.dispatch {
                if !dispatch.launched && !launchEvidence.contains(id) {
                    if !record.status.stage.terminal && ![.awaitingActivation, .awaitingClarification].contains(record.status.stage) { record.status.stage = dispatch.priorStage }
                    pendingRetirements[id] = dispatch.executionID
                } else if dispatch.retirementPending || (operations[id]?.id == dispatch.workerOperationID && operations[id]?.phase == .complete) {
                    pendingRetirements[id] = dispatch.executionID
                    if !record.status.stage.terminal && ![.awaitingActivation, .awaitingClarification].contains(record.status.stage) {
                        record.status.stage = .failed; record.status.message = "Worker settled before metadata recovery; inspect its retained log."
                    }
                } else if active == id, ![.awaitingActivation, .awaitingClarification].contains(record.status.stage),
                          !record.status.stage.terminal || record.cleanupPending == true {
                    recoveryID = id
                    if !record.status.stage.terminal { record.status.stage = .repairing }
                }
            } else if active == id, (!record.status.stage.terminal || record.cleanupPending == true), ![.awaitingActivation, .awaitingClarification].contains(record.status.stage) {
                recoveryID = id
                if !record.status.stage.terminal { record.status.stage = .repairing; record.status.message = "Recovering interrupted request" }
            }
            if detachedOwners.contains(where: { $0.requestID == id }) {
                record.detached = true; record.cleanupPending = false
                if !record.status.stage.terminal { record.status.stage = .failed; record.status.message = "Checkout detached; unpublished files and evidence were retained" }
            }
            if record.revoked, !record.status.stage.terminal, record.detached != true {
                record.cleanupPending = true; record.cleanupMessage = "TV access was revoked; any pushed commit remains"
                record.status.stage = .failed; record.status.message = "TV access was revoked; checkout cleanup is pending"
            }
            if record.detached == true, recoveryID == id { recoveryID = nil }
            record.cleanupFailure = nil; records[id] = record
        }
        if detachedOwners.contains(where: { Self.matchesDetachedCheckout(configuration, acknowledgement: $0, paths: paths) }) { configuration.enabled = false }
    }
    private func resetPersistenceFailure() async throws {
        let attempt = UUID()
        metadataRecoveryAttempt = attempt; metadataRecoveryIssueID = metadataIssue?.id; metadataAdmission.beginRecovery(attempt)
        defer {
            if metadataRecoveryAttempt == attempt { metadataRecoveryAttempt = nil; metadataRecoveryIssueID = nil }
            metadataAdmission.endRecovery(attempt, accepted: metadataIssue == nil && acceptedMetadataAvailable && storageFaultInspected)
        }
        try await MetadataAuthority.$recovery.withValue(attempt) {
            var token: RequestPersistence.RecoveryToken?
            let issueID = metadataIssue?.id
            do {
                if let retirementTask { await retirementTask.value }
                try await inspectStorage()
                token = try await persistence.restoreForRecovery()
                if !acceptedMetadataAvailable || token?.reloadAccepted == true {
                    try await reloadAcceptedMetadata()
                } else if metadataIssue?.preferencesOnly == true {
                    _ = try await readAcceptedPreferences(reason: "Repaired preferences must match the accepted setup.")
                }
                if configurationAccepted, metadataIssue?.preferencesOnly == true || requiresVerification {
                    let permit = try admitMetadataMutation(), bytes = try JSONEncoder().encode(configuration)
                    try await persistence.write(bytes, to: directory.appendingPathComponent("preferences.json"), recovery: token, metadataPermit: permit)
                }
                if startupFinalizationFailure != nil { try await beforeStartupFinalization() }
                let validationRevision = try await persist(recoveryToken: token)
                try await retirePendingWorkers(recoveryToken: token)
                try await persistence.clearValidation(through: validationRevision)
                let receipt = try await persistence.finishRecovery(token)
                resolvedPersistenceGeneration = max(resolvedPersistenceGeneration, receipt.clearedGeneration)
                if let fault = persistenceFault, fault.generation > receipt.clearedGeneration { throw fault }
                persistenceFault = nil
                if metadataIssue?.id == issueID { metadataIssue = nil }
                resolvedValidationRevision = max(resolvedValidationRevision, validationRevision)
                if (validationBlocker?.revision ?? 0) <= validationRevision { validationBlocker = nil }
                if let validationBlocker { throw RequestPersistence.ValidationError(message: validationBlocker.message) }
                startupFinalizationFailure = nil; refreshSetupMessage()
                emitUpdates(); if schedulingDeferred { scheduleWakeup() }
            } catch {
                await persistence.abortRecovery(token)
                if error is MetadataIssue { publishMetadataIssue(error, file: directory.path, preferencesOnly: metadataIssue?.preferencesOnly == true) }
                publishStorageFault(error); throw error
            }
        }
    }
    func applyPersistenceReceipt(_ receipt: RequestPersistence.CommitReceipt) {
        if let value = receipt.recovery[directory.appendingPathComponent("recovery.json")], value.generation == recoveryRevision {
            recovery = value.store
        }
    }
    func progressPersistenceFailed(_ error: Error) {
        publishStorageFault(error)
        publishValidation(error)
    }
    private func holdForRecovery(journal: URL, configuration target: ShaderRequestConfiguration?, error: Error,
                                 preferencesRollback: ShaderRequestConfiguration? = nil) async {
        let key = RequestPaths.canonical(journal), id = records.keys.first { RequestPaths.canonical(folder($0)) == key }
        let disposition: ShaderRequestRecoveryDisposition
        if let id, records[id]?.cleanupPending == true || records[id]?.revoked == true { disposition = .cleanup }
        else if let id, records[id]?.status.stage == .awaitingActivation || records[id]?.status.stage == .completed { disposition = .retainResult }
        else { disposition = .resume }
        var entry = recovery.entries[key] ?? .init(journal: key, requestID: id, configuration: target, disposition: disposition, message: error.localizedDescription)
        entry.configuration = entry.configuration ?? target
        let detail = error.localizedDescription
        entry.appendDiagnostic(detail)
        if let preferencesRollback { entry.preferencesRollback = preferencesRollback }
        recovery.entries[key] = entry
        reconciliationFailure = entry.message; reconciliationJournal = URL(fileURLWithPath: key); reconciliationConfiguration = entry.configuration; invalidateJournal(key)
        do { try await persistRecovery(retainingEvidence: true); try await persist() }
        catch {
            var current = recovery.entries[key] ?? entry
            current.appendDiagnostic("Recovery state could not be saved: " + error.localizedDescription)
            recovery.entries[key] = current; refreshReconciliationFailure(); emitUpdates()
        }
        let log = URL(fileURLWithPath: key).appendingPathComponent("recovery-diagnostic.log")
        _ = try? await persistence.perform { try RequestJournalWriter.appendDiagnostic(detail, to: log) }
    }
    private func appendRecoveryFailure(journal: URL, configuration: ShaderRequestConfiguration?, error: Error) async {
        let key = RequestPaths.canonical(journal)
        guard var entry = recovery.entries[key] else { await holdForRecovery(journal: journal, configuration: configuration, error: error); return }
        let detail = error.localizedDescription
        entry.appendDiagnostic(detail)
        recovery.entries[key] = entry; reconciliationFailure = entry.message; invalidateJournal(key)
        do { try await persistRecovery(retainingEvidence: true); try await persist() } catch { reconciliationFailure = entry.message + " Recovery state could not be saved: " + error.localizedDescription; emitUpdates() }
        let log = URL(fileURLWithPath: key).appendingPathComponent("recovery-diagnostic.log")
        _ = try? await persistence.perform { try RequestJournalWriter.appendDiagnostic(detail, to: log) }
    }
    private func finalizeDetachment(_ entry: RequestRecoveryStore.Entry) async throws {
        let permit = try admitMetadataMutation()
        guard let archiveID = entry.archiveID else {
            throw RequestWorkerEvidenceError(cause: "Detachment archive intent is missing; retry explicit Detach.")
        }
        try await persistence.mutate(metadataPermit: permit) { try RequestJournalWriter.archive(in: URL(fileURLWithPath: entry.journal), id: archiveID) }
        guard let id = entry.requestID, let target = entry.configuration else { return }
        let acknowledgement = Self.acknowledgement(id: id, job: URL(fileURLWithPath: entry.journal), configuration: target)
        try await waitForStorageChange(cancellable: false)
        detachedOwners.removeAll { $0.requestID == id }; detachedOwners.append(acknowledgement)
        _ = try await appliedRecord(id, .detached)
    }

    private func drainReconciliation(lease: UUID) async throws {
        let previous = reconciliationTask
        // Invalidate its actor callback before awaiting the detached observer. The
        // maintenance lease prevents a replacement worker or observer from starting.
        reconciliationTask = nil; reconciliationKickID = nil; reconciled = false
        if let previous { _ = try? await previous.task.value }
        try checkMaintenance(lease)
    }

    public func retryReconciliation() async throws { try await retryReconciliation(replayTrusted: true) }
    func retryReconciliation(replayTrusted: Bool) async throws {
        try await recoverLocalMetadata()
        // Release the local maintenance lease before visiting other service targets.
        if replayTrusted, let coordinator = revocationCoordinator { try await coordinator() }
    }
    private func recoverLocalMetadata() async throws {
        guard activeID == nil, !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout work to finish.") }
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        // Invalidate the previous observer before storage recovery's first await;
        // its late result must not publish a new failure into the restored state.
        try await drainReconciliation(lease: lease); try await resetPersistenceFailure()
        for id in records.keys.sorted(by: { $0.uuidString < $1.uuidString }) where records[id]?.deletionPending == true { await finishDeletion(id) }
        var failures: [String] = []
        for key in recovery.entries.keys.sorted() {
            guard let entry = recovery.entries[key] else { continue }
            do {
                let journal = URL(fileURLWithPath: entry.journal)
                do { try await reconcileWorker(journal) }
                catch where entry.disposition == .detach && !(error is RequestWorkerTeardownError) && !(error is RequestWorkerOwnershipError) && !(error is CancellationError) {
                    // Exact-entry finalization archives unverifiable markers after settlement.
                }
                try checkMaintenance(lease)
                if let repair = entry.maintenanceRepair {
                    try await completeMaintenanceRepair(key, repair: repair, lease: lease)
                } else if let repair = entry.configurationRepair {
                    guard let id = entry.requestID else { throw RequestWorkerOwnershipError() }
                    try await Task.detached { try Self.validateRecoveryCheckout(repair.corrected, id: id, job: journal) }.value
                    try checkMaintenance(lease)
                    try await completeConfigurationRepair(key, lease: lease)
                } else if entry.disposition == .retainResult {
                    try await journalChange("retire worker operation", in: journal) { try RequestWorkerOperation.retire(in: journal) }
                } else if entry.disposition != .detach, try RequestWorkerOperation.read(in: journal) != nil {
                    guard let target = entry.configuration else { throw RequestWorkerOwnershipError() }
                    let saved = try Self.savedConfiguration(in: journal)
                    guard saved.map({ Self.samePublicationCheckout($0, target) }) == true else { throw RequestWorkerOwnershipError() }
                    if let id = entry.requestID {
                        try await Task.detached { try Self.validateRecoveryCheckout(target, id: id, job: journal) }.value
                    } else {
                        try await Task.detached { try Self.validateMaintenanceRecoveryCheckout(target) }.value
                    }
                    try checkMaintenance(lease)
                    try await journalChange("restart recovered operation", in: journal) { try RequestWorkerOperation.restartPaused(in: journal, configuration: target, repairLegacyMismatch: true) }
                }
                try await persist()
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures.append(entry.journal + ": " + error.localizedDescription)
                await appendRecoveryFailure(journal: URL(fileURLWithPath: entry.journal), configuration: entry.configuration, error: error)
            }
        }
        if !failures.isEmpty { throw ShaderRequestError.unavailable(failures.joined(separator: "\n")) }
        try await reconcileWorkers(); try checkMaintenance(lease)
        try await persist()
    }

    private func completeConfigurationRepair(_ key: String, lease: UUID) async throws {
        guard let entry = recovery.entries[key], var repair = entry.configurationRepair else { return }
        guard repair.version == nil || repair.version == 1 || repair.version == 2 else { throw RequestWorkerEvidenceError(cause: "Unsupported cleanup repair intent version.") }
        if repair.participants == nil {
            var participants: [RequestRecoveryStore.ConfigurationRepair.Participant] = []
            for id in repair.requestIDs {
                guard let record = records[id] else {
                    let path = folder(id)
                    guard !RequestProcessIdentity.evidenceExists(path), try Self.ownerMarker(repair.corrected)?.id != id else { throw RequestWorkerOwnershipError() }
                    continue // Older versions permitted deleting a terminal participant and its entire folder.
                }
                guard record.detached != true, Self.samePublicationCheckout(record.configuration, repair.previous) || Self.samePublicationCheckout(record.configuration, repair.corrected) else { throw RequestWorkerOwnershipError() }
                let corrected = repair.applying(to: record.configuration, primary: id == entry.requestID)
                if corrected != record.configuration || id == entry.requestID {
                    participants.append(.init(requestID: id, change: .init(previous: record.configuration, corrected: corrected),
                        mode: record.cleanupPending == true ? "discard" : "run", oldID: try RequestWorkerOperation.read(in: folder(id))?.id))
                }
            }
            repair.version = 2; repair.participants = participants; repair.requestIDs = participants.map(\.requestID)
            if repair.updatePreferences {
                guard Self.samePublicationCheckout(configuration, repair.previous) || Self.samePublicationCheckout(configuration, repair.corrected) else { throw RequestWorkerOwnershipError() }
                repair.preferences = .init(previous: configuration, corrected: repair.applying(to: configuration))
            }
            recovery.entries[key]?.configurationRepair = repair; try await persistRecovery()
        }
        guard repair.version == 2, Set(repair.requestIDs).count == repair.requestIDs.count,
              Set(repair.participants?.map(\.requestID) ?? []) == Set(repair.requestIDs) else { throw RequestWorkerOwnershipError() }
        func validChange(_ change: RequestRecoveryStore.ConfigurationRepair.Change) -> Bool {
            var expected = change.previous
            expected.repository = change.corrected.repository; expected.python = change.corrected.python; expected.git = change.corrected.git
            return expected == change.corrected && Self.samePublicationCheckout(change.previous, change.corrected)
        }
        if let preferences = repair.preferences, !validChange(preferences) { throw RequestWorkerOwnershipError() }
        if var preferences = repair.preferences, configuration != preferences.previous, configuration != preferences.corrected,
           let bundledShaderTool, configuration.shaderTool == bundledShaderTool {
            preferences.previous.shaderTool = bundledShaderTool; preferences.corrected.shaderTool = bundledShaderTool
            guard configuration == preferences.previous || configuration == preferences.corrected else { throw RequestWorkerOwnershipError() }
            // Only the app's current bundled executable may relocate preference replay.
            // Captured request configurations keep their original tools.
            repair.preferences = preferences; recovery.entries[key]?.configurationRepair = repair
            try await persistRecovery()
        }
        for participant in repair.participants ?? [] {
            guard validChange(participant.change), ["run", "discard"].contains(participant.mode) else { throw RequestWorkerOwnershipError() }
            try await reconcileWorker(folder(participant.requestID))
            try checkMaintenance(lease)
            guard let record = records[participant.requestID], record.detached != true,
                  record.configuration == participant.change.previous || record.configuration == participant.change.corrected else { throw RequestWorkerOwnershipError() }
        }
        for participant in repair.participants ?? [] {
            let journal = folder(participant.requestID)
            try await journalChange("repair operation binding", in: journal) { try RequestWorkerOperation.repair(in: journal, mode: participant.mode,
                previous: participant.change.previous, corrected: participant.change.corrected, oldID: participant.oldID, newID: participant.newID, repairLegacyMismatch: true) }
            try checkMaintenance(lease)
        }
        for participant in repair.participants ?? [] {
            guard try await appliedRecord(participant.requestID, .configuration(participant.change.previous, participant.change.corrected)) != nil else { throw RequestWorkerOwnershipError() }
        }
        try await persist() // Retain the intent until bindings, records and preferences converge.
        try checkMaintenance(lease)
        if let preferences = repair.preferences {
            guard configuration == preferences.previous || configuration == preferences.corrected else { throw RequestWorkerOwnershipError() }
            try await writeFile(to: directory.appendingPathComponent("preferences.json")) { service in
                try service.checkMaintenance(lease)
                guard service.configuration == preferences.previous || service.configuration == preferences.corrected else { throw RequestWorkerOwnershipError() }
                return try JSONEncoder().encode(preferences.corrected)
            }
            configuration = preferences.corrected
        }
        recovery.entries[key]?.configuration = records[entry.requestID ?? UUID()]?.configuration ?? repair.corrected
        recovery.entries[key]?.configurationRepair = nil
        if let id = entry.requestID { transitionRecord(id, .cleanupFailure(nil)); recoveryID = id }
        try await persist()
    }

    private func proposalInput(_ entry: RequestRecoveryStore.Entry) -> ProposalInput? {
        guard entry.requestID == nil, entry.disposition != .detach, entry.maintenanceRepair == nil,
              entry.configurationRepair == nil, ["setup", "publication"].contains(URL(fileURLWithPath: entry.journal).lastPathComponent) else { return nil }
        return ProposalInput(id: entry.id, journal: entry.journal, generation: proposalGenerations[entry.journal, default: 0], configuration: configuration)
    }
    private func proposedMaintenanceConfiguration(_ entry: RequestRecoveryStore.Entry) -> ShaderRequestConfiguration? {
        guard let input = proposalInput(entry), maintenanceProposals[entry.id]?.input == input else { return nil }
        return maintenanceProposals[entry.id]?.configuration
    }
    private func invalidateMaintenanceProposal(_ journal: String) {
        proposalGenerations[journal, default: 0] &+= 1
        scheduleMaintenanceProposals()
    }
    private func scheduleMaintenanceProposals() {
        guard initialized, proposalTask == nil,
              recovery.entries.values.compactMap(proposalInput).contains(where: { maintenanceProposals[$0.id]?.input != $0 }) else { return }
        proposalTask = Task { [weak self] in await self?.prepareMaintenanceProposals() }
    }
    private func prepareMaintenanceProposals() async {
        defer { proposalTask = nil }
        while true {
            maintenanceProposals = maintenanceProposals.filter { cached in recovery.entries.values.contains { $0.id == cached.key } }
            let inputs = recovery.entries.values.compactMap(proposalInput).filter { maintenanceProposals[$0.id]?.input != $0 }
            guard !inputs.isEmpty else { return }
            let read = readMaintenanceProposal
            maintenanceProposalReadCount += inputs.count
            let proposals = (try? await persistence.perform {
                inputs.map { input -> MaintenanceProposal in
                    var proposed: ShaderRequestConfiguration?
                    if let operation = try? read(URL(fileURLWithPath: input.journal)),
                       ["preflight", "publication"].contains(operation.mode), let target = operation.target {
                        var value = operation.binding.flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0.replacement) } ?? input.configuration
                        value.repository = target.repository; value.checkoutID = target.checkoutID
                        proposed = value
                    }
                    return MaintenanceProposal(input: input, configuration: proposed)
                }
            }) ?? []
            for proposal in proposals {
                guard let entry = recovery.entries[proposal.input.journal], proposalInput(entry) == proposal.input else { continue }
                maintenanceProposals[entry.id] = proposal
            }
            emitUpdates()
        }
    }
    public func repairMaintenanceRecovery(_ id: UUID, configuration candidate: ShaderRequestConfiguration) async throws {
        guard activeID == nil, !maintenanceBusy, let entry = recovery.entries.values.first(where: { $0.id == id }),
              entry.requestID == nil, entry.disposition != .detach, entry.configurationRepair == nil else { throw RequestWorkerOwnershipError() }
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        try await drainReconciliation(lease: lease)
        let journal = URL(fileURLWithPath: entry.journal)
        let original: RequestWorkerOperation
        if let pending = entry.maintenanceRepair { original = pending.operation }
        else {
            original = try await persistence.perform { guard let operation = try RequestWorkerOperation.read(in: journal) else { throw RequestWorkerOwnershipError() }; return operation }
            invalidateMaintenanceProposal(entry.journal)
        }
        guard ["preflight", "publication"].contains(original.mode), let target = original.target else { throw RequestWorkerOwnershipError() }
        var candidate = candidate; candidate.repository = RequestPaths.canonical(URL(fileURLWithPath: candidate.repository)); candidate.checkoutID = target.checkoutID
        guard RequestWorkerOperation.Target(candidate) == target else { throw RequestWorkerOwnershipError() }
        if let pending = entry.maintenanceRepair, try !RequestWorkerOperation.matches(JSONEncoder().encode(pending.configuration), configuration: candidate, id: nil) { throw RequestWorkerEvidenceError(cause: "A different maintenance repair is already pending. Retry its saved configuration before proposing another repair.") }
        try await Task.detached { [candidate] in try Self.validateMaintenanceRecoveryCheckout(candidate) }.value
        try checkMaintenance(lease); try await reconcileWorker(journal); try checkMaintenance(lease)
        try await resetPersistenceFailure()
        guard recovery.entries[entry.journal]?.id == id, recovery.entries[entry.journal]?.disposition != .detach else { throw RequestWorkerOwnershipError() }
        let repair: RequestRecoveryStore.MaintenanceRepair
        if let pending = entry.maintenanceRepair { repair = pending }
        else {
            repair = RequestRecoveryStore.MaintenanceRepair(operation: original, configuration: candidate)
            let prior = recovery.entries[entry.journal]
            recovery.entries[entry.journal]?.maintenanceRepair = repair
            try await commitRepairIntent(key: entry.journal, previous: prior)
        }
        try checkMaintenance(lease)
        try await completeMaintenanceRepair(entry.journal, repair: repair, lease: lease)
        try await reconcileWorkers(); try checkMaintenance(lease)
    }
    private func commitRepairIntent(key: String, previous: RequestRecoveryStore.Entry?) async throws {
        let root = directory
        let priorBytes = try? await persistence.perform { try BoundedCatalogReader(root: root).read("recovery.json", limit: CatalogLimits.manifestBytes).bytes }
        do { try await persistRecovery() }
        catch {
            // A writer can fail after atomic replacement. Only discard a proposal when
            // the last committed file is provably unchanged; otherwise keep it pending.
            let savedBytes = try? await persistence.perform { try BoundedCatalogReader(root: root).read("recovery.json", limit: CatalogLimits.manifestBytes).bytes }
            if let priorBytes, savedBytes == priorBytes {
                recovery.entries[key] = previous; refreshReconciliationFailure()
            }
            else {
                recovery.entries[key]?.appendDiagnostic("Configuration repair persistence is uncertain; Retry Recovery must finish it.")
                // An already-published repair is durable recovery intent, not a rejected
                // caller proposal. Confirm it independently of the ordinary storage gate.
                try? await persistRecovery(retainingEvidence: true)
            }
            throw error
        }
    }
    private func completeMaintenanceRepair(_ key: String, repair: RequestRecoveryStore.MaintenanceRepair, lease: UUID) async throws {
        let journal = URL(fileURLWithPath: key)
        guard repair.operation.target == RequestWorkerOperation.Target(repair.configuration),
              ["setup", "publication"].contains(journal.lastPathComponent), journal.deletingLastPathComponent().path == RequestPaths.canonical(directory) else { throw RequestWorkerOwnershipError() }
        try await Task.detached { try Self.validateMaintenanceRecoveryCheckout(repair.configuration) }.value
        try checkMaintenance(lease); try await reconcileWorker(journal); try checkMaintenance(lease)
        let archive = journal.appendingPathComponent("detached-" + repair.archiveID.uuidString)
        let current = try RequestWorkerOperation.read(in: journal)
        if current?.id != repair.replacementID {
            if let current { guard current.id == repair.operation.id, current.target == repair.operation.target else { throw RequestWorkerOwnershipError() } }
            else { guard try RequestWorkerOperation.read(in: archive)?.id == repair.operation.id else { throw RequestWorkerOwnershipError() } }
            let permit = try admitMetadataMutation()
            try await persistence.mutate(metadataPermit: permit) { try RequestJournalWriter.archive(in: journal, id: repair.archiveID) }
            try checkMaintenance(lease)
        }
        try await journalChange("create repaired operation", in: journal) { try RequestWorkerOperation.createRepaired(in: journal, mode: repair.operation.mode, configuration: repair.configuration, id: repair.replacementID) }
        recovery.entries[key]?.configuration = repair.configuration; recovery.entries[key]?.maintenanceRepair = nil
        try await persist()
    }

    public func retryCleanup(_ id: UUID, repository: String, python: String, git: String) async throws {
        guard activeID == nil, !maintenanceBusy, let record = records[id], record.cleanupPending == true else {
            throw ShaderRequestError.unavailable("Wait for active checkout work to finish before retrying cleanup.")
        }
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        try await drainReconciliation(lease: lease)
        var corrected = record.configuration
        corrected.repository = RequestPaths.canonical(URL(fileURLWithPath: repository)); corrected.python = python; corrected.git = git
        guard corrected.repository == RequestPaths.canonical(URL(fileURLWithPath: record.configuration.repository)) else {
            throw ShaderRequestError.unavailable("Restore the owned checkout's original path, or detach it and select a fresh clean checkout.")
        }
        let job = folder(id)
        try await Task.detached { [corrected] in try Self.validateRecoveryCheckout(corrected, id: id, job: job) }.value
        try checkMaintenance(lease)
        guard records[id]?.detached != true else { throw CancellationError() }
        try await reconcileWorker(job); try checkMaintenance(lease)
        try await resetPersistenceFailure()
        let key = RequestPaths.canonical(job)
        var entry = recovery.entries[key] ?? .init(journal: key, requestID: id, configuration: record.configuration,
            disposition: .cleanup, message: record.cleanupFailure ?? "Completing saved cleanup configuration repair")
        entry.configurationRepair = .init(previous: record.configuration, corrected: corrected,
            requestIDs: records.values.filter { $0.detached != true && Self.samePublicationCheckout($0.configuration, record.configuration) }.map { $0.status.id },
            updatePreferences: Self.samePublicationCheckout(configuration, record.configuration))
        let previous = recovery.entries[key]
        recovery.entries[key] = entry
        try await commitRepairIntent(key: key, previous: previous)
        try checkMaintenance(lease)
        do { try await completeConfigurationRepair(key, lease: lease) }
        catch { await appendRecoveryFailure(journal: job, configuration: record.configuration, error: error); throw error }
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil
        try await reconcileWorkers(); try checkMaintenance(lease)
    }

    private typealias DetachmentTarget = (journal: URL, requestID: UUID?, checkout: ShaderRequestConfiguration)
    private func detachmentTargets(for selected: ShaderRequestConfiguration) -> [String: DetachmentTarget] {
        var targets: [String: DetachmentTarget] = [:]
        func add(_ journal: URL, _ id: UUID?, _ checkout: ShaderRequestConfiguration) {
            let key = RequestPaths.canonical(journal)
            targets[key] = (URL(fileURLWithPath: key), id, checkout)
        }
        let paths = Self.canonicalRepositories([selected.repository] + records.values.map { $0.configuration.repository })
        for (id, record) in records where Self.samePublicationCheckout(record.configuration, selected, paths: paths) {
            add(folder(id), id, record.configuration)
        }
        for entry in recovery.entries.values {
            if let checkout = entry.configuration, Self.samePublicationCheckout(checkout, selected) {
                add(URL(fileURLWithPath: entry.journal), entry.requestID, checkout)
            }
        }
        for name in ["setup", "publication"] {
            let journal = directory.appendingPathComponent(name)
            if let checkout = try? Self.savedConfiguration(in: journal), Self.samePublicationCheckout(checkout, selected) {
                let key = RequestPaths.canonical(journal)
                if targets[key] == nil { add(journal, nil, checkout) }
            }
        }
        if targets.isEmpty { add(directory.appendingPathComponent("detachment"), nil, selected) }
        return targets
    }
    private func markPendingDetachment(_ targets: [String: DetachmentTarget]) {
        for (key, target) in targets {
            var entry = recovery.entries[key] ?? .init(journal: key, requestID: target.requestID,
                configuration: target.checkout, disposition: .detach, message: "")
            entry.disposition = .detach
            entry.archiveID = entry.archiveID ?? UUID()
            let original = entry.primaryDiagnostic ?? entry.message
            entry.message = "Detachment is pending until worker processes are confirmed stopped."
            entry.primaryDiagnostic = entry.message
            if !original.isEmpty { entry.appendDiagnostic(original) }
            recovery.entries[key] = entry
        }
    }

    public func detachCheckout(_ target: ShaderCheckoutDetachTarget) async throws {
        guard !selectingRepository || acceptingRepository else { throw ShaderRequestError.unavailable("Wait for the selected folder to finish loading before detaching.") }
        guard !detaching else { throw ShaderRequestError.unavailable("Checkout detachment is already in progress.") }
        let selected: ShaderRequestConfiguration
        switch target {
        case .request(let id):
            guard let record = records[id] else { throw ShaderRequestError.invalidRequest }
            selected = record.configuration
        case .recovery(let id):
            guard let entry = recovery.entries.values.first(where: { $0.id == id }), let checkout = entry.configuration else {
                throw ShaderRequestError.unavailable("This recovery journal has no verified checkout target. Repair its configuration; no selected checkout has been detached.")
            }
            selected = checkout
        case .selectedCheckout:
            guard recovery.entries.isEmpty, reconciliationFailure == nil else {
                throw ShaderRequestError.unavailable("Select an exact recovery entry; there is no verified checkout target for a global detachment.")
            }
            selected = configuration
        }
        let paths = Self.canonicalRepositories([selected.repository] + records.values.map { $0.configuration.repository })
        let ids = records.keys.filter { Self.samePublicationCheckout(records[$0]!.configuration, selected, paths: paths) }
        guard activeID == nil || ids.contains(activeID!) else { throw ShaderRequestError.unavailable("Wait for the other checkout’s active request before detaching this checkout.") }
        detaching = true
        defer { detaching = false; kick() }
        // Reserve detachment before yielding. Existing maintenance owns its lease until it retires.
        var targets = detachmentTargets(for: selected)
        markPendingDetachment(targets)
        configuration.enabled = false; execution?.interrupted = true
        try await persistRecovery()
        cancelPublicationRequests(); activeProcess?.stop()
        try await persist()
        try await writeFile(to: directory.appendingPathComponent("preferences.json")) { service in try JSONEncoder().encode(service.configuration) }
        if let process = activeProcess {
            do { try await settleProcess(process) }
            catch is RequestWorkerEvidenceError {
                // Verified processes have retired. Drain the operation, then let the
                // exact-journal reconciliation below retain its unverifiable markers.
            }
        }
        if let task = workerTask { await task.value }
        await waitForMaintenance()
        let lease = try beginMaintenance(forDetachment: true)
        defer { endMaintenance(lease) }
        // Reconciliation may have been running before the reservation. It must finish before handoff.
        if let attempt = reconciliationTask {
            _ = try? await attempt.task.value
            if reconciliationTask?.id == attempt.id { reconciliationTask = nil }
        }
        reconciliationKickID = nil
        // Work can discover an additional recovery journal while it is draining.
        targets.merge(detachmentTargets(for: selected)) { _, current in current }
        markPendingDetachment(targets)
        try await persistRecovery(); try await persist()
        for (_, target) in targets.sorted(by: { $0.key < $1.key }) {
            let (journal, _, checkout) = target
            do { try await reconcileWorker(journal) }
            catch {
                if error is CancellationError { throw error }
                if error is RequestWorkerTeardownError || error is RequestWorkerOwnershipError {
                    await holdForRecovery(journal: journal, configuration: checkout, error: error); throw error
                }
                // Finalization archives all markers and both binding files under the
                // already durable archive ID, including dangling symlinks.

            }
        }
        for (journal, _, _) in targets.values {
            if let entry = recovery.entries[RequestPaths.canonical(journal)] { try await finalizeDetachment(entry) }
        }
        try await persist()
        for key in targets.keys { recovery.entries[key] = nil }
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil
        refreshReconciliationFailure()
        resolvePublicationFailure()
        setupMessage = "Requests disabled. Select a checkout and verify setup before enabling requests again."
        try await persist()
    }

    /// Cache restoration and forced rebuilds share the checkout scheduler with recovery and jobs.
    public func ensurePublication(force: Bool = false) async throws {
        guard initialized else { throw ShaderRequestError.unavailable("Initialize shader requests before preparing the library.") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                var request = pendingPublication ?? PublicationRequest(force: force, waiters: [])
                request.force = request.force || force
                request.waiters.append(PublicationWaiter(id: id, continuation: continuation))
                pendingPublication = request
                kick()
            }
        } onCancel: { Task { await self.cancelPublicationWaiter(id) } }
    }
    private func cancelPublicationWaiter(_ id: UUID) {
        if let index = pendingPublication?.waiters.firstIndex(where: { $0.id == id }) {
            pendingPublication?.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            if pendingPublication?.waiters.isEmpty == true, pendingPublication?.ownsRetry != true { pendingPublication = nil }
        }
        if let index = activePublication?.waiters.firstIndex(where: { $0.id == id }) {
            activePublication?.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            if activePublication?.waiters.isEmpty == true, activePublication?.ownsRetry != true {
                execution?.interrupted = true; activeProcess?.stop()
            }
        }
    }
    private func runPublication(operation: UUID) async {
        do {
            if activePublication?.force != true {
                do {
                    if let cached = try await catalog.cached() {
                        try checkExecution(operation); finishPublication(revision: cached.publicationRevision); return
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { Diagnostics.catalog.error("Previous publication unavailable; rebuilding: \(error.localizedDescription, privacy: .public)") }
            }
            try checkExecution(operation)
            let outcome = try await runWorker(mode: "publication", configuration: configuration, journal: directory.appendingPathComponent("publication"), operation: operation) { event, process, attempt in
                try checkExecution(operation)
                switch event.event {
                case "preparePublication": try await preparePublication(event, process: process, operation: operation, attempt: attempt)
                default: break
                }
            }
            try checkExecution(operation)
            guard let preparedID, preparedAttemptID == outcome.attemptID else { throw ShaderRequestError.unavailable("Publication rebuild did not complete.") }
            let publication = try await catalog.install(preparedID)
            self.preparedID = nil; published(publication)
            try await persist()
            finishPublication(revision: publication.catalog.publicationRevision)
        } catch {
            if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
            if execution?.interrupted == true,
               activePublication?.waiters.isEmpty == false || activePublication?.ownsRetry == true {
                let request = activePublication!
                if pendingPublication == nil { pendingPublication = request }
                else {
                    var pending = pendingPublication!
                    pending.force = pending.force || request.force; pending.waiters += request.waiters
                    pending.ownsRetry = pending.ownsRetry || request.ownsRetry
                    pendingPublication = pending
                }
                activePublication = nil
                finishPublication()
            } else { finishPublication(error: execution?.interrupted == true ? CancellationError() : error) }
        }
    }
    private func finishPublication(error: Error? = nil, revision: String? = nil) {
        let waiters = activePublication?.waiters ?? []
        let lease = execution?.id
        activePublication = nil; activeProcess = nil; execution = nil; workerTask = nil
        if let lease { endMaintenance(lease, schedule: false) }
        let reported: Error?
        if let error, !(error is CancellationError) {
            reported = publicationState(.failed, message: error.localizedDescription, correlationID: lease)
        } else {
            _ = publicationState(.idle, revision: revision, correlationID: lease)
            reported = error
        }
        for waiter in waiters {
            if let reported { waiter.continuation.resume(throwing: reported) }
            else { waiter.continuation.resume() }
        }
        kick()
    }

    private func settleProcess(_ process: RequestWorkerProcess) async throws {
        let operation = execution?.id, processID = ObjectIdentifier(process)
        do {
            try await waitForWorker(process)
            if let operation, execution?.id == operation, execution?.processID == processID {
                let launched = execution?.checkoutLaunched == true || process.checkoutLaunched
                execution?.checkoutLaunched = launched
                if let id = activeID {
                    transitionRecord(id, .launch(operation, launched), execution: operation)
                    settledExecutions.insert(operation)
                }
            }
        }
        catch {
            if let operation, execution?.id == operation, execution?.processID == processID { settledExecutions.remove(operation) }
            await holdForRecovery(journal: process.recoveryTarget?.directory ?? activeID.map(folder) ?? directory.appendingPathComponent("publication"),
                configuration: process.recoveryTarget?.configuration ?? configurationForActiveWorker, error: error)
            throw error
        }
    }
    private func stopAndDrain(_ process: RequestWorkerProcess) async -> Error? {
        process.shutdown()
        do { try await settleProcess(process); return nil } catch { return error }
    }

    private func workerFailure(_ event: RequestWorkerEvent) async -> Error  {
        let failure = event.failureError ?? ShaderRequestError.unavailable("Shader worker failed")
        if event.recoveryRequired == true {
            await holdForRecovery(journal: activeProcess?.recoveryTarget?.directory ?? activeID.map(folder) ?? directory.appendingPathComponent("publication"),
                configuration: activeProcess?.recoveryTarget?.configuration ?? configurationForActiveWorker, error: failure)
        }
        return failure
    }

    private struct WorkerOutcome {
        let attemptID: UUID
        let completion: RequestWorkerEvent
    }
    private func finishWorkerOperation(_ attempt: RequestWorkerOperation, journal: URL) async throws {
        var finished = attempt; finished.phase = .complete
        do { let snapshot = finished; try await journalChange("finish worker operation", in: journal) { try snapshot.save(in: journal) } }
        catch { await appendRecoveryFailure(journal: journal, configuration: activeProcess?.recoveryTarget?.configuration, error: error); throw error }
        let key = RequestPaths.canonical(journal), retained = recovery.entries[key]
        if retained?.disposition != .detach, retained?.configurationRepair == nil, retained?.maintenanceRepair == nil { recovery.entries[key] = nil }
        do { try await persist() }
        catch {
            if recovery.entries[key] == nil { recovery.entries[key] = retained }
            let failure = RequestWorkerEvidenceError(cause: "Cannot finalize worker recovery: " + error.localizedDescription)
            await appendRecoveryFailure(journal: journal, configuration: retained?.configuration, error: failure)
            throw failure
        }
        dirtyJournals.remove(key) // Process settlement and the exact-journal retry were verified under this execution lease.
        refreshReconciliationFailure()
    }
    private func saveOperation(_ operation: RequestWorkerOperation, in journal: URL) async throws {
        try await journalChange("save worker operation", in: journal) { try operation.save(in: journal) }
    }
    @discardableResult
    private func runWorker(mode: String, configuration: ShaderRequestConfiguration, journal: URL, operation: UUID,
                           receive: (RequestWorkerEvent, RequestWorkerProcess, UUID) async throws -> Void) async throws -> WorkerOutcome {
        let journalKey = RequestPaths.canonical(journal)
        defer { activeRetryJournals[journalKey] = nil; refreshReconciliationFailure() }
        var attempt: RequestWorkerOperation
        do {
            try checkExecution(operation)
            try await reconcileWorker(journal)
            try checkExecution(operation)
            attempt = try await journalChange("bind worker operation", in: journal) { try RequestWorkerOperation.begin(mode: mode, configuration: configuration, in: journal, replacingInitialMaintenance: true) }
            if attempt.phase == .retryPending { attempt.phase = .retryRunning; try await saveOperation(attempt, in: journal) }
        } catch {
            if !(error is CancellationError) && !Self.isMetadataBlocker(error) {
                let target = (try? Self.savedConfiguration(in: journal)) ?? (RequestProcessIdentity.evidenceExists(journal.appendingPathComponent("configuration.json")) ? nil : configuration)
                await holdForRecovery(journal: journal, configuration: target, error: error)
            }
            throw error
        }
        while true {
            do {
                try checkExecution(operation)
                if let id = activeID {
                    transitionRecord(id, .launchBinding(operation, attempt.id), execution: operation)
                    try await persist()
                }
                try checkExecution(operation)
            } catch {
                if attempt.phase == .initial, ["preflight", "publication"].contains(mode) { try await finishWorkerOperation(attempt, journal: journal) }
                throw error
            }
            let process = workerProcess()
            if let id = activeID { transitionRecord(id, .launch(operation, true), execution: operation) }
            activeProcess = process
            execution?.processID = ObjectIdentifier(process)
            settledExecutions.remove(operation)
            let attemptID = UUID()
            var completion: RequestWorkerEvent?
            do {
                for try await event in process.run(mode: mode, configuration: configuration, directory: journal, operationID: attempt.id) {
                    try checkExecution(operation)
                    if event.event == "failure" { throw await workerFailure(event) }
                    try await receive(event, process, attemptID)
                    let terminal: Bool
                    switch mode {
                    case "preflight": terminal = event.event == "preflight"
                    case "publication": terminal = event.event == "publicationReady"
                    case "discard": terminal = event.event == "discarded"
                    default: terminal = event.event == "result" || event.event == "clarification"
                    }
                    if terminal { completion = event }
                }
                try await settleProcess(process)
                if completion != nil, let persistenceFailure {
                    var finished = attempt; finished.phase = .complete
                    let snapshot = finished
                    try await journalChange("retain settled worker completion", in: journal) { try snapshot.save(in: journal) }
                    throw MetadataUnavailable(message: persistenceFailure)
                }
                try checkExecution(operation)
                guard let completion else { throw ShaderRequestError.unavailable("Worker ended without the required " + mode + " completion event for this attempt.") }
                try await finishWorkerOperation(attempt, journal: journal)
                return WorkerOutcome(attemptID: attemptID, completion: completion)
            } catch {
                let recorded = process.recordedFailure
                let hostFault = recorded.map(Self.requiresCheckoutRecovery) ?? false
                let error = error is CancellationError || (error is ShaderRequestError && hostFault) ? (recorded ?? error) : error
                let settlementError = await stopAndDrain(process)
                if let fault = error as? RequestWorkerSupervisionError {
                    await appendRecoveryFailure(journal: journal, configuration: configuration, error: fault)
                }
                if let settlementError { throw settlementError }
                if error is CancellationError, attempt.phase == .initial,
                   mode == "preflight" || mode == "publication" {
                    // Settled maintenance cancellation must not bind the next attempt to this configuration.
                    try await finishWorkerOperation(attempt, journal: journal)
                }
                try checkExecution(operation)
                guard let fault = error as? RequestWorkerSupervisionError else {
                    if !Self.requiresCheckoutRecovery(error) && !(error is RequestPersistence.Fault) {
                        try await finishWorkerOperation(attempt, journal: journal)
                    }
                    throw error
                }
                do {
                    try await persistRecovery() // A failed recovery write must prevent automatic relaunch.
                    guard fault.retryable, attempt.phase == .initial else {
                        attempt.phase = .paused; try await saveOperation(attempt, in: journal); throw fault
                    }
                    attempt.phase = .retryPending; try await saveOperation(attempt, in: journal)
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                    try checkExecution(operation)
                    try await reconcileWorker(journal)
                    try checkExecution(operation)
                    attempt.phase = .retryRunning; try await saveOperation(attempt, in: journal)
                    activeRetryJournals[journalKey] = operation; refreshReconciliationFailure()
                    // Keep the original recovery diagnostic until this attempt completes.
                    try await persist()
                    if mode == "run", let id = activeID, records[id]?.status.stage.terminal == false,
                       records[id]?.status.stage != .awaitingActivation, records[id]?.status.stage != .awaitingClarification {
                        try await update(id, stage: .repairing, message: "Retrying preserved work after a supervision failure")
                    }
                } catch {
                    if !(error is CancellationError) { await appendRecoveryFailure(journal: journal, configuration: configuration, error: error) }
                    throw error
                }
            }
        }
    }

    private func checkExecution(_ id: UUID) throws {
        try Task.checkCancellation()
        if let persistenceFailure { throw MetadataUnavailable(message: persistenceFailure) }
        if let startupFinalizationFailure { throw ShaderRequestError.unavailable(startupFinalizationFailure) }
        // A reservation fences unlaunched work, not another TV's running command.
        // Trusted commit interrupts its matching execution explicitly.
        if let activeID, !(activeProcess?.checkoutLaunched ?? (records[activeID]?.dispatch?.launched == true)), let deviceID = records[activeID]?.status.deviceID,
           let blocker = revocationBlocker(for: deviceID) { throw MetadataUnavailable(message: blocker) }
        guard execution?.id == id, execution?.interrupted == false, !suspended else { throw CancellationError() }
    }

    private func preparePublication(_ event: RequestWorkerEvent, process: RequestWorkerProcess, operation: UUID, attempt: UUID) async throws {
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        let prepared: PreparedCatalogPublication
        do {
            prepared = try await catalog.prepare(from: URL(fileURLWithPath: configurationForActiveWorker.repository))
        } catch {
            try checkExecution(operation)
            try process.reply(false, message: error.localizedDescription)
            return
        }
        do {
            try checkExecution(operation)
            if let required = event.requiredPreviewShaderIDs {
                guard required.count <= CatalogLimits.shaderCount, Set(required).count == required.count,
                      required.allSatisfy(ShaderRequest.validID) else { throw ShaderRequestError.invalidRequest }
            }
            let failures = prepared.previewWarnings.filter { event.requiredPreviewShaderIDs?.contains($0.shaderID) ?? true }
            if !failures.isEmpty {
                await catalog.discard(prepared.id)
                try process.reply(false, message: failures.map { "\($0.shaderID): \($0.message)" }.joined(separator: "\n"))
            } else {
                preparedID = prepared.id; preparedAttemptID = attempt
                try process.reply(true)
            }
        } catch { await catalog.discard(prepared.id); throw error }
    }
    private var configurationForActiveWorker: ShaderRequestConfiguration { activeID.flatMap { records[$0]?.configuration } ?? configuration }

    public func allJobs() -> [ShaderRequestStatus] {
        records.values.filter { $0.deletionPending != true }.map(\.status).sorted { $0.createdAt > $1.createdAt }
    }
    public func updates() -> AsyncStream<[ShaderRequestStatus]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(allJobs())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func metadataFiles(rows: [UUID: Record], acknowledgements: [DetachedCheckoutAcknowledgement], store: RequestRecoveryStore) -> [RequestPersistence.File] {
        let values = Array(rows.values)
        return [
            .init(url: directory.appendingPathComponent("recovery.json"), recovery: store, generation: recoveryRevision),
            .init(url: directory.appendingPathComponent("detached-checkouts.json"), value: acknowledgements),
            .init(url: directory.appendingPathComponent("journal.json"), encode: {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return try encoder.encode(values.sorted { $0.status.id.uuidString < $1.status.id.uuidString })
            })]
    }
    @discardableResult private func persist(progress: Bool = false, operation: String = "request metadata", recoveryToken: RequestPersistence.RecoveryToken? = nil) async throws -> UInt64 {
        try await waitForStorageChange(cancellable: false)
        let permit = try admitMetadataMutation()
        let files = metadataFiles(rows: records, acknowledgements: detachedOwners, store: recovery)
        let committedRevision: UInt64
        if progress {
            persistenceRevision &+= 1
            let revision = persistenceRevision; committedRevision = revision
            persistence.enqueueProgress(.init(revision: revision, files: files, operation: operation, metadataPermit: permit), completed: { [weak self] receipt in
                Task { await self?.applyPersistenceReceipt(receipt) }
            }, failed: { [weak self] error in
                Task { await self?.progressPersistenceFailed(error) }
            })
        } else { committedRevision = try await commitFiles(files, operation: operation, recoveryToken: recoveryToken, metadataPermit: permit) }
        emitUpdates()
        return committedRevision
    }
    public func localUpdates() -> AsyncStream<ShaderRequestLocalState> {
        let id = UUID()
        return AsyncStream { continuation in
            localObservers[id] = continuation; continuation.yield(localState())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeLocalObserver(id) } }
        }
    }
    private func removeLocalObserver(_ id: UUID) { localObservers[id] = nil }
    private func localState(jobs: [ShaderRequestStatus]? = nil) -> ShaderRequestLocalState {
        localSnapshots += 1
        return .init(jobs: jobs ?? allJobs(), recoveries: recoveryStatuses(), pendingCleanup: hasPendingCleanup(),
                     canDisableRequests: canDisableRequests(), setup: acceptedSetupSnapshot())
    }
    private func emitUpdates() {
        publishHostRecoveryRequirement()
        scheduleMaintenanceProposals()
        guard !observers.isEmpty || !localObservers.isEmpty else { return }
        let jobs = allJobs()
        for observer in observers.values { observer.yield(jobs) }
        if !localObservers.isEmpty {
            let state = localState(jobs: jobs)
            for observer in localObservers.values { observer.yield(state) }
        }
    }
    private func update(_ id: UUID, stage: ShaderRequestStatus.Stage, message: String, progress: Bool = false) async throws {
        _ = try await appliedRecord(id, .stage(stage, message), execution: activeID == id ? execution?.id : nil)
        let context = "request " + id.uuidString + " stage " + stage.rawValue + " operation " + (execution?.id.uuidString ?? "local")
        try await persist(progress: progress, operation: context)
    }
    public func verify(configuration candidate: ShaderRequestConfiguration) async throws {
        guard !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout maintenance to finish.") }
        try await load()
        guard activeID == nil, !maintenanceBusy, !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true }) else {
            throw ShaderRequestError.unavailable("Finish or cancel queued requests before changing setup.")
        }
        var candidate = candidate
        candidate.repository = RequestPaths.canonical(URL(fileURLWithPath: candidate.repository))
        let operation = Execution()
        let lease = try beginMaintenance(id: operation.id)
        execution = operation
        defer {
            if execution?.id == operation.id { activeProcess = nil; execution = nil }
            endMaintenance(lease)
        }
        try await reconcileWorkers()
        try checkExecution(operation.id)
        guard recovery.entries.isEmpty else { throw ShaderRequestError.unavailable("Retry checkout recovery before changing setup.") }
        let acknowledgements = detachedOwners
        let checkout = candidate
        candidate.detachedOwner = try await Task.detached { try Self.detachedOwner(for: checkout, acknowledgements: acknowledgements) }.value
        candidate.checkoutID = nil
        try checkExecution(operation.id)
        let outcome = try await runWorker(mode: "preflight", configuration: candidate, journal: directory.appendingPathComponent("setup"), operation: operation.id) { _, _, _ in
            try checkExecution(operation.id)
        }
        try checkExecution(operation.id)
        candidate.checkoutID = outcome.completion.checkoutID
        candidate.detachedOwner = nil
        try await retireMaintenanceOperations(replacing: candidate)
        candidate.enabled = true
        let verified = candidate
        try await commitProposal("verify setup") { service in
            try service.checkExecution(operation.id)
            let paths = Self.canonicalRepositories([verified.repository] + service.detachedOwners.map(\.repository))
            let acknowledgements = service.detachedOwners.filter { !Self.matchesDetachedCheckout(verified, acknowledgement: $0, paths: paths) }
            return StorageProposal(configuration: verified, acknowledgements: acknowledgements,
                files: [.init(url: service.directory.appendingPathComponent("preferences.json"), value: verified)])
        }
        if !initialized { initialized = true; schedulingActive = true }
        requiresVerification = false
        setupMessage = "Ready for shader requests"; resolvePublicationFailure(); kick()
    }
    public func canDisableRequests() -> Bool {
        initialized && pendingCommits == 0 && storageCommit == nil && activeID == nil && !maintenanceBusy && !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true })
    }
    public func disable() async throws {
        try await commitProposal("disable requests") { service in
            guard service.canDisableRequestsIgnoringCommit else { throw ShaderRequestError.unavailable("Requests are still in progress.") }
            var accepted = service.configuration; accepted.enabled = false
            return StorageProposal(configuration: accepted, files: [.init(url: service.directory.appendingPathComponent("preferences.json"), value: accepted)])
        }
        setupMessage = "Shader requests are disabled."; cancelPublicationRequests()
    }
    private var canDisableRequestsIgnoringCommit: Bool {
        initialized && pendingCommits == 0 && activeID == nil && !maintenanceBusy && !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true })
    }
    public func cancelQueued(_ id: UUID) async throws {
        try await commitProposal("cancel request") { service in
            guard var record = service.records[id], record.status.stage == .queued, service.activeID != id else {
                throw ShaderRequestError.unavailable("Only queued requests can be cancelled.")
            }
            Self.setStatus(&record, stage: .cancelled, message: "Cancelled on the Mac")
            return StorageProposal(records: [id: record])
        }
        kick()
    }
    public func deleteFinished(_ id: UUID) async throws {
        try await commitProposal("delete record") { service in
            guard !service.recovery.entries.values.contains(where: { $0.configurationRepair?.requestIDs.contains(id) == true }) else { throw ShaderRequestError.unavailable("Finish the pending configuration repair before deleting this record.") }
            guard !service.recovery.entries.values.contains(where: { $0.requestID == id }), !Self.hasProcessEvidence(service.folder(id)),
                  var record = service.records[id], record.status.stage.terminal, record.cleanupPending != true, service.activeID != id else { throw ShaderRequestError.invalidRequest }
            record.deletionPending = true
            return StorageProposal(records: [id: record])
        }
        await finishDeletion(id)
    }
    private func finishDeletion(_ id: UUID) async {
        guard let permit = try? admitMetadataMutation() else { return }
        guard records[id]?.deletionPending == true else { return }
        let tombstone = records[id]
        do {
            guard activeID != id, records[id]?.status.stage.terminal == true, !Self.hasProcessEvidence(folder(id)),
                  !recovery.entries.values.contains(where: { $0.requestID == id || $0.configurationRepair?.requestIDs.contains(id) == true }) else {
                throw RequestWorkerOwnershipError()
            }
            let job = folder(id), remove = removeRecordDirectory
            try await persistence.mutate(metadataPermit: permit) { if RequestProcessIdentity.evidenceExists(job) { try remove(job) } }
            try await waitForStorageChange(cancellable: false)
            records[id] = nil
            try await persist(operation: "finish accepted record deletion")
        } catch {
            try? await waitForStorageChange(cancellable: false)
            records[id] = tombstone; records[id]?.deletionFailure = error.localizedDescription
            if !(error is RequestPersistence.Fault) { _ = try? await persist() }
            emitUpdates()
        }
    }
    public func revoke(_ deviceID: String) async throws {
        try await load()
        try admitMetadataMutation()
        if let activeID, records[activeID]?.status.deviceID == deviceID { execution?.interrupted = true; activeProcess?.stop() }
        // Revocation is an independently accepted trusted fact. Wait for prior
        // submissions, then keep its cancellation state even if the writer is faulted.
        try await waitForStorageChange(cancellable: false)
        let permit = try admitMetadataMutation()
        storageCommit = UUID(); defer { releaseStorageCommit() }
        var changed = false
        for (id, var record) in records where record.status.deviceID == deviceID && record.deletionPending != true {
            let previous = record
            Self.markRevoked(&record, active: activeID == id)
            if record != previous { records[id] = record; changed = true }
        }
        if changed {
            let files = metadataFiles(rows: records, acknowledgements: detachedOwners, store: recovery)
            try await commitFiles(files, operation: "revoke requests from TV " + deviceID, metadataPermit: permit)
        } else if let persistenceFailure {
            // A no-op cannot acknowledge trusted replay while accepted metadata is
            // still waiting for explicit storage convergence.
            throw persistenceFault as Error? ?? MetadataUnavailable(message: persistenceFailure)
        }
        kick()
    }
    private static func markRevoked(_ record: inout Record, active: Bool) {
        guard !record.status.stage.terminal else { return }
        record.revoked = true
        if !active {
            if record.status.stage == .queued { Self.setStatus(&record, stage: .cancelled, message: "TV access was revoked") }
            else {
                record.cleanupPending = true; record.cleanupMessage = "TV access was revoked; any pushed commit remains"
                Self.setStatus(&record, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
            }
        }
    }

    private func acceptedPerformanceID(_ request: ShaderRequest, deviceID: String) -> UUID? {
        guard request.purpose == .performance else { return nil }
        return records.values.first {
            $0.status.deviceID == deviceID && !$0.status.stage.terminal && $0.status.request.purpose == .performance &&
            $0.status.request.context.shaderID == request.context.shaderID && $0.status.request.context.sourceHash == request.context.sourceHash
        }?.status.id
    }

    public func control(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        try await performControl(operation: operation, payload: payload, deviceID: deviceID, authorization: nil)
    }
    func control(operation: String, payload: ShaderRequestControl, deviceID: String, authorization: TrustedRequestAuthorization) async throws -> ShaderRequestControlReply {
        try await performControl(operation: operation, payload: payload, deviceID: deviceID, authorization: authorization)
    }
    private func checkControlAdmission(deviceID: String, scope: ControlScope, coordinator: UUID?, authorization: TrustedRequestAuthorization?) throws {
        guard controlScopes[deviceID]?.id == scope.id, coordinator == revocationCoordinatorID,
              authorization.map({ $0.coordinator == revocationCoordinatorID && $0.deviceID == deviceID && $0.isCurrent }) ?? true else {
            throw ShaderRequestError.unavailable("TV access changed before this request was accepted. Reconnect before submitting again.")
        }
    }
    private func performControl(operation: String, payload: ShaderRequestControl, deviceID: String, authorization: TrustedRequestAuthorization?) async throws -> ShaderRequestControlReply {
        if operation == "requestStatus" {
            try await load()
            return try await reply(deviceID: deviceID, requestID: payload.request?.id ?? payload.requestID)
        }
        var scope = controlScopes[deviceID] ?? ControlScope()
        let coordinator = revocationCoordinatorID
        scope.users += 1; controlScopes[deviceID] = scope
        defer {
            if controlScopes[deviceID]?.id == scope.id {
                controlScopes[deviceID]?.users -= 1
                if controlScopes[deviceID]?.users == 0 { controlScopes[deviceID] = nil }
            }
        }
        try await load()
        if ["requestSubmit", "requestAnswer", "requestActivated", "requestDelivery"].contains(operation) {
            // Only already accepted records can take this path. A duplicate of an
            // in-flight submission still waits for its original commit's outcome.
            try checkControlAdmission(deviceID: deviceID, scope: scope, coordinator: coordinator, authorization: authorization)
            let candidateID = payload.request?.id ?? payload.requestID
            let canInspect = candidateID.flatMap { records[$0] } != nil ||
                (operation == "requestSubmit" && payload.request.flatMap { acceptedPerformanceID($0, deviceID: deviceID) } != nil)
            let unchanged: Bool
            if canInspect {
                let proposal = try controlProposal(operation: operation, payload: payload, deviceID: deviceID)
                unchanged = proposal.files.isEmpty && proposal.configuration == nil && proposal.acknowledgements == nil && proposal.records.allSatisfy { records[$0.key] == $0.value }
            } else { unchanged = false }
            if !unchanged {
                try await commitProposal(operation) { service in
                    try service.checkControlAdmission(deviceID: deviceID, scope: scope, coordinator: coordinator, authorization: authorization)
                    return try service.controlProposal(operation: operation, payload: payload, deviceID: deviceID)
                }
            }
            kick()
        }
        var responseID = payload.request?.id ?? payload.requestID
        if operation == "requestSubmit", let request = payload.request, request.purpose == .performance, records[request.id] == nil {
            responseID = acceptedPerformanceID(request, deviceID: deviceID)
        }
        return try await reply(deviceID: deviceID, requestID: responseID)
    }
    private static func setStatus(_ record: inout Record, stage: ShaderRequestStatus.Stage, message: String) {
        record.status.stage = stage; record.status.message = message
        record.status.updatedAt = Date(); record.status.sequence &+= 1
    }
    private func controlProposal(operation: String, payload: ShaderRequestControl, deviceID: String) throws -> StorageProposal {
        if let blocker = revocationBlocker(for: deviceID) { throw ShaderRequestError.unavailable(blocker) }
        if operation == "requestSubmit" {
            guard configuration.enabled else { throw ShaderRequestError.unavailable(setupMessage) }
            if let blocker = requestAcceptanceBlocker { throw ShaderRequestError.unavailable(blocker) }
            guard let request = payload.request else { throw ShaderRequestError.invalidRequest }
            try request.validate()
            if let existing = records[request.id] {
                guard existing.status.deviceID == deviceID else { throw ShaderRequestError.notFound }
                let original = try JSONDecoder().decode(ShaderRequest.self, from: Data(contentsOf: folder(request.id).appendingPathComponent("request.json")))
                guard original == request else { throw ShaderRequestError.invalidRequest }
                return StorageProposal()
            }
            if acceptedPerformanceID(request, deviceID: deviceID) != nil { return StorageProposal() }
            if request.purpose == .creative, records.values.contains(where: { $0.status.deviceID == deviceID && $0.status.blocksBrowsing }) {
                throw ShaderRequestError.unavailable("This TV already has a manual request in progress.")
            }
            var lightweight = request; lightweight.context.source = ""; lightweight.context.screenshot = Data()
            let record = Record(status: ShaderRequestStatus(request: lightweight, deviceID: deviceID), configuration: configuration)
            return StorageProposal(records: [request.id: record], files: [.init(url: folder(request.id).appendingPathComponent("request.json"), value: request)])
        }
        guard let id = payload.requestID, var record = records[id], record.deletionPending != true, record.status.deviceID == deviceID, !record.revoked else { throw ShaderRequestError.notFound }
        var files: [RequestPersistence.File] = []
        if operation == "requestDelivery" {
            guard let nonce = payload.answer, UUID(uuidString: nonce) != nil else { throw ShaderRequestError.invalidRequest }
            if record.status.stage == .awaitingActivation, record.deliveryNonce != nonce {
                record.deliveryNonce = nonce
                Self.setStatus(&record, stage: .queued, message: "Refreshing latest committed result for this TV")
            }
        } else if operation == "requestAnswer" {
            guard record.status.stage == .awaitingClarification, let answer = payload.answer,
                  !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 16_384 else { throw ShaderRequestError.invalidRequest }
            files.append(.init(url: folder(id).appendingPathComponent("answer.json"), value: answer))
            record.status.clarification = nil
            Self.setStatus(&record, stage: .queued, message: "Ready to continue after clarification")
        } else if record.status.stage == .awaitingActivation {
            if let diagnostic = payload.diagnostic {
                guard diagnostic.utf8.count <= 16_384 else { throw ShaderRequestError.invalidRequest }
                files.append(.init(url: folder(id).appendingPathComponent("repair.json"), value: ["attemptID": UUID().uuidString, "shaderID": record.status.result?.shaderID ?? "", "diagnostic": diagnostic]))
                Self.setStatus(&record, stage: .repairing, message: "Repairing the TV activation error")
            } else {
                guard (record.status.request.purpose == .performance && payload.sourceHash == nil) ||
                      (payload.sourceHash.map({ CatalogHash.isSHA($0) }) == true && payload.sourceHash == record.status.result?.deliveredSourceHash) else { throw ShaderRequestError.invalidRequest }
                record.status.result?.deliveredSourceHash = payload.sourceHash
                Self.setStatus(&record, stage: .completed, message: record.status.result?.summary ?? "Request completed")
            }
        }
        return StorageProposal(records: [id: record], files: files)
    }
    private func reply(deviceID: String, requestID: UUID?) async throws -> ShaderRequestControlReply {
        let owned = allJobs().filter { $0.deviceID == deviceID }
        let jobs = requestID.map { id in owned.filter { $0.id == id } } ?? owned.filter { !$0.stage.terminal }
        let blocker = requestAcceptanceBlocker ?? revocationBlocker(for: deviceID)
        return ShaderRequestControlReply(enabled: configurationValue().enabled && blocker == nil,
                                        message: blocker ?? (configuration.enabled ? "Ready for shader requests" : setupMessage), jobs: jobs,
                                        publicationRevision: await catalog.publicationRevisionValue())
    }
    private func kick() {
        if let startupFinalizationFailure { failPendingPublicationForRecovery(startupFinalizationFailure); return }
        if let persistenceFailure { failPendingPublicationForRecovery(persistenceFailure); return }
        if let reconciliationFailure { failPendingPublicationForRecovery(reconciliationFailure); return }
        if let entry = recovery.entries.values.sorted(by: { $0.journal < $1.journal }).first { failPendingPublicationForRecovery(entry.message); return }
        guard hostOwners.mayDispatch else { pauseOwnerlessPublication(); return }
        guard loaded, initialized, !suspended, !maintenanceBusy, activeID == nil, workerTask == nil else { return }
        if storageCommit != nil || pendingCommits != 0 || !pendingRetirements.isEmpty || retirementTask != nil { schedulingDeferred = true; return }
        if !reconciled {
            guard reconciliationKickID == nil, reconciliationTask == nil else { return }
            if let reconciliationFailure { failPendingPublicationForRecovery(reconciliationFailure); return }
            let id = UUID(); reconciliationKickID = id
            Task {
                do {
                    try await reconcileWorkers()
                    guard reconciliationKickID == id else { return }
                    reconciliationKickID = nil; kick()
                } catch {
                    guard reconciliationKickID == id else { return }
                    reconciliationKickID = nil
                    if let reconciliationFailure { failPendingPublicationForRecovery(reconciliationFailure) }
                }
            }
            return
        }
        if let entry = recovery.entries.values.first { failPendingPublicationForRecovery(entry.message); return }
        let eligible = records.values.filter { !$0.revoked && $0.detached != true && revocationBlocker(for: $0.status.deviceID) == nil }.map(\.status)
        if let recoveryID, let failure = records[recoveryID]?.cleanupFailure {
            failPendingPublicationForRecovery(failure); return
        }
        let ownerCleanup = recoveryID.flatMap { records[$0]?.cleanupPending == true ? $0 : nil }
        let cleanupID = ownerCleanup ?? records.values.filter { $0.cleanupPending == true && $0.cleanupFailure == nil }.sorted { $0.status.createdAt < $1.status.createdAt }.first?.status.id
        let interrupted = recoveryID.flatMap { id -> UUID? in
            guard configuration.enabled, schedulingActive || pendingPublication != nil || retryPublicationForce != nil,
                  let value = records[id], !value.revoked, value.detached != true, revocationBlocker(for: value.status.deviceID) == nil,
                  value.cleanupPending != true, value.status.stage == .repairing || value.status.stage == .queued else { return nil }
            return id
        }
        let work: ScheduledWork
        if let interrupted { work = .execute(interrupted) }
        else if let cleanupID { work = .cleanup(cleanupID) }
        else if hasPendingCleanup() {
            let failure = records.values.first { $0.cleanupPending == true && $0.cleanupFailure != nil }?.cleanupFailure
            failPendingPublicationForRecovery(failure ?? "Checkout cleanup is required."); return
        }
        else if let revocationCheckoutBlocker { failPendingPublicationForRecovery(revocationCheckoutBlocker); return }
        else if pendingPublication != nil || (retryPublicationForce != nil && configuration.enabled) { work = .publication }
        else if schedulingActive, configuration.enabled, let id = ShaderRequestScheduling.next(in: eligible, recoveringID: recoveryID) { work = .execute(id) }
        else { return }
        let operation = Execution(); execution = operation
        if case .publication = work {
            if let force = retryPublicationForce, configuration.enabled {
                var request = pendingPublication ?? PublicationRequest(force: force, waiters: [])
                request.force = request.force || force; request.ownsRetry = true
                pendingPublication = request; retryPublicationForce = nil
            }
            guard (try? beginMaintenance(id: operation.id)) != nil else { execution = nil; return }
            activePublication = pendingPublication; pendingPublication = nil
            _ = publicationState(.preparing)
            workerTask = Task { [weak self] in await self?.runPublication(operation: operation.id) }
            return
        }
        let id: UUID
        switch work { case .execute(let job), .cleanup(let job): id = job; case .publication: return }
        activeID = id
        workerTask = Task { [weak self] in await self?.runScheduledWork(id: id, operation: operation.id, work: work) }
    }
    private func runScheduledWork(id: UUID, operation: UUID, work: ScheduledWork) async {
        do {
            try checkExecution(operation)
            try await commitProposal("dispatch request") { service in
                try service.checkExecution(operation)
                guard var record = service.records[id] else { throw ShaderRequestError.notFound }
                record.executionID = operation; record.interrupted = false
                record.dispatch = DispatchState(executionID: operation, priorStage: record.status.stage)
                if case .execute = work { Self.setStatus(&record, stage: .implementing, message: "Preparing the managed checkout") }
                return StorageProposal(records: [id: record], files: [.init(url: service.directory.appendingPathComponent("active.json"), value: id)])
            }
            try checkExecution(operation)
            switch work {
            case .cleanup(let id): await cleanup(id, operation: operation)
            case .execute(let id): await execute(id, operation: operation)
            case .publication: break
            }
        } catch {
            if !(error is CancellationError) && !Self.isMetadataBlocker(error) {
                await holdForRecovery(journal: folder(id), configuration: records[id]?.configuration, error: error)
            }
            finishWorker(id)
        }
    }

    private static func isMetadataBlocker(_ error: Error) -> Bool {
        error is MetadataUnavailable || error is RequestPersistence.MetadataAdmission.Unavailable || error is RequestPersistence.Fault || error is RequestPersistence.ValidationError
    }
    private static func requiresCheckoutRecovery(_ error: Error) -> Bool {
        error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError || error is RequestWorkerTeardownError || error is RequestWorkerSupervisionError
    }
    private func cleanup(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { finishWorker(id); return }
        await prepareCleanup()
        do {
            try checkExecution(operation)
            let job = folder(id)
            try await runWorker(mode: "discard", configuration: record.configuration, journal: job, operation: operation) { _, _, _ in
                try checkExecution(operation)
            }
            try checkExecution(operation)
            _ = try await appliedRecord(id, .cleanupComplete, execution: operation)
            try await persist()
        } catch {
            if Self.isMetadataBlocker(error) {
                // Storage recovery retains the cleanup intent and resumes it after convergence.
            } else if Self.requiresCheckoutRecovery(error) {
                await holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            } else if execution?.interrupted == false, records[id]?.detached != true {
                transitionRecord(id, .cleanupFailure(error.localizedDescription), execution: operation)
                setupMessage = "Checkout recovery is required. Correct the saved folder/tool paths and retry cleanup, or detach the checkout."
                try? await update(id, stage: .failed, message: "Cleanup failed: \(error.localizedDescription). \(setupMessage)")
            }
        }
        finishWorker(id)
    }
    private func finishWorker(_ id: UUID) {
        let interrupted = execution?.interrupted == true, operation = execution?.id
        let settled = operation.map { settledExecutions.remove($0) != nil } ?? false
        activeProcess = nil; activeID = nil; workerTask = nil; execution = nil
        if let operation { transitionRecord(id, .finish(operation, interrupted: interrupted, settled: settled)) }
        emitUpdates()
    }
    private func finishRetirementTask() { retirementTask = nil; emitUpdates(); kick() }
    private func retirePendingWorkers(recoveryToken: RequestPersistence.RecoveryToken? = nil) async throws {
        try admitMetadataMutation()
        for (id, operation) in pendingRetirements.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard records[id]?.dispatch?.executionID == operation || records[id]?.dispatch == nil else { continue }
            let job = folder(id)
            if !verifiedRetirements.contains(operation) {
                do { try await reconcileWorker(job); verifiedRetirements.insert(operation) }
                catch { await holdForRecovery(journal: job, configuration: records[id]?.configuration, error: error); throw error }
            }
            // The bound complete operation (or a prepared, never-launched dispatch)
            // already supplies durable restart evidence before marker retirement.
            let marker = directory.appendingPathComponent("active.json")
            do {
                try await persistence.journal("retire settled worker", files: [marker], metadataPermit: try admitMetadataMutation()) {
                    if RequestProcessIdentity.evidenceExists(marker) {
                        let bytes = try BoundedCatalogReader(root: marker.deletingLastPathComponent()).read(marker.lastPathComponent, limit: 4096).bytes
                        if try JSONDecoder().decode(UUID.self, from: bytes) == id { try RequestJournalWriter.remove(marker) }
                    }
                }
            } catch {
                if !Self.isMetadataBlocker(error) {
                    await holdForRecovery(journal: job, configuration: records[id]?.configuration,
                        error: RequestWorkerEvidenceError(cause: "Cannot retire active marker at " + marker.path + ": " + error.localizedDescription))
                }
                throw error
            }
            _ = try await appliedRecord(id, .retired(operation))
            try await persist(recoveryToken: recoveryToken)
            pendingRetirements[id] = nil; verifiedRetirements.remove(operation)
        }
    }
    private func execute(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { finishWorker(id); return }
        var deliveredCommits: Set<String> = []
        do {
            try checkExecution(operation)
            let job = folder(id)
            try await runWorker(mode: "run", configuration: record.configuration, journal: job, operation: operation) { event, process, attempt in
                try checkExecution(operation)
                switch event.event {
                case "stage":
                    if let value = event.stage, let stage = ShaderRequestStatus.Stage(rawValue: value) {
                        try await update(id, stage: stage, message: event.message ?? value, progress: true)
                    }
                case "preparePublication":
                    try await preparePublication(event, process: process, operation: operation, attempt: attempt)
                case "discardPublication":
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                case "clarification":
                    _ = try await appliedRecord(id, .clarification(ShaderClarification(question: event.question ?? "Please clarify the request", options: event.options ?? [])), execution: operation)
                    try await persist()
                case "result":
                    if let result = event.result, let commit = result.commitSHA, deliveredCommits.contains(commit),
                       records[id]?.status.result?.commitSHA == commit, records[id]?.status.result?.shaderID == result.shaderID {
                        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                        return
                    }
                    guard let result = event.result, ShaderRequest.validID(result.shaderID), let preparedID, preparedAttemptID == attempt else {
                        throw ShaderRequestError.invalidRequest
                    }
                    try await update(id, stage: .publishing, message: "Installing the committed library")
                    let publication = try await catalog.install(preparedID)
                    self.preparedID = nil
                    published(publication)
                    _ = try await appliedRecord(id, .result(result), execution: operation)
                    if let commit = result.commitSHA { deliveredCommits.insert(commit) }
                    if records[id]?.revoked == true {
                        try await update(id, stage: .failed, message: "Pushed successfully; TV access was revoked")
                        return
                    }
                    guard let output = publication.catalog.shaders.first(where: { $0.id == result.shaderID }) else {
                        try await writeFile(to: job.appendingPathComponent("repair.json")) { service in
                            try service.checkExecution(operation)
                            return try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": result.shaderID, "diagnostic": "The committed output was removed before TV delivery. Recreate it under a fresh unused ID."]) }
                        try await update(id, stage: .repairing, message: "Recreating the output removed before delivery")
                        return
                    }
                    transitionRecord(id, .deliveredHash(output.sourceHash), execution: operation)
                    try await update(id, stage: records[id]?.revoked == true ? .failed : .awaitingActivation,
                               message: records[id]?.revoked == true ? "Pushed successfully; TV access was revoked" : "Waiting for the TV to play the result")
                default: break
                }
            }
            try checkExecution(operation)
        } catch {
            if Self.isMetadataBlocker(error), !(error is RequestPersistence.Fault) {
                transitionRecord(id, .metadataPause(operation), execution: operation)
            } else if error is RequestPersistence.Fault, records[id]?.dispatch?.launched != true {
                // No gate was opened: storage recovery owns this rejected dispatch.
            } else if Self.requiresCheckoutRecovery(error) || error is RequestPersistence.Fault {
                await holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            } else if execution?.interrupted == false, records[id]?.detached != true {
                transitionRecord(id, .cleanupPending(error.localizedDescription), execution: operation)
                try? await update(id, stage: .failed, message: error.localizedDescription)
            }
        }
        if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
            transitionRecord(id, .cleanupPending("TV access was revoked; any pushed commit remains"), execution: operation)
            try? await update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
        }
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        finishWorker(id)
    }
    public func suspend() async {
        suspended = true; execution?.interrupted = true; activeProcess?.stop()
        if let id = activeID {
            transitionRecord(id, .interrupted)
            if records[id]?.status.stage.terminal == false {
                try? await update(id, stage: .repairing, message: "Waiting for the Mac to resume")
            } else { _ = try? await persist() }
        }
        activeProcess?.stop()
    }
    public func resume() { suspended = false; kick() }

    nonisolated private static func canonicalRepositories(_ repositories: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Set(repositories).map { ($0, $0.isEmpty ? "" : RequestPaths.canonical(URL(fileURLWithPath: $0))) })
    }
    nonisolated private static func savedConfiguration(in journal: URL) throws -> ShaderRequestConfiguration? {
        guard RequestProcessIdentity.evidenceExists(journal.appendingPathComponent("configuration.json")) else { return nil }
        return try JSONDecoder().decode(ShaderRequestConfiguration.self,
            from: BoundedCatalogReader(root: journal).read("configuration.json", limit: CatalogLimits.headBytes).bytes)
    }
    nonisolated private static func samePublicationCheckout(_ lhs: ShaderRequestConfiguration, _ rhs: ShaderRequestConfiguration, paths: [String: String] = [:]) -> Bool {
        sameCheckout(lhs, repository: rhs.repository, checkoutID: rhs.checkoutID, paths: paths)
    }
    nonisolated private static func matchesDetachedCheckout(_ configuration: ShaderRequestConfiguration,
        acknowledgement: DetachedCheckoutAcknowledgement, paths: [String: String] = [:]) -> Bool {
        sameCheckout(configuration, repository: acknowledgement.repository, checkoutID: acknowledgement.checkoutID, paths: paths)
    }
    nonisolated private static func sameCheckout(_ configuration: ShaderRequestConfiguration, repository: String, checkoutID: String?, paths: [String: String] = [:]) -> Bool {
        if configuration.repository.isEmpty || repository.isEmpty { return configuration.repository == repository }
        let candidate = paths[configuration.repository] ?? RequestPaths.canonical(URL(fileURLWithPath: configuration.repository))
        let expected = paths[repository] ?? RequestPaths.canonical(URL(fileURLWithPath: repository))
        guard candidate == expected else { return false }
        if let identity = configuration.checkoutID, let checkoutID { return identity == checkoutID }
        return true
    }
    nonisolated private static func acknowledgement(id: UUID, job: URL, configuration: ShaderRequestConfiguration) -> DetachedCheckoutAcknowledgement {
        DetachedCheckoutAcknowledgement(requestID: id, directory: RequestPaths.canonical(job),
            repository: RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)), checkoutID: configuration.checkoutID)
    }
    nonisolated private static func detachedOwner(for configuration: ShaderRequestConfiguration, acknowledgements: [DetachedCheckoutAcknowledgement]) throws -> DetachedCheckoutAcknowledgement? {
        guard !acknowledgements.isEmpty else { return nil }
        let gitdir = try gitDirectory(configuration)
        guard let marker = try readOwner(in: gitdir) else { return nil }
        let identity = (try? String(contentsOf: gitdir.appendingPathComponent("holodeck-checkout-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = canonicalRepositories([configuration.repository] + acknowledgements.map(\.repository))
        return acknowledgements.first {
            guard $0.requestID == marker.id, RequestPaths.canonical(URL(fileURLWithPath: $0.directory)) == marker.directory else { return false }
            var checkout = configuration; checkout.checkoutID = identity
            return matchesDetachedCheckout(checkout, acknowledgement: $0, paths: paths)
        }
    }

    nonisolated private struct OwnerMarker: Decodable {
        let id: UUID
        var directory: String
    }
    nonisolated private static func readOwner(in gitdir: URL) throws -> OwnerMarker? {
        guard FileManager.default.fileExists(atPath: gitdir.appendingPathComponent("holodeck-request-owner.json").path) else { return nil }
        do {
            var owner = try JSONDecoder().decode(OwnerMarker.self, from: BoundedCatalogReader(root: gitdir).read("holodeck-request-owner.json", limit: CatalogLimits.headBytes).bytes)
            guard owner.directory.hasPrefix("/") else { throw ShaderRequestError.invalidRequest }
            owner.directory = RequestPaths.canonical(URL(fileURLWithPath: owner.directory))
            return owner
        } catch { throw ShaderRequestError.unavailable("Checkout ownership marker is unreadable. Repair it or explicitly detach the checkout while retaining evidence.") }
    }
    nonisolated private static func ownerMarker(_ configuration: ShaderRequestConfiguration) throws -> OwnerMarker? {
        guard FileManager.default.fileExists(atPath: configuration.repository) else { return nil }
        return try readOwner(in: gitDirectory(configuration))
    }

    nonisolated private static func gitDirectory(_ configuration: ShaderRequestConfiguration) throws -> URL {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.git)
        process.arguments = ["rev-parse", "--absolute-git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.repository)
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ShaderRequestError.unavailable(String(decoding: error, as: UTF8.self)) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func validateMaintenanceRecoveryCheckout(_ configuration: ShaderRequestConfiguration) throws {
        let gitdir = try gitDirectory(configuration)
        let identity = (try? String(contentsOf: gitdir.appendingPathComponent("holodeck-checkout-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.checkoutID == nil || configuration.checkoutID == identity else { throw RequestWorkerOwnershipError() }
        if let owner = try readOwner(in: gitdir) {
            guard let acknowledgement = configuration.detachedOwner,
                  acknowledgement.requestID == owner.id,
                  RequestPaths.canonical(URL(fileURLWithPath: acknowledgement.directory)) == owner.directory,
                  matchesDetachedCheckout(configuration, acknowledgement: acknowledgement),
                  acknowledgement.checkoutID == nil || acknowledgement.checkoutID == identity else { throw RequestWorkerOwnershipError() }
        }
    }

    nonisolated private static func validateRecoveryCheckout(_ configuration: ShaderRequestConfiguration, id: UUID, job: URL) throws {
        let gitdir = try gitDirectory(configuration)
        let owner = try readOwner(in: gitdir)
        let identity = (try? String(contentsOf: gitdir.appendingPathComponent("holodeck-checkout-id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let owned = owner?.id == id && owner?.directory == RequestPaths.canonical(job)
        let sameCheckout = configuration.checkoutID != nil && identity == configuration.checkoutID
        guard owned || sameCheckout, owner == nil || owned else {
            throw ShaderRequestError.unavailable("Selected checkout does not belong to this request. Locate its owned checkout or detach it without deleting files.")
        }
    }

}
#endif
