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
        var deletionPending: Bool?
        var deletionFailure: String?
    }
    private let directory: URL
    private let catalog: DirectoryCatalog
    private let workerScript: URL?
    private var recovery = RequestRecoveryStore()
    private let waitForWorker: @Sendable (RequestWorkerProcess) async throws -> Void
    private let reconcileWorker: @Sendable (URL) async throws -> Void
    private let persistence: RequestPersistence
    private var persistenceRevision: UInt64 = 0
    private var persistenceEpoch: UInt64 = 0
    private var pendingCommits = 0
    private var persistenceFault: RequestPersistence.Fault?
    private var persistenceFailure: String? { persistenceFault?.localizedDescription }
    private var schedulingWakeupPending = false
    private var schedulingDeferred = false
    private struct StorageChange {
        let id: UUID
        let operation: String
        let ids: Set<UUID>
        var previous: [UUID: Record]
        let configuration: ShaderRequestConfiguration?
        let acknowledgements: [DetachedCheckoutAcknowledgement]?
    }
    private var storageChange: StorageChange?
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []
    private let prepareCleanup: @Sendable () async -> Void
    private var configuration = ShaderRequestConfiguration()
    private var records: [UUID: Record] = [:]
    private var observers: [UUID: AsyncStream<[ShaderRequestStatus]>.Continuation] = [:]
    private var activeID: UUID?
    private var activeProcess: RequestWorkerProcess?
    private var workerTask: Task<Void, Never>?
    private var preparedID: UUID? { didSet { if preparedID == nil { preparedAttemptID = nil } } }
    private var preparedAttemptID: UUID?
    private struct Execution { let id = UUID(); var interrupted = false }
    private var execution: Execution?
    private var selectingRepository = false
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
    }
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
    private let bundledShaderTool: String?
    private var initialized = false
    private var detachedOwners: [DetachedCheckoutAcknowledgement] = []
    private var suspended = false
    private var loaded = false
    private var activeRetryJournals: [String: UUID] = [:]
    private var recoveryID: UUID?
    private var setupMessage = "Enable shader requests in Mac Settings."

    public init(catalog: DirectoryCatalog, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/Requests")) {
        self.catalog = catalog; self.directory = directory; self.workerScript = nil
        self.waitForWorker = { try await $0.waitForExit() }
        self.reconcileWorker = { try RequestWorkerProcess.reconcileOrphan(in: $0) }
        self.persistence = RequestPersistence(directory: directory)
        self.prepareCleanup = {}
        self.bundledShaderTool = Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path
    }
    init(catalog: DirectoryCatalog, directory: URL, workerScript: URL,
         reconcileWorker: @escaping @Sendable (URL) async throws -> Void = { try RequestWorkerProcess.reconcileOrphan(in: $0) },
         waitForWorker: @escaping @Sendable (RequestWorkerProcess) async throws -> Void = { try await $0.waitForExit() },
         recoveryWriter: @escaping @Sendable (Data, URL) throws -> Void = { try RequestJournalWriter.write($0, to: $1) },
         prepareCleanup: @escaping @Sendable () async -> Void = {}, bundledShaderTool: String? = nil) {
        self.catalog = catalog; self.directory = directory; self.workerScript = workerScript
        self.reconcileWorker = reconcileWorker; self.waitForWorker = waitForWorker; self.persistence = RequestPersistence(directory: directory, recoveryWriter: recoveryWriter)
        self.prepareCleanup = prepareCleanup
        self.bundledShaderTool = bundledShaderTool ?? Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path
    }
    private func workerProcess() -> RequestWorkerProcess { RequestWorkerProcess(script: workerScript) }
    private func waitForStorageChange() async {
        while let change = storageChange, change.id != RequestStorageContext.mutation {
            await withCheckedContinuation { storageWaiters.append($0) }
        }
    }
    private func scheduleWakeup() {
        guard !schedulingWakeupPending else { return }
        schedulingWakeupPending = true
        RequestStorageContext.$mutation.withValue(nil) {
            Task { [weak self] in
                guard let self else { return }
                await self.performSchedulingWakeup()
            }
        }
    }
    private func performSchedulingWakeup() { schedulingWakeupPending = false; schedulingDeferred = false; kick() }
    private func publishStorageFault(_ error: Error) {
        guard let fault = error as? RequestPersistence.Fault else { return }
        guard persistenceFault == nil || fault.generation >= persistenceFault!.generation else { return }
        persistenceFault = fault
        activeProcess?.shutdown()
        failPendingPublicationForRecovery(fault.localizedDescription)
        emitUpdates()
    }
    private func writeFile(_ bytes: Data, to file: URL) async throws {
        await waitForStorageChange()
        do { try await persistence.write(bytes, to: file) }
        catch { publishStorageFault(error); throw error }
    }
    private func journalChange<T: Sendable>(_ operation: String, in journal: URL, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        do { return try await persistence.journal(operation, files: [journal.appendingPathComponent(RequestWorkerOperation.filename), journal.appendingPathComponent("configuration.json")], body) }
        catch { publishStorageFault(error); throw error }
    }
    private func changingStorage<T: Sendable>(_ operation: String, ids: Set<UUID> = [], configuration: Bool = false,
                                             _ body: (isolated ShaderRequestService) async throws -> T) async throws -> T {
        if storageChange?.id == RequestStorageContext.mutation, storageChange != nil { return try await body(self) }
        await waitForStorageChange()
        if let persistenceFault { throw persistenceFault }
        let id = UUID()
        storageChange = StorageChange(id: id, operation: operation, ids: ids,
            previous: records.filter { ids.contains($0.key) }, configuration: configuration ? self.configuration : nil,
            acknowledgements: configuration ? detachedOwners : nil)
        defer {
            storageChange = nil
            let waiting = storageWaiters; storageWaiters.removeAll(); waiting.forEach { $0.resume() }
            emitUpdates(); if schedulingDeferred { scheduleWakeup() }
        }
        try await persistence.begin(id, operation: operation)
        return try await RequestStorageContext.$mutation.withValue(id) {
            do { let result = try await body(self); await persistence.accept(id); return result }
            catch {
                let original = error
                do { try await persistence.reject(id) } catch { publishStorageFault(error) }
                if let saved = storageChange {
                    for key in saved.ids {
                        let current = records[key]
                        records[key] = saved.previous[key]
                        // These are independent ownership/cancellation/publication facts.
                        if current?.revoked == true { records[key]?.revoked = true }
                        if current?.interrupted == true { records[key]?.interrupted = true }
                        if current?.detached == true { records[key] = current }
                        if let result = current?.status.result, result.commitSHA != saved.previous[key]?.status.result?.commitSHA {
                            records[key]?.status.result = result
                        }
                    }
                    if let accepted = saved.configuration { self.configuration = accepted; if detaching { self.configuration.enabled = false } }
                    if let accepted = saved.acknowledgements { detachedOwners = accepted }
                }
                publishStorageFault(original)
                throw original
            }
        }
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
    public func initialize(configuration: ShaderRequestConfiguration) async throws {
        try await load()
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
        emitUpdates()
    }
    public func activateScheduling() { schedulingActive = true; kick() }
    private func load() async throws {
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
        refreshReconciliationFailure()
        persistenceFault = try await persistence.loadFault()
        loaded = true
        if persistenceFault == nil {
            try await persist()
            for id in records.keys where records[id]?.deletionPending == true { await finishDeletion(id) }
        }
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    public func artifacts(for id: UUID) -> URL { folder(id) }
    public func configurationValue() -> ShaderRequestConfiguration {
        if storageChange?.id != RequestStorageContext.mutation, let accepted = storageChange?.configuration { return accepted }
        return configuration
    }
    var hasPendingStorageChange: Bool { storageChange != nil }
    func persistenceStatistics() async -> [String: Int] { await persistence.statistics() }
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
        if Self.samePublicationCheckout(configuration, accepted) { configuration = accepted; return }
        cancelPublicationRequests()
        configuration = accepted
        publicationGeneration = UUID(); latestPublication = nil; unresolvedPublicationFailure = nil
        _ = publicationState(.idle)
    }
    @discardableResult public func selectRepository(_ repository: URL) async throws -> ShaderRequestConfiguration {
        guard !detaching, !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout maintenance to finish.") }
        return try await changingStorage("select repository", configuration: true) { try await $0.selectRepositoryAccepted(repository) }
    }
    private func selectRepositoryAccepted(_ repository: URL) async throws -> ShaderRequestConfiguration {
        try await load()
        if RequestPaths.canonical(repository) == RequestPaths.canonical(URL(fileURLWithPath: configuration.repository)) { return configuration }
        try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        let accepted = selectedConfiguration(repository)
        try await retireMaintenanceOperations(replacing: accepted)
        try await writeFile(JSONEncoder().encode(accepted), to: directory.appendingPathComponent("preferences.json"))
        acceptRepository(accepted)
        return accepted
    }
    /// Folder selection, publication and persisted management configuration share one lease.
    public func reloadRepository(_ repository: URL) async throws -> ShaderRepositorySelection {
        guard !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout maintenance to finish.") }
        return try await changingStorage("reload repository", configuration: true) { try await $0.reloadRepositoryAccepted(repository) }
    }
    private func reloadRepositoryAccepted(_ repository: URL) async throws -> ShaderRepositorySelection {
        try await load(); try requireRepositorySelection()
        try await reconcileWorkers(); try requireRepositorySelection()
        let lease = try beginMaintenance(); selectingRepository = true
        defer { selectingRepository = false; endMaintenance(lease) }
        let previous = configuration, accepted = selectedConfiguration(repository)
        let prepared = try await catalog.prepare(from: repository)
        do {
            try checkMaintenance(lease)
            try await retireMaintenanceOperations(replacing: accepted)
            try await writeFile(JSONEncoder().encode(accepted), to: directory.appendingPathComponent("preferences.json"))
            let publication: CatalogReloadResult
            do { publication = try await catalog.install(prepared.id) }
            catch {
                do { try await writeFile(JSONEncoder().encode(previous), to: directory.appendingPathComponent("preferences.json")) }
                catch {
                    let journal = directory.appendingPathComponent("selection")
                    await holdForRecovery(journal: journal, configuration: previous, error: error, preferencesRollback: previous)
                }
                throw error
            }
            acceptRepository(accepted); published(publication)
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
    private var recoveryBlocker: String? {
        if let persistenceFailure { return "Mac persistence recovery required: " + persistenceFailure }
        if let entry = recovery.entries.values.sorted(by: { $0.journal < $1.journal }).first(where: { !isActiveRetry($0.journal) }) { return "Mac checkout recovery required: " + entry.message }
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
        guard !suspended || persistenceFault != nil, let request = pendingPublication else { return }
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
        if let persistenceFault {
            statuses.append(ShaderRequestRecoveryStatus(id: persistenceFault.id, kind: .persistence,
                repository: "", python: "", git: "", message: persistenceFault.localizedDescription,
                isRunning: maintenanceBusy || activeID != nil, journal: directory))
        }
        for record in records.values where record.deletionPending == true && record.deletionFailure != nil {
            statuses.append(ShaderRequestRecoveryStatus(id: record.status.id, kind: .persistence,
                repository: "", python: "", git: "", message: "Record deletion is pending: " + (record.deletionFailure ?? ""),
                isRunning: maintenanceBusy, journal: folder(record.status.id)))
        }
        return statuses
    }

    private func reconcileWorkers() async throws {
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
            guard reconciliationTask?.id == attempt.id else { return }
            guard !detaching else { reconciliationTask = nil; throw CancellationError() }
            guard reconciliationEpoch == attempt.epoch else {
                reconciliationTask = nil
                try await reconcileWorkers(); return
            }
            for acknowledgement in result.acknowledgements {
                detachedOwners.removeAll { $0.requestID == acknowledgement.requestID }; detachedOwners.append(acknowledgement)
                if Self.matchesDetachedCheckout(configuration, acknowledgement: acknowledgement) {
                    configuration.enabled = false
                    try await writeFile(JSONEncoder().encode(configuration), to: directory.appendingPathComponent("preferences.json"))
                }
            }
            // Finalization is idempotent; entries remain durable until record/ack writes finish.
            for entry in recovery.entries.values where entry.disposition == .detach { try await finalizeDetachment(entry) }
            for entry in recovery.entries.values {
                if let rollback = entry.preferencesRollback {
                    try await writeFile(JSONEncoder().encode(rollback), to: directory.appendingPathComponent("preferences.json"))
                    configuration = rollback
                }
                guard let id = entry.requestID, records[id]?.detached != true else { continue }
                switch entry.disposition {
                case .resume:
                    if records[id]?.cleanupPending != true, records[id]?.status.stage != .awaitingClarification,
                       records[id]?.status.stage != .awaitingActivation, records[id]?.status.stage.terminal == false {
                        recoveryID = id; try await update(id, stage: .repairing, message: "Resuming preserved work after process recovery")
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
                    if !stage.terminal && stage != .awaitingActivation { try await update(owner, stage: .failed, message: "Interrupted checkout cleanup is required") }
                } else if records[owner]?.status.stage != .repairing { try await update(owner, stage: .repairing, message: "Recovering interrupted owned work") }
            }
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
        try await commitFiles([.init(url: directory.appendingPathComponent("recovery.json"), bytes: recovery.encoded())], retainingEvidence: retainingEvidence)
    }
    private func commitFiles(_ files: [RequestPersistence.File], retainingEvidence: Bool = false) async throws {
        persistenceRevision &+= 1
        let snapshot = RequestPersistence.Snapshot(revision: persistenceRevision, files: files), epoch = persistenceEpoch
        pendingCommits += 1
        defer { pendingCommits -= 1; if pendingCommits == 0, schedulingDeferred { scheduleWakeup() } }
        do { try await persistence.commit(snapshot, retainingEvidence: retainingEvidence, transaction: files.allSatisfy { $0.url.lastPathComponent == "recovery.json" } ? nil : RequestStorageContext.mutation) }
        catch {
            if epoch == persistenceEpoch { publishStorageFault(error) }
            throw error
        }
    }
    private func resetPersistenceFailure() async throws {
        let expected = persistenceFault?.id
        let id = try await persistence.restoreForRecovery()
        try await persist()
        try await persistence.finishRecovery(id)
        guard persistenceFault?.id == expected else { throw RequestWorkerEvidenceError(cause: "A newer storage failure superseded recovery.") }
        persistenceEpoch &+= 1; persistenceFault = nil; emitUpdates(); if schedulingDeferred { scheduleWakeup() }
    }
    private func progressPersistenceFailed(_ error: Error, epoch: UInt64) {
        guard epoch == persistenceEpoch else { return }
        publishStorageFault(error)
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
        guard let archiveID = entry.archiveID else {
            throw RequestWorkerEvidenceError(cause: "Detachment archive intent is missing; retry explicit Detach.")
        }
        try await persistence.perform { try RequestJournalWriter.archive(in: URL(fileURLWithPath: entry.journal), id: archiveID) }
        guard let id = entry.requestID, let target = entry.configuration else { return }
        let acknowledgement = Self.acknowledgement(id: id, job: URL(fileURLWithPath: entry.journal), configuration: target)
        detachedOwners.removeAll { $0.requestID == id }; detachedOwners.append(acknowledgement)
        if records[id] != nil {
            let wasDetached = records[id]?.detached == true
            records[id]?.detached = true; records[id]?.interrupted = true
            records[id]?.cleanupPending = false; records[id]?.cleanupFailure = nil
            if !wasDetached, records[id]?.status.stage.terminal == false {
                try await update(id, stage: .failed, message: "Checkout detached; unpublished files and evidence were retained")
            }
        }
    }

    private func drainReconciliation(lease: UUID) async throws {
        let previous = reconciliationTask
        // Invalidate its actor callback before awaiting the detached observer. The
        // maintenance lease prevents a replacement worker or observer from starting.
        reconciliationTask = nil; reconciliationKickID = nil; reconciled = false
        if let previous { _ = try? await previous.task.value }
        try checkMaintenance(lease)
    }

    public func retryReconciliation() async throws {
        guard activeID == nil, !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout work to finish.") }
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        try await resetPersistenceFailure(); try await drainReconciliation(lease: lease)
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
        for participant in repair.participants ?? [] { records[participant.requestID]?.configuration = participant.change.corrected }
        try await persist() // Retain the intent until bindings, records and preferences converge.
        try checkMaintenance(lease)
        if let preferences = repair.preferences {
            guard configuration == preferences.previous || configuration == preferences.corrected else { throw RequestWorkerOwnershipError() }
            try await writeFile(JSONEncoder().encode(preferences.corrected), to: directory.appendingPathComponent("preferences.json"))
            configuration = preferences.corrected
        }
        recovery.entries[key]?.configuration = records[entry.requestID ?? UUID()]?.configuration ?? repair.corrected
        recovery.entries[key]?.configurationRepair = nil
        if let id = entry.requestID { records[id]?.cleanupFailure = nil; recoveryID = id }
        try await persist()
    }

    private func proposedMaintenanceConfiguration(_ entry: RequestRecoveryStore.Entry) -> ShaderRequestConfiguration? {
        guard entry.requestID == nil, entry.disposition != .detach, entry.maintenanceRepair == nil, let operation = try? RequestWorkerOperation.read(in: URL(fileURLWithPath: entry.journal)),
              ["preflight", "publication"].contains(operation.mode), let target = operation.target else { return nil }
        var proposed = operation.binding.flatMap { try? JSONDecoder().decode(ShaderRequestConfiguration.self, from: $0.replacement) } ?? configuration
        proposed.repository = target.repository; proposed.checkoutID = target.checkoutID
        return proposed
    }
    public func repairMaintenanceRecovery(_ id: UUID, configuration candidate: ShaderRequestConfiguration) async throws {
        guard activeID == nil, !maintenanceBusy, let entry = recovery.entries.values.first(where: { $0.id == id }),
              entry.requestID == nil, entry.disposition != .detach, entry.configurationRepair == nil else { throw RequestWorkerOwnershipError() }
        let lease = try beginMaintenance(); defer { endMaintenance(lease) }
        try await drainReconciliation(lease: lease)
        let journal = URL(fileURLWithPath: entry.journal)
        let original: RequestWorkerOperation
        if let pending = entry.maintenanceRepair { original = pending.operation }
        else { original = try await persistence.perform { guard let operation = try RequestWorkerOperation.read(in: journal) else { throw RequestWorkerOwnershipError() }; return operation } }
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
        let priorBytes = try? BoundedCatalogReader(root: directory).read("recovery.json", limit: CatalogLimits.manifestBytes).bytes
        do { try await persistRecovery() }
        catch {
            // A writer can fail after atomic replacement. Only discard a proposal when
            // the last committed file is provably unchanged; otherwise keep it pending.
            if let priorBytes, (try? BoundedCatalogReader(root: directory).read("recovery.json", limit: CatalogLimits.manifestBytes).bytes) == priorBytes {
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
            try await persistence.perform { try RequestJournalWriter.archive(in: journal, id: repair.archiveID) }
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
        try await persistRecovery()
        cancelPublicationRequests(); activeProcess?.stop()
        try await persist()
        try await writeFile(JSONEncoder().encode(configuration), to: directory.appendingPathComponent("preferences.json"))
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
        do { try await waitForWorker(process) }
        catch {
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
            if !(error is CancellationError) {
                let target = (try? Self.savedConfiguration(in: journal)) ?? (RequestProcessIdentity.evidenceExists(journal.appendingPathComponent("configuration.json")) ? nil : configuration)
                await holdForRecovery(journal: journal, configuration: target, error: error)
            }
            throw error
        }
        while true {
            do { try checkExecution(operation) }
            catch {
                if attempt.phase == .initial, ["preflight", "publication"].contains(mode) { try await finishWorkerOperation(attempt, journal: journal) }
                throw error
            }
            let process = workerProcess(); activeProcess = process
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
                try checkExecution(operation)
                guard let completion else { throw ShaderRequestError.unavailable("Worker ended without the required " + mode + " completion event for this attempt.") }
                try await finishWorkerOperation(attempt, journal: journal)
                return WorkerOutcome(attemptID: attemptID, completion: completion)
            } catch {
                let recorded = process.recordedFailure
                let hostFault = recorded is RequestWorkerSupervisionError || recorded is RequestWorkerEvidenceError || recorded is RequestWorkerOwnershipError || recorded is RequestWorkerTeardownError
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
                    if !(error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError || error is RequestWorkerTeardownError || error is RequestPersistence.Fault) {
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
        if let persistenceFailure { throw RequestWorkerEvidenceError(cause: persistenceFailure) }
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
        var visible = records
        if let change = storageChange, change.id != RequestStorageContext.mutation {
            for id in change.ids { visible[id] = change.previous[id] }
        }
        return visible.values.map(\.status).sorted { $0.createdAt > $1.createdAt }
    }
    public func updates() -> AsyncStream<[ShaderRequestStatus]> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(allJobs())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func persist(progress: Bool = false) async throws {
        await waitForStorageChange()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let files: [RequestPersistence.File] = [
            .init(url: directory.appendingPathComponent("detached-checkouts.json"), bytes: try encoder.encode(detachedOwners)),
            .init(url: directory.appendingPathComponent("journal.json"), bytes: try encoder.encode(records.values.sorted { $0.status.id.uuidString < $1.status.id.uuidString })),
            .init(url: directory.appendingPathComponent("recovery.json"), bytes: try recovery.encoded())]
        if progress {
            persistenceRevision &+= 1; let epoch = persistenceEpoch
            persistence.enqueueProgress(.init(revision: persistenceRevision, files: files)) { [weak self] error in
                Task { await self?.progressPersistenceFailed(error, epoch: epoch) }
            }
        } else { try await commitFiles(files) }
        emitUpdates()
    }
    private func emitUpdates() { for observer in observers.values { observer.yield(allJobs()) } }
    private func update(_ id: UUID, stage: ShaderRequestStatus.Stage, message: String, progress: Bool = false) async throws {
        records[id]?.status.stage = stage; records[id]?.status.message = message
        records[id]?.status.updatedAt = Date(); records[id]?.status.sequence &+= 1
        try await persist(progress: progress)
    }
    public func verify(configuration candidate: ShaderRequestConfiguration) async throws {
        guard !maintenanceBusy else { throw ShaderRequestError.unavailable("Wait for active checkout maintenance to finish.") }
        try await changingStorage("verify setup", configuration: true) { try await $0.verifyAccepted(configuration: candidate) }
    }
    private func verifyAccepted(configuration candidate: ShaderRequestConfiguration) async throws {
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
        if !Self.samePublicationCheckout(configuration, candidate) { cancelPublicationRequests() }
        configuration = candidate; configuration.enabled = true
        let paths = Self.canonicalRepositories([candidate.repository] + detachedOwners.map(\.repository))
        detachedOwners.removeAll { Self.matchesDetachedCheckout(candidate, acknowledgement: $0, paths: paths) }
        if !initialized { initialized = true; schedulingActive = true }
        try await persist()
        try await writeFile(JSONEncoder().encode(configuration), to: directory.appendingPathComponent("preferences.json"))
        setupMessage = "Ready for shader requests"
        resolvePublicationFailure()
        try await persist(); kick()
    }
    public func canDisableRequests() -> Bool {
        initialized && pendingCommits == 0 && (storageChange == nil || storageChange?.id == RequestStorageContext.mutation) && activeID == nil && !maintenanceBusy && !records.values.contains(where: { !$0.status.stage.terminal || $0.cleanupPending == true })
    }
    public func disable() async throws {
        try await changingStorage("disable requests", configuration: true) { try await $0.disableAccepted() }
    }
    private func disableAccepted() async throws {
        guard canDisableRequests() else {
            throw ShaderRequestError.unavailable("Requests are still in progress.")
        }
        configuration.enabled = false; setupMessage = "Shader requests are disabled."
        cancelPublicationRequests()
        try await writeFile(JSONEncoder().encode(configuration), to: directory.appendingPathComponent("preferences.json"))
        try await persist()
    }
    public func cancelQueued(_ id: UUID) async throws {
        try await changingStorage("cancel request", ids: [id]) { try await $0.cancelQueuedAccepted(id) }
    }
    private func cancelQueuedAccepted(_ id: UUID) async throws {
        guard records[id]?.status.stage == .queued, activeID != id else {
            throw ShaderRequestError.unavailable("Only queued requests can be cancelled.")
        }
        try await update(id, stage: .cancelled, message: "Cancelled on the Mac")
        kick()
    }
    public func deleteFinished(_ id: UUID) async throws {
        try await changingStorage("delete record", ids: [id]) { try await $0.deleteFinishedAccepted(id) }
    }
    private func deleteFinishedAccepted(_ id: UUID) async throws {
        guard !recovery.entries.values.contains(where: { $0.configurationRepair?.requestIDs.contains(id) == true }) else { throw ShaderRequestError.unavailable("Finish the pending configuration repair before deleting this record.") }
        guard !recovery.entries.values.contains(where: { $0.requestID == id }), !Self.hasProcessEvidence(folder(id)), records[id]?.status.stage.terminal == true, records[id]?.cleanupPending != true, activeID != id else { throw ShaderRequestError.invalidRequest }
        records[id]?.deletionPending = true
        try await persist()
        if let change = storageChange {
            await persistence.accept(change.id)
            try await persistence.begin(change.id, operation: "finish accepted record deletion")
            storageChange?.previous[id] = records[id]
        }
        await finishDeletion(id)
    }
    private func finishDeletion(_ id: UUID) async {
        guard records[id]?.deletionPending == true else { return }
        let tombstone = records[id]
        do {
            guard activeID != id, !Self.hasProcessEvidence(folder(id)),
                  !recovery.entries.values.contains(where: { $0.requestID == id || $0.configurationRepair?.requestIDs.contains(id) == true }) else {
                throw RequestWorkerOwnershipError()
            }
            let job = folder(id)
            try await persistence.perform { if RequestProcessIdentity.evidenceExists(job) { try FileManager.default.removeItem(at: job) } }
            records[id] = nil
            try await persist()
        } catch {
            records[id] = tombstone; records[id]?.deletionFailure = error.localizedDescription
            if !(error is RequestPersistence.Fault) { try? await persist() }
            emitUpdates()
        }
    }
    public func revoke(_ deviceID: String) async throws {
        for id in records.keys where records[id]?.status.deviceID == deviceID && records[id]?.status.stage.terminal == false {
            records[id]?.revoked = true
            if records[id]?.status.stage == .queued, activeID != id {
                try await update(id, stage: .cancelled, message: "TV access was revoked")
            } else if activeID != id {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                try await update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
            }
        }
        try await persist(); kick()
    }

    public func control(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        if ["requestSubmit", "requestAnswer", "requestActivated", "requestDelivery"].contains(operation) {
            let ids = Set([payload.request?.id, payload.requestID].compactMap { $0 })
            return try await changingStorage(operation, ids: ids) { try await $0.controlAccepted(operation: operation, payload: payload, deviceID: deviceID) }
        }
        return try await controlAccepted(operation: operation, payload: payload, deviceID: deviceID)
    }
    private func controlAccepted(operation: String, payload: ShaderRequestControl, deviceID: String) async throws -> ShaderRequestControlReply {
        try await load()
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
            try await writeFile(JSONEncoder().encode(request), to: job.appendingPathComponent("request.json"))
            var lightweight = request
            lightweight.context.source = ""; lightweight.context.screenshot = Data()
            records[request.id] = Record(status: ShaderRequestStatus(request: lightweight, deviceID: deviceID), configuration: configuration)
            try await persist() // Acknowledgement follows durable acceptance.
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
                    try await update(id, stage: .queued, message: "Refreshing latest committed result for this TV")
                    kick()
                }
            } else if operation == "requestAnswer" {
                guard record.status.stage == .awaitingClarification, let answer = payload.answer,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 16_384 else {
                    throw ShaderRequestError.invalidRequest
                }
                try await writeFile(JSONEncoder().encode(answer), to: folder(id).appendingPathComponent("answer.json"))
                records[id]?.status.clarification = nil
                try await update(id, stage: .queued, message: "Ready to continue after clarification")
                kick()
            } else if record.status.stage == .awaitingActivation {
                if let diagnostic = payload.diagnostic {
                    guard diagnostic.utf8.count <= 16_384 else { throw ShaderRequestError.invalidRequest }
                    try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": record.status.result?.shaderID ?? "", "diagnostic": diagnostic])
                        .write(to: folder(id).appendingPathComponent("repair.json"), options: .atomic)
                    try await update(id, stage: .repairing, message: "Repairing the TV activation error")
                    kick()
                } else {
                    guard (record.status.request.purpose == .performance && payload.sourceHash == nil) ||
                          (payload.sourceHash.map({ CatalogHash.isSHA($0) }) == true && payload.sourceHash == record.status.result?.deliveredSourceHash) else {
                        throw ShaderRequestError.invalidRequest
                    }
                    records[id]?.status.result?.deliveredSourceHash = payload.sourceHash
                    try await update(id, stage: .completed, message: record.status.result?.summary ?? "Request completed")
                }
            }
        }
        return try await reply(deviceID: deviceID, requestID: payload.requestID)
    }
    private func reply(deviceID: String, requestID: UUID?) async throws -> ShaderRequestControlReply {
        let owned = allJobs().filter { $0.deviceID == deviceID }
        let jobs = requestID.map { id in owned.filter { $0.id == id } } ?? owned.filter { !$0.stage.terminal }
        return ShaderRequestControlReply(enabled: configurationValue().enabled && recoveryBlocker == nil,
                                        message: recoveryBlocker ?? (configuration.enabled ? "Ready for shader requests" : setupMessage), jobs: jobs,
                                        publicationRevision: await catalog.publicationRevisionValue())
    }
    private func kick() {
        if let persistenceFailure { failPendingPublicationForRecovery(persistenceFailure); return }
        guard loaded, initialized, !suspended, !maintenanceBusy, activeID == nil, workerTask == nil else { return }
        if storageChange != nil || pendingCommits != 0 { schedulingDeferred = true; return }
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
        activeID = id
        workerTask = Task { [weak self] in await self?.runScheduledWork(id: id, operation: operation.id, work: work) }
    }
    private func runScheduledWork(id: UUID, operation: UUID, work: ScheduledWork) async {
        do {
            try checkExecution(operation)
            try await writeFile(JSONEncoder().encode(id), to: directory.appendingPathComponent("active.json"))
            records[id]?.executionID = operation; records[id]?.interrupted = false
            if case .execute = work { try await update(id, stage: .implementing, message: "Preparing the managed checkout") }
            else { try await persist() }
            try checkExecution(operation)
            switch work {
            case .cleanup(let id): await cleanup(id, operation: operation)
            case .execute(let id): await execute(id, operation: operation)
            case .publication: break
            }
        } catch {
            if !(error is CancellationError) && !(error is RequestPersistence.Fault) {
                await holdForRecovery(journal: folder(id), configuration: records[id]?.configuration, error: error)
            }
            finishWorker(id)
        }
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
            records[id]?.cleanupPending = false; records[id]?.cleanupFailure = nil
            if record.status.result != nil, record.status.stage == .awaitingActivation || record.status.stage == .completed {
                try await update(id, stage: record.status.stage, message: record.status.message)
            } else { try await update(id, stage: .failed, message: record.cleanupMessage ?? "Owned checkout cleanup completed; see the retained request diagnostic") }
        } catch {
            if error is RequestWorkerEvidenceError || error is RequestWorkerOwnershipError || error is RequestWorkerTeardownError || error is RequestWorkerSupervisionError || error is RequestPersistence.Fault {
                await holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            }
            if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupFailure = error.localizedDescription
                setupMessage = "Checkout recovery is required. Correct the saved folder/tool paths and retry cleanup, or detach the checkout."
                try? await update(id, stage: .failed, message: "Cleanup failed: \(error.localizedDescription). \(setupMessage)")
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
                    if records[id]?.revoked == true {
                        records[id]?.cleanupPending = true
                        records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
                    }
                    records[id]?.status.clarification = ShaderClarification(question: event.question ?? "Please clarify the request", options: event.options ?? [])
                    try await update(id, stage: records[id]?.revoked == true ? .failed : .awaitingClarification,
                               message: records[id]?.revoked == true ? "Discarding revoked unpublished work" : "Waiting for a TV answer")
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
                    records[id]?.status.result = result
                    if let commit = result.commitSHA { deliveredCommits.insert(commit) }
                    if records[id]?.revoked == true {
                        try await update(id, stage: .failed, message: "Pushed successfully; TV access was revoked")
                        return
                    }
                    guard let output = publication.catalog.shaders.first(where: { $0.id == result.shaderID }) else {
                        try JSONEncoder().encode(["attemptID": UUID().uuidString, "shaderID": result.shaderID, "diagnostic": "The committed output was removed before TV delivery. Recreate it under a fresh unused ID."])
                            .write(to: job.appendingPathComponent("repair.json"), options: .atomic)
                        try await update(id, stage: .repairing, message: "Recreating the output removed before delivery")
                        return
                    }
                    records[id]?.status.result?.deliveredSourceHash = output.sourceHash
                    try await update(id, stage: records[id]?.revoked == true ? .failed : .awaitingActivation,
                               message: records[id]?.revoked == true ? "Pushed successfully; TV access was revoked" : "Waiting for the TV to play the result")
                default: break
                }
            }
            try checkExecution(operation)
        } catch {
            if error is RequestWorkerTeardownError || error is RequestWorkerOwnershipError || error is RequestWorkerEvidenceError || error is RequestWorkerSupervisionError || error is RequestPersistence.Fault {
                await holdForRecovery(journal: folder(id), configuration: record.configuration, error: error)
            } else if execution?.interrupted == false, records[id]?.detached != true {
                records[id]?.cleanupPending = true
                records[id]?.cleanupMessage = error.localizedDescription
                try? await update(id, stage: .failed, message: error.localizedDescription)
            }
        }
        if records[id]?.revoked == true, records[id]?.status.stage.terminal == false, records[id]?.detached != true {
            records[id]?.cleanupPending = true
            records[id]?.cleanupMessage = "TV access was revoked; any pushed commit remains"
            try? await update(id, stage: .failed, message: "TV access was revoked; checkout cleanup is pending")
        }
        if let preparedID { await catalog.discard(preparedID); self.preparedID = nil }
        finishWorker(id)
    }
    public func suspend() async {
        suspended = true; execution?.interrupted = true; activeProcess?.stop()
        if let id = activeID {
            records[id]?.interrupted = true
            if records[id]?.status.stage.terminal == false {
                try? await update(id, stage: .repairing, message: "Waiting for the Mac to resume")
            } else { try? await persist() }
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
