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
}

public enum ShaderCheckoutDetachTarget: Sendable {
    case request(UUID)
    case recovery(UUID)
    case selectedCheckout
}

public struct ShaderRequestRecoveryStatus: Sendable, Identifiable {
    public enum Kind: Sendable { case cleanup, reconciliation }
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

public actor ShaderRequestService {
    private struct Record: Codable, Sendable {
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
    }
    private let directory: URL
    private let catalog: DirectoryCatalog
    private let workerScript: URL?
    private var recovery = RequestRecoveryStore()
    private let waitForWorker: @Sendable (RequestWorkerProcess) async throws -> Void
    private let reconcileWorker: @Sendable (URL) async throws -> Void
    private let recoveryWriter: @Sendable (Data, URL) throws -> Void
    private let prepareCleanup: @Sendable () async -> Void
    private var configuration = ShaderRequestConfiguration()
    private var records: [UUID: Record] = [:]
    private var observers: [UUID: AsyncStream<[ShaderRequestStatus]>.Continuation] = [:]
    private var activeID: UUID?
    private var activeProcess: RequestWorkerProcess?
    private var workerTask: Task<Void, Never>?
    private var preparedID: UUID?
    private struct Execution { let id = UUID(); var interrupted = false }
    private var execution: Execution?
    private var selectingRepository = false
    private var maintenanceLease: UUID?
    private var detaching = false
    private var maintenanceWaiters: [CheckedContinuation<Void, Never>] = []
    private var maintenanceBusy: Bool { maintenanceLease != nil || detaching }
    private struct ReconciliationResult: Sendable { var owner: UUID?; var acknowledgements: [DetachedCheckoutAcknowledgement] }
    private struct ReconciliationAttempt { let id = UUID(); let task: Task<ReconciliationResult, Error> }
    private var reconciliationTask: ReconciliationAttempt?
    private var reconciled = false
    private var reconciliationKickID: UUID?
    private var reconciliationFailure: String?
    private var reconciliationJournal: URL?
    private var reconciliationConfiguration: ShaderRequestConfiguration?
    private struct ReconciliationError: LocalizedError {
        let journal: URL; let configuration: ShaderRequestConfiguration?; let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }
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
    private var initialized = false
    private var detachedOwners: [DetachedCheckoutAcknowledgement] = []
    private var suspended = false
    private var loaded = false
    private var recoveryID: UUID?
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory; self.workerScript = nil
        self.waitForWorker = { try await $0.waitForExit() }
        self.reconcileWorker = { try RequestWorkerProcess.reconcileOrphan(in: $0) }
        self.recoveryWriter = { try $0.write(to: $1, options: .atomic) }
        self.prepareCleanup = {}
    }
    init(catalog: DirectoryCatalog, directory: URL, workerScript: URL,
         reconcileWorker: @escaping @Sendable (URL) async throws -> Void = { try RequestWorkerProcess.reconcileOrphan(in: $0) },
         waitForWorker: @escaping @Sendable (RequestWorkerProcess) async throws -> Void = { try await $0.waitForExit() },
         recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         prepareCleanup: @escaping @Sendable () async -> Void = {}) {
        self.catalog = catalog; self.directory = directory; self.workerScript = workerScript
        self.reconcileWorker = reconcileWorker; self.waitForWorker = waitForWorker; self.recoveryWriter = recoveryWriter
        self.prepareCleanup = prepareCleanup
    }
    private func workerProcess() -> RequestWorkerProcess { RequestWorkerProcess(script: workerScript) }

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

    public func start(configuration: ShaderRequestConfiguration) throws {
        try initialize(configuration: configuration)
        activateScheduling()
    }
    public func initialize(configuration: ShaderRequestConfiguration) throws {
        try load()
        guard !selectingRepository else { throw ShaderRequestError.unavailable("Wait for the selected folder to finish loading.") }
        let previous = self.configuration
        let preferences = directory.appendingPathComponent("preferences.json")
        self.configuration = (try? Data(contentsOf: preferences)).flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0) } ?? configuration
        if !configuration.shaderTool.isEmpty { self.configuration.shaderTool = configuration.shaderTool }
        let paths = Self.canonicalRepositories([previous.repository, self.configuration.repository] + detachedOwners.map(\.repository))
        if detachedOwners.contains(where: {
            Self.matchesDetachedCheckout(self.configuration, acknowledgement: $0, paths: paths)
        }) {
            self.configuration.enabled = false
        }
        if initialized, !Self.samePublicationCheckout(previous, self.configuration, paths: paths) {
            cancelPublicationRequests()
            publicationGeneration = UUID(); unresolvedPublicationFailure = nil; emitPublication()
        }
        if !self.configuration.enabled { cancelPublicationRequests() }
        initialized = true
        setupMessage = self.configuration.enabled ? "Ready for shader requests" : "Enable shader requests in Mac Settings."
    }
    public func activateScheduling() { schedulingActive = true; kick() }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        let acknowledgements = directory.appendingPathComponent("detached-checkouts.json")
        let hasAcknowledgements = FileManager.default.fileExists(atPath: acknowledgements.path)
        if hasAcknowledgements { detachedOwners = try JSONDecoder().decode([DetachedCheckoutAcknowledgement].self, from: Data(contentsOf: acknowledgements)) }
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
            records = Dictionary(uniqueKeysWithValues: saved.map { ($0.status.id, $0) })
            let active = directory.appendingPathComponent("active.json")
            if let bytes = try? Data(contentsOf: active), let id = try? JSONDecoder().decode(UUID.self, from: bytes),
               let stage = records[id]?.status.stage, (!stage.terminal || records[id]?.cleanupPending == true), stage != .awaitingActivation, stage != .awaitingClarification {
                recoveryID = id
                if !stage.terminal {
                    records[id]?.status.stage = .repairing
                    records[id]?.status.message = "Recovering interrupted request"
                }
            }
        }
        for id in records.keys {
            if detachedOwners.contains(where: { $0.requestID == id }) {
                records[id]?.detached = true; records[id]?.cleanupPending = false
                if records[id]?.status.stage.terminal == false {
                    records[id]?.status.stage = .failed
                    records[id]?.status.message = "Checkout detached; unpublished files and evidence were retained"
                }
            }
            if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                records[id]?.status.stage = .failed
                records[id]?.status.message = "TV access was revoked; checkout cleanup is pending"
            }
            // A restart makes one new recovery attempt after the operator can repair the host.
            records[id]?.cleanupFailure = nil
        }
        let sidecar = directory.appendingPathComponent("recovery.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            recovery = try JSONDecoder().decode(RequestRecoveryStore.self,
                from: BoundedCatalogReader(root: directory).read("recovery.json", limit: CatalogLimits.manifestBytes).bytes)
            guard recovery.formatVersion == 1, recovery.entries.allSatisfy({ key, value in
                key == value.journal && URL(fileURLWithPath: key).deletingLastPathComponent().path == RequestPaths.canonical(directory)
            }) else { throw ShaderRequestError.unavailable("Recovery journal is invalid. Retain recovery.json and repair it before reusing this checkout.") }
        }
        if let entry = recovery.entries.values.first {
            reconciliationFailure = entry.message; reconciliationJournal = URL(fileURLWithPath: entry.journal)
            reconciliationConfiguration = entry.configuration
        }
        loaded = true
        try persist()
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    public func artifacts(for id: UUID) -> URL { folder(id) }
    public func configurationValue() -> ShaderRequestConfiguration { configuration }
    private func requireRepositorySelection() throws {
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
    private func acceptRepository(_ accepted: ShaderRequestConfiguration) {
        if Self.samePublicationCheckout(configuration, accepted) { configuration = accepted; return }
        cancelPublicationRequests()
        configuration = accepted
        publicationGeneration = UUID(); latestPublication = nil; unresolvedPublicationFailure = nil
        _ = publicationState(.idle)
    }
    @discardableResult public func selectRepository(_ repository: URL) async throws -> ShaderRequestConfiguration {
        try load()
        if RequestPaths.canonical(repository) == RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) { return configuration }
        try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        let accepted = selectedConfiguration(repository)
        try JSONEncoder().encode(accepted).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        acceptRepository(accepted)
        return accepted
    }
    /// Folder selection, publication and persisted management configuration share one lease.
    public func reloadRepository(_ repository: URL) async throws -> ShaderRepositorySelection {
        try load(); try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); selectingRepository = true
        defer { selectingRepository = false; endMaintenance(lease) }
        let previous = configuration, accepted = selectedConfiguration(repository)
        let prepared = try await catalog.prepare(from: repository)
        do {
            try checkMaintenance(lease)
            try JSONEncoder().encode(accepted).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
            let publication: CatalogReloadResult
            do { publication = try await catalog.install(prepared.id) }
            catch {
                do { try JSONEncoder().encode(previous).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic) }
                catch {
                    let journal = directory.appendingPathComponent("selection")
                    holdForRecovery(journal: journal, configuration: previous, error: error, preferencesRollback: previous)
                }
                throw error
            }
            acceptRepository(accepted); published(publication)
            return ShaderRepositorySelection(configuration: configuration, publication: publication)
        } catch { await catalog.discard(prepared.id); throw error }
    }
    public func hasPendingCleanup() -> Bool { records.values.contains { $0.cleanupPending == true } }
    private var recoveryBlocker: String? {
        if let entry = recovery.entries.values.first { return "Mac checkout recovery required: " + entry.message }
        if let reconciliationFailure { return "Mac checkout recovery required: " + reconciliationFailure }
        if let record = records.values.first(where: { $0.cleanupPending == true }) {
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
        guard !suspended, let request = pendingPublication else { return }
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
                message: entry.message, isRunning: reconciliationTask != nil, requestID: entry.requestID,
                journal: URL(fileURLWithPath: entry.journal), checkout: entry.configuration, disposition: entry.disposition))
        }
        if recovery.entries.isEmpty, let reconciliationFailure {
            statuses.append(ShaderRequestRecoveryStatus(id: Self.reconciliationStatusID, kind: .reconciliation,
                repository: reconciliationConfiguration?.repository ?? "", python: reconciliationConfiguration?.python ?? "", git: reconciliationConfiguration?.git ?? "",
                message: reconciliationFailure, isRunning: reconciliationTask != nil,
                requestID: records.keys.first { folder($0) == reconciliationJournal }, journal: reconciliationJournal, checkout: reconciliationConfiguration))
        }
        return statuses
    }

    private func reconcileWorkers() async throws {
        guard !reconciled else { return }
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
            reconciliationTask = ReconciliationAttempt(task: Task.detached {
                for folder in folders.sorted(by: { $0.path < $1.path }) {
                    do { try await reconcile(folder) }
                    catch {
                        let key = RequestPaths.canonical(folder)
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
            guard reconciliationTask?.id == attempt.id else { return }
            guard !detaching else { reconciliationTask = nil; throw CancellationError() }
            for acknowledgement in result.acknowledgements {
                detachedOwners.removeAll { $0.requestID == acknowledgement.requestID }; detachedOwners.append(acknowledgement)
                if Self.matchesDetachedCheckout(configuration, acknowledgement: acknowledgement) {
                    configuration.enabled = false
                    try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
                }
            }
            // Finalization is idempotent; entries remain durable until record/ack writes finish.
            for entry in recovery.entries.values where entry.disposition == .detach { try finalizeDetachment(entry) }
            for entry in recovery.entries.values {
                if let rollback = entry.preferencesRollback {
                    try JSONEncoder().encode(rollback).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
                    configuration = rollback
                }
                guard let id = entry.requestID, records[id]?.detached != true else { continue }
                switch entry.disposition {
                case .resume:
                    if records[id]?.cleanupPending != true, records[id]?.status.stage != .awaitingClarification,
                       records[id]?.status.stage != .awaitingActivation, records[id]?.status.stage.terminal == false {
                        recoveryID = id; try update(id, stage: .repairing, message: "Resuming preserved work after process recovery")
                    }
                case .cleanup: records[id]?.cleanupFailure = nil
                case .retainResult, .detach: break
                }
            }
            if let owner = result.owner, records[owner]?.detached != true {
                recoveryID = owner
                if let stage = records[owner]?.status.stage, stage.terminal || stage == .awaitingActivation || stage == .awaitingClarification {
                    records[owner]?.cleanupPending = true
                    records[owner]?.cleanupMessage = "Cleaning interrupted owned work; pushed commits are retained"
                    if !stage.terminal && stage != .awaitingActivation { try update(owner, stage: .failed, message: "Interrupted checkout cleanup is required") }
                } else if records[owner]?.status.stage != .repairing { try update(owner, stage: .repairing, message: "Recovering interrupted owned work") }
            }
            recovery.legacyMigrationComplete = true
            try persist()
            recovery.entries.removeAll(); try persist()
            reconciled = true; reconciliationTask = nil; reconciliationFailure = nil; reconciliationJournal = nil; reconciliationConfiguration = nil
            emitUpdates()
        } catch {
            if detaching, error is CancellationError { throw error }
            if reconciliationTask?.id == attempt.id {
                let detail = error as? ReconciliationError
                reconciliationTask = nil
                if let detail {
                    holdForRecovery(journal: detail.journal, configuration: detail.configuration, error: detail.underlying)
                } else {
                    holdForRecovery(journal: reconciliationJournal ?? directory.appendingPathComponent("setup"),
                        configuration: reconciliationConfiguration, error: error)
                }
                failPendingPublicationForRecovery(reconciliationFailure ?? error.localizedDescription)
            }
            throw error
        }
    }

    nonisolated private static func hasProcessEvidence(_ journal: URL) -> Bool {
        ["process.json", "children.json", "supervision.json"].contains { FileManager.default.fileExists(atPath: journal.appendingPathComponent($0).path) }
    }
    private func persistRecovery() throws {
        try recoveryWriter(JSONEncoder().encode(recovery), directory.appendingPathComponent("recovery.json"))
    }
    private func holdForRecovery(journal: URL, configuration target: ShaderRequestConfiguration?, error: Error,
                                 preferencesRollback: ShaderRequestConfiguration? = nil) {
        let key = RequestPaths.canonical(journal), id = records.keys.first { RequestPaths.canonical(folder($0)) == key }
        let disposition: ShaderRequestRecoveryDisposition
        if let id, records[id]?.cleanupPending == true || records[id]?.revoked == true { disposition = .cleanup }
        else if let id, records[id]?.status.stage == .awaitingActivation || records[id]?.status.stage == .completed { disposition = .retainResult }
        else { disposition = .resume }
        var entry = recovery.entries[key] ?? .init(journal: key, requestID: id, configuration: target, disposition: disposition, message: error.localizedDescription)
        entry.configuration = entry.configuration ?? target; entry.message = error.localizedDescription
        if let preferencesRollback { entry.preferencesRollback = preferencesRollback }
        recovery.entries[key] = entry
        reconciliationFailure = entry.message; reconciliationJournal = URL(fileURLWithPath: key); reconciliationConfiguration = entry.configuration; reconciled = false
        do { try persistRecovery(); try persist() }
        catch {
            entry.message += " Recovery state could not be saved: " + error.localizedDescription
            recovery.entries[key] = entry; reconciliationFailure = entry.message; emitUpdates()
        }
    }
    private func finalizeDetachment(_ entry: RequestRecoveryStore.Entry) throws {
        guard let id = entry.requestID, let target = entry.configuration else { return }
        let acknowledgement = Self.acknowledgement(id: id, job: URL(fileURLWithPath: entry.journal), configuration: target)
        detachedOwners.removeAll { $0.requestID == id }; detachedOwners.append(acknowledgement)
        if records[id] != nil {
            let wasDetached = records[id]?.detached == true
            records[id]?.detached = true; records[id]?.interrupted = true
            records[id]?.cleanupPending = false; records[id]?.cleanupFailure = nil
            if !wasDetached, records[id]?.status.stage.terminal == false {
                try update(id, stage: .failed, message: "Checkout detached; unpublished files and evidence were retained")
            }
        }
    }

    public func retryReconciliation() async throws {
        guard activeID == nil, !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout work to finish.") }
        reconciled = false
        // Existing waiters retain their own attempt identity and cannot clear a subsequent retry.
        reconciliationTask = nil; reconciliationKickID = nil
        for entry in recovery.entries.values {
            try RequestWorkerOperation.restartPaused(in: URL(fileURLWithPath: entry.journal))
        }
        try await reconcileWorkers()
        try persist(); kick()
    }

    public func retryCleanup(_ id: UUID, repository: String, python: String, git: String) async throws {
        guard activeID == nil, !maintenanceBusy, let record = records[id], record.cleanupPending == true else {
            throw ShaderRequestError.unavailable("Wait for active checkout work to finish before retrying cleanup.")
        }
        let lease = try beginMaintenance()
        defer { endMaintenance(lease) }
        var corrected = record.configuration
        corrected.repository = repository; corrected.python = python; corrected.git = git
        guard RequestPaths.canonical(URL(fileURLWithPath: repository)) == RequestPaths.canonical(URL(fileURLWithPath: record.configuration.repository)) else {
            throw ShaderRequestError.unavailable("Restore the owned checkout's original path, or detach it and select a fresh clean checkout.")
        }
        let job = folder(id)
        try await Task.detached { try Self.validateRecoveryCheckout(corrected, id: id, job: job) }.value
        try checkMaintenance(lease)
        guard records[id]?.detached != true else { throw CancellationError() }
        let previous = record.configuration
        let paths = Self.canonicalRepositories([configuration.repository, previous.repository] + records.values.map { $0.configuration.repository })
        for key in records.keys where records[key]?.detached != true {
            guard let existing = records[key]?.configuration else { continue }
            if Self.samePublicationCheckout(existing, previous, paths: paths) {
                records[key]?.configuration.repository = repository
                records[key]?.configuration.python = python; records[key]?.configuration.git = git
            }
        }
        if Self.samePublicationCheckout(configuration, previous, paths: paths) {
            configuration.repository = repository; configuration.python = python; configuration.git = git
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        }
        try RequestWorkerOperation.restartPaused(in: job)
        records[id]?.cleanupFailure = nil; recoveryID = id
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil
        try persist()
        try await reconcileWorkers()
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
            entry.message = "Detachment is pending until worker processes are confirmed stopped."
            recovery.entries[key] = entry
        }
    }

    public func detachCheckout(_ target: ShaderCheckoutDetachTarget) async throws {
        guard !selectingRepository else { throw ShaderRequestError.unavailable("Wait for the selected folder to finish loading before detaching.") }
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
        try persistRecovery(); try persist()
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        cancelPublicationRequests(); activeProcess?.stop()
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
        try persistRecovery(); try persist()
        for (_, target) in targets.sorted(by: { $0.key < $1.key }) {
            let (journal, _, checkout) = target
            do { try await reconcileWorker(journal) }
            catch {
                if error is RequestWorkerTeardownError || error is RequestWorkerOwnershipError {
                    holdForRecovery(journal: journal, configuration: checkout, error: error); throw error
                }
                // Explicit detachment retains unverifiable markers without signalling them.
                for name in ["process", "children", "supervision"] {
                    let marker = journal.appendingPathComponent(name + ".json")
                    if FileManager.default.fileExists(atPath: marker.path) {
                        try FileManager.default.moveItem(at: marker, to: journal.appendingPathComponent(name + "-detached-" + UUID().uuidString + ".json"))
                    }
                }
            }
        }
        for (journal, _, _) in targets.values {
            if let entry = recovery.entries[RequestPaths.canonical(journal)] { try finalizeDetachment(entry) }
        }
        try persist()
        for key in targets.keys { recovery.entries[key] = nil }
        reconciled = false; reconciliationTask = nil; reconciliationKickID = nil
        if let entry = recovery.entries.values.first {
            reconciliationFailure = entry.message; reconciliationJournal = URL(fileURLWithPath: entry.journal)
            reconciliationConfiguration = entry.configuration
        } else { reconciliationFailure = nil; reconciliationJournal = nil; reconciliationConfiguration = nil }
        resolvePublicationFailure()
        setupMessage = "Requests disabled. Select a checkout and verify setup before enabling requests again."
        try persist()
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
            var ready = false
            try await runWorker(mode: "publication", configuration: configuration, journal: directory.appendingPathComponent("publication"), operation: operation) { event, process in
                try checkExecution(operation)
                switch event.event {
                case "preparePublication": try await preparePublication(event, process: process, operation: operation)
                case "publicationReady": ready = true
                case "failure": throw workerFailure(event)
                default: break
                }
            }
            try checkExecution(operation)
            guard ready, let preparedID else { throw ShaderRequestError.unavailable("Publication rebuild did not complete.") }
            let publication = try await catalog.install(preparedID)
            self.preparedID = nil; published(publication)
            try persist()
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
        do { try await waitForWorker(process) }
        catch {
            holdForRecovery(journal: process.recoveryTarget?.directory ?? activeID.map(folder) ?? directory.appendingPathComponent("publication"),
                configuration: process.recoveryTarget?.configuration ?? configurationForActiveWorker, error: error)
            throw error
        }
    }
    private func stopAndDrain(_ process: RequestWorkerProcess) async -> Error? {
        process.stop()
        do { try await settleProcess(process); return nil } catch { return error }
    }

    private func workerFailure(_ event: RequestWorkerEvent) -> Error {
        let message = event.message ?? "Shader worker failed"
        guard event.recoveryRequired == true else {
            if event.failureKind == "supervision" || event.failureKind == "interrupted" {
                return RequestWorkerSupervisionError(message: message, retryable: event.failureKind == "supervision" && event.retryable != false)
            }
            return ShaderRequestError.unavailable(message)
        }
        let failure = RequestWorkerTeardownError(cause: message)
        holdForRecovery(journal: activeProcess?.recoveryTarget?.directory ?? activeID.map(folder) ?? directory.appendingPathComponent("publication"),
            configuration: activeProcess?.recoveryTarget?.configuration ?? configurationForActiveWorker, error: failure)
        return failure
    }

    private func runWorker(mode: String, configuration: ShaderRequestConfiguration, journal: URL, operation: UUID,
                           receive: (RequestWorkerEvent, RequestWorkerProcess) async throws -> Void) async throws {
        var attempt: RequestWorkerOperation
        do {
            try checkExecution(operation)
            attempt = try RequestWorkerOperation.begin(mode: mode, in: journal)
            try await reconcileWorker(journal)
            try checkExecution(operation)
            if attempt.phase == .retryPending { attempt.phase = .retryRunning; try attempt.save(in: journal) }
        } catch {
            if !(error is CancellationError) { holdForRecovery(journal: journal, configuration: configuration, error: error) }
            throw error
        }
        while true {
            try checkExecution(operation)
            let process = workerProcess(); activeProcess = process
            do {
                for try await event in process.run(mode: mode, configuration: configuration, directory: journal, operationID: attempt.id) {
                    try checkExecution(operation)
                    if event.event == "failure" { throw workerFailure(event) }
                    try await receive(event, process)
                }
                try await settleProcess(process)
                try checkExecution(operation)
                attempt.phase = .complete; try attempt.save(in: journal)
                return
            } catch {
                let settlementError = await stopAndDrain(process)
                if let settlementError { throw settlementError }
                try checkExecution(operation)
                guard let fault = error as? RequestWorkerSupervisionError else { throw error }
                holdForRecovery(journal: journal, configuration: configuration, error: fault)
                do {
                    try persistRecovery() // A failed recovery write must prevent automatic relaunch.
                    guard fault.retryable, attempt.phase == .initial else {
                        attempt.phase = .paused; try attempt.save(in: journal); throw fault
                    }
                    attempt.phase = .retryPending; try attempt.save(in: journal)
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                    try checkExecution(operation)
                    try await reconcileWorker(journal)
                    try checkExecution(operation)
                    attempt.phase = .retryRunning; try attempt.save(in: journal)
                    let key = RequestPaths.canonical(journal)
                    recovery.entries[key] = nil
                    if reconciliationJournal.map({ RequestPaths.canonical($0) }) == key {
                        reconciliationFailure = nil; reconciliationJournal = nil; reconciliationConfiguration = nil
                    }
                    try persist()
                    if mode == "run", let id = activeID, records[id]?.status.stage.terminal == false,
                       records[id]?.status.stage != .awaitingActivation, records[id]?.status.stage != .awaitingClarification {
                        try update(id, stage: .repairing, message: "Retrying preserved work after a supervision failure")
                    }
                } catch {
                    holdForRecovery(journal: journal, configuration: configuration, error: error)
                    throw error
                }
            }
        }
    }

    private func checkExecution(_ id: UUID) throws {
        try Task.checkCancellation()
        guard execution?.id == id, execution?.interrupted == false, !suspended else { throw CancellationError() }
    }

    private func preparePublication(_ event: RequestWorkerEvent, process: RequestWorkerProcess, operation: UUID) async throws {
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
                preparedID = prepared.id
                try process.reply(true)
            }
        } catch { await catalog.discard(prepared.id); throw error }
    }
    private var configurationForActiveWorker: ShaderRequestConfiguration { activeID.flatMap { records[$0]?.configuration } ?? configuration }

    public func allJobs() -> [ShaderRequestStatus] { records.values.map(\.status).sorted { $0.createdAt > $1.createdAt } }
    public func updates() -> AsyncStream<[ShaderRequestStatus]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(allJobs())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func persist() throws {
        try JSONEncoder().encode(detachedOwners).write(to: directory.appendingPathComponent("detached-checkouts.json"), options: .atomic)
        try JSONEncoder().encode(Array(records.values)).write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
        try persistRecovery()
        emitUpdates()
    }
    private func emitUpdates() { for observer in observers.values { observer.yield(allJobs()) } }
    private func update(_ id: UUID, stage: ShaderRequestStatus.Stage, message: String) throws {
        records[id]?.status.stage = stage; records[id]?.status.message = message
        records[id]?.status.updatedAt = Date(); records[id]?.status.sequence &+= 1
        try persist()
    }
    public func verify(configuration candidate: ShaderRequestConfiguration) async throws {
        try load()
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
        var verified = false
        do {
            try RequestWorkerOperation.restartPaused(in: directory.appendingPathComponent("setup"))
            try await runWorker(mode: "preflight", configuration: candidate, journal: directory.appendingPathComponent("setup"), operation: operation.id) { event, _ in
                try checkExecution(operation.id)
                if event.event == "failure" { throw workerFailure(event) }
                if event.event == "preflight" { verified = true; candidate.checkoutID = event.checkoutID }
            }
            try checkExecution(operation.id)
            guard verified else { throw ShaderRequestError.unavailable("Setup did not complete.") }
        } catch {
            throw error
        }
        candidate.detachedOwner = nil
        if !Self.samePublicationCheckout(configuration, candidate) { cancelPublicationRequests() }
        configuration = candidate; configuration.enabled = true
        let paths = Self.canonicalRepositories([candidate.repository] + detachedOwners.map(\.repository))
        detachedOwners.removeAll { Self.matchesDetachedCheckout(candidate, acknowledgement: $0, paths: paths) }
        if !initialized { initialized = true; schedulingActive = true }
        try persist()
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        setupMessage = "Ready for shader requests"
        resolvePublicationFailure()
        try persist(); kick()
    }
    public func canDisableRequests() -> Bool {
        activeID == nil && !maintenanceBusy && !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true })
    }
    public func disable() throws {
        guard canDisableRequests() else {
            throw ShaderRequestError.unavailable("Requests are still in progress.")
        }
        configuration.enabled = false; setupMessage = "Shader requests are disabled."
        cancelPublicationRequests()
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        try persist()
    }
    public func cancelQueued(_ id: UUID) throws {
        guard records[id]?.status.stage == .queued, activeID != id else {
            throw ShaderRequestError.unavailable("Only queued requests can be cancelled.")
        }
        try update(id, stage: .cancelled, message: "Cancelled on the Mac")
        kick()
    }
    public func deleteFinished(_ id: UUID) throws {
        guard !recovery.entries.values.contains(where: { $0.requestID == id }), !Self.hasProcessEvidence(folder(id)), records[id]?.status.stage.terminal == true, records[id]?.cleanupPending != true, activeID != id else { throw ShaderRequestError.invalidRequest }
        try FileManager.default.removeItem(at: folder(id)); records[id] = nil; try persist()
    }
    public func revoke(_ deviceID: String) throws {
        for id in records.keys where records[id]?.status.deviceID == deviceID && records[id]?.status.stage.terminal == false {
            records[id]?.revoked = true
            if records[id]?.status.stage == .queued, activeID != id {
                try update(id, stage: .cancelled, message: "TV access was revoked")
            } else if activeID != id {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                try update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
            }
        }
        try persist(); kick()
    }

    public func control(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        try load()
        if operation == "requestSubmit" {
            guard configuration.enabled else { throw ShaderRequestError.unavailable(setupMessage) }
            if let blocker = recoveryBlocker { throw ShaderRequestError.unavailable(blocker) }
            guard let request = payload.request else { throw ShaderRequestError.invalidRequest }
            try request.validate()
            if let existing = records[request.id] {
                guard existing.status.deviceID == deviceID else { throw ShaderRequestError.notFound }
                let original = try JSONDecoder().decode(ShaderRequest.self, from: Data(contentsOf: folder(request.id).appendingPathComponent("request.json")))
                guard original == request else { throw ShaderRequestError.invalidRequest }
                return try await reply(deviceID: deviceID, requestID: request.id)
            }
            if request.purpose == .performance, let existing = records.values.first(where: {
                $0.status.deviceID == deviceID && !$0.status.stage.terminal && $0.status.request.purpose == .performance &&
                $0.status.request.context.shaderID == request.context.shaderID && $0.status.request.context.sourceHash == request.context.sourceHash
            }) { return try await reply(deviceID: deviceID, requestID: existing.status.id) }
            if request.purpose == .creative, records.values.contains(where: {
                $0.status.deviceID == deviceID && $0.status.blocksBrowsing
            }) { throw ShaderRequestError.unavailable("This TV already has a manual request in progress.") }
            let job = folder(request.id)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: job.appendingPathComponent("request.json"), options: .atomic)
            var lightweight = request
            lightweight.context.source = ""; lightweight.context.screenshot = Data()
            records[request.id] = Record(status: ShaderRequestStatus(request: lightweight, deviceID: deviceID), configuration: configuration)
            try persist() // Acknowledgement follows durable acceptance.
            kick()
            return try await reply(deviceID: deviceID, requestID: request.id)
        }
        if operation == "requestAnswer" || operation == "requestActivated" || operation == "requestDelivery" {
            guard let id = payload.requestID, let record = records[id], record.status.deviceID == deviceID, !record.revoked else {
                throw ShaderRequestError.notFound
            }
            if operation == "requestDelivery" {
                guard let nonce = payload.answer, UUID(uuidString: nonce) != nil else { throw ShaderRequestError.invalidRequest }
                if record.status.stage == .awaitingActivation, record.deliveryNonce != nonce {
                    records[id]?.deliveryNonce = nonce
                    try update(id, stage: .queued, message: "Refreshing latest committed result for this TV")
                    kick()
                }
            } else if operation == "requestAnswer" {
                guard record.status.stage == .awaitingClarification, let answer = payload.answer,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 16_384 else {
                    throw ShaderRequestError.invalidRequest
                }
                try JSONEncoder().encode(answer).write(to: folder(id).appendingPathComponent("answer.json"), options: .atomic)
                records[id]?.status.clarification = nil
                try update(id, stage: .queued, message: "Ready to continue after clarification")
                kick()
            } else if record.status.stage == .awaitingActivation {
                if let diagnostic = payload.diagnostic {
                    guard diagnostic.utf8.count <= 16_384 else { throw ShaderRequestError.invalidRequest }
                    try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": record.status.result?.shaderID ?? "", "diagnostic": diagnostic])
                        .write(to: folder(id).appendingPathComponent("repair.json"), options: .atomic)
                    try update(id, stage: .repairing, message: "Repairing the TV activation error")
                    kick()
                } else {
                    guard (record.status.request.purpose == .performance && payload.sourceHash == nil) ||
                          (payload.sourceHash.map({ CatalogHash.isSHA($0) }) == true && payload.sourceHash == record.status.result?.deliveredSourceHash) else {
                        throw ShaderRequestError.invalidRequest
                    }
                    records[id]?.status.result?.deliveredSourceHash = payload.sourceHash
                    try update(id, stage: .completed, message: record.status.result?.summary ?? "Request completed")
                }
            }
        }
        return try await reply(deviceID: deviceID, requestID: payload.requestID)
    }
    private func reply(deviceID: String, requestID: UUID?) async throws -> ShaderRequestControlReply {
        let owned = allJobs().filter { $0.deviceID == deviceID }
        let jobs = requestID.map { id in owned.filter { $0.id == id } } ?? owned.filter { !$0.stage.terminal }
        return ShaderRequestControlReply(enabled: configuration.enabled && recoveryBlocker == nil,
                                        message: recoveryBlocker ?? (configuration.enabled ? "Ready for shader requests" : setupMessage), jobs: jobs,
                                        publicationRevision: await catalog.publicationRevisionValue())
    }
    private func kick() {
        guard loaded, initialized, !suspended, !maintenanceBusy, activeID == nil, workerTask == nil else { return }
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
        let eligible = records.values.filter { !$0.revoked && $0.detached != true }.map(\.status)
        if let recoveryID, let failure = records[recoveryID]?.cleanupFailure {
            failPendingPublicationForRecovery(failure); return
        }
        let ownerCleanup = recoveryID.flatMap { records[$0]?.cleanupPending == true ? $0 : nil }
        let cleanupID = ownerCleanup ?? records.values.filter { $0.cleanupPending == true && $0.cleanupFailure == nil }.sorted { $0.status.createdAt < $1.status.createdAt }.first?.status.id
        let interrupted = recoveryID.flatMap { id -> UUID? in
            guard configuration.enabled, schedulingActive || pendingPublication != nil || retryPublicationForce != nil,
                  let value = records[id], !value.revoked, value.detached != true,
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
        do {
            try JSONEncoder().encode(id).write(to: directory.appendingPathComponent("active.json"), options: .atomic)
            records[id]?.executionID = operation.id; records[id]?.interrupted = false
            if case .execute = work { try update(id, stage: .implementing, message: "Preparing the managed checkout") }
            else { try persist() }
        } catch {
            execution = nil; try? update(id, stage: .failed, message: error.localizedDescription)
            return
        }
        activeID = id
        workerTask = Task { [weak self] in
            switch work {
            case .cleanup(let id): await self?.cleanup(id, operation: operation.id)
            case .execute(let id): await self?.execute(id, operation: operation.id)
            case .publication: break
            }
        }
    }
    private func cleanup(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { finishWorker(id); return }
        await prepareCleanup()
        do {
            try checkExecution(operation)
            let job = folder(id)
            var discarded = false
            try await runWorker(mode: "discard", configuration: record.configuration, journal: job, operation: operation) { event, _ in
                try checkExecution(operation)
                if event.event == "failure" { throw workerFailure(event) }
                if event.event == "discarded" { discarded = true }
            }
            try checkExecution(operation)
            guard discarded else { throw ShaderRequestError.unavailable("Cleanup did not complete.") }
            records[id]?.cleanupPending = false; records[id]?.cleanupFailure = nil
            if record.status.result != nil, record.status.stage == .awaitingActivation || record.status.stage == .completed {
                try update(id, stage: record.status.stage, message: record.status.message)
            } else { try update(id, stage: .failed, message: record.cleanupMessage ?? "Owned checkout cleanup completed; see the retained request diagnostic") }
        } catch {
            if error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError || error is RequestWorkerTeardownError || error is RequestWorkerSupervisionError {
                holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            }
            if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupFailure = error.localizedDescription
                setupMessage = "Checkout recovery is required. Correct the saved folder/tool paths and retry cleanup, or detach the checkout."
                try? update(id, stage: .failed, message: "Cleanup failed: \(error.localizedDescription). \(setupMessage)")
            }
        }
        finishWorker(id)
    }
    private func finishWorker(_ id: UUID) {
        let interrupted = execution?.interrupted == true
        activeProcess = nil; activeID = nil; workerTask = nil; execution = nil
        emitUpdates()
        if records[id]?.detached != true, records[id]?.cleanupPending == true || (interrupted && records[id]?.status.stage.terminal == false) {
            recoveryID = id
            if !suspended { kick() }
        } else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("active.json"))
            if recoveryID == id { recoveryID = nil }
            kick()
        }
    }
    private func execute(_ id: UUID, operation: UUID) async {
        guard let record = records[id] else { finishWorker(id); return }
        var outcomeSeen = false
        do {
            try checkExecution(operation)
            let job = folder(id)
            try await runWorker(mode: "run", configuration: record.configuration, journal: job, operation: operation) { event, process in
                try checkExecution(operation)
                switch event.event {
                case "stage":
                    if let value = event.stage, let stage = ShaderRequestStatus.Stage(rawValue: value) {
                        try update(id, stage: stage, message: event.message ?? value)
                    }
                case "preparePublication":
                    try await preparePublication(event, process: process, operation: operation)
                case "discardPublication":
                    if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                case "clarification":
                    if records[id]?.revoked == true {
                        records[id]?.cleanupPending = true
                        records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                    }
                    records[id]?.status.clarification = ShaderClarification(question: event.question ?? "Please clarify the request", options: event.options ?? [])
                    try update(id, stage: records[id]?.revoked == true ? .failed : .awaitingClarification,
                               message: records[id]?.revoked == true ? "Discarding revoked unpublished work" : "Waiting for a TV answer")
                    outcomeSeen = true
                case "result":
                    if outcomeSeen, let result = event.result, records[id]?.status.result?.commitSHA == result.commitSHA {
                        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
                        return
                    }
                    guard let result = event.result, ShaderRequest.validID(result.shaderID), let preparedID else {
                        throw ShaderRequestError.invalidRequest
                    }
                    try update(id, stage: .publishing, message: "Installing the committed library")
                    let publication = try await catalog.install(preparedID)
                    self.preparedID = nil
                    published(publication)
                    records[id]?.status.result = result
                    if records[id]?.revoked == true {
                        try update(id, stage: .failed, message: "Pushed successfully; TV access was revoked")
                        outcomeSeen = true
                        return
                    }
                    guard let output = publication.catalog.shaders.first(where: { $0.id == result.shaderID }) else {
                        try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": result.shaderID, "diagnostic": "The committed output was removed before TV delivery. Recreate it under a fresh unused ID."])
                            .write(to: job.appendingPathComponent("repair.json"), options: .atomic)
                        try update(id, stage: .repairing, message: "Recreating the output removed before delivery")
                        outcomeSeen = true
                        return
                    }
                    records[id]?.status.result?.deliveredSourceHash = output.sourceHash
                    try update(id, stage: records[id]?.revoked == true ? .failed : .awaitingActivation,
                               message: records[id]?.revoked == true ? "Pushed successfully; TV access was revoked" : "Waiting for the TV to play the result")
                    outcomeSeen = true
                case "failure": throw workerFailure(event)
                default: break
                }
            }
            try checkExecution(operation)
            if !outcomeSeen { throw ShaderRequestError.unavailable("Worker ended without a verified result.") }
        } catch {
            if error is RequestWorkerTeardownError || error is RequestWorkerOwnershipError || error is RequestWorkerEvidenceError || error is RequestWorkerSupervisionError {
                holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            } else if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = error.localizedDescription
                try? update(id, stage: .failed, message: error.localizedDescription)
            }
        }
        if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
            records[id]?.cleanupPending = true
            records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
            try? update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
        }
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        finishWorker(id)
    }
    public func suspend() {
        suspended = true; execution?.interrupted = true
        if let id = activeID {
            records[id]?.interrupted = true
            if records[id]?.status.stage.terminal == false {
                try? update(id, stage: .repairing, message: "Waiting for the Mac to resume")
            } else { try? persist() }
        }
        activeProcess?.stop()
    }
    public func resume() { suspended = false; kick() }

    nonisolated private static func canonicalRepositories(_ repositories: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Set(repositories).map { ($0, $0.isEmpty ? "" : RequestPaths.canonical(URL(fileURLWithPath: $0))) })
    }
    nonisolated private static func savedConfiguration(in journal: URL) throws -> ShaderRequestConfiguration? {
        guard FileManager.default.fileExists(atPath: journal.appendingPathComponent("configuration.json").path) else { return nil }
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
