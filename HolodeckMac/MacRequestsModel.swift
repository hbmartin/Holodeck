import AppKit
import HolodeckCore
import Observation

@MainActor @Observable
final class MacRequestsModel {
    var configuration: ShaderRequestConfiguration
    var jobs: [ShaderRequestStatus] = []
    var recoveries: [ShaderRequestRecoveryStatus] = []
    private var pendingCleanup = false
    var canDisableRequests = false
    var checking = false
    var message = "Configure Codex and enable requests."
    var error: String?
    var onPublication: (@MainActor (ShaderRequestPublicationStatus) -> Void)?
    var onPublicationEvent: (@MainActor (ShaderRequestPublicationEvent) -> Void)?
    let service: ShaderRequestService
    let directory: URL
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var publicationObservation: Task<Void, Never>?
    @ObservationIgnored private var pendingRepository: URL?
    private struct Selection { let configuration: ShaderRequestConfiguration; let publication: CatalogReloadResult? }
    @ObservationIgnored private var selectionTask: Task<Selection, Error>?
    @ObservationIgnored private var selectionIsProposal = false
    @ObservationIgnored private var selectionID: UUID?
    @ObservationIgnored private var didInitialize = false
    @ObservationIgnored private var setupRevision: UInt64 = 0
    @ObservationIgnored private var acceptedSetup: ShaderRequestConfiguration?
    @ObservationIgnored private var backedUpSetup: ShaderRequestConfiguration?
    @ObservationIgnored private var publicationSequence: UInt64?
    @ObservationIgnored private var initialization: Task<ShaderRequestConfiguration, Error>?

    init(catalog: DirectoryCatalog, defaults: UserDefaults?, namespace: String?) {
        self.defaults = defaults
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace.map { "Holodeck/Requests-tests-\($0)" } ?? "Holodeck/Requests")
        #if DEBUG
        let fixture = UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac")
        // The sandboxed UI runner and app must inspect the same isolated request evidence.
        if namespace != nil, fixture.hasExplicitStorageSuite,
           let path = ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_REQUEST_DIRECTORY"] {
            directory = URL(fileURLWithPath: path)
        } else { directory = defaultDirectory }
        #else
        directory = defaultDirectory
        #endif
        service = ShaderRequestService(catalog: catalog, directory: directory)
        let saved = (try? Data(contentsOf: directory.appendingPathComponent("preferences.json"))).flatMap { try? ShaderRequestConfiguration.decodePreferences($0) }
        let fallback = defaults?.data(forKey: "holodeck.requestConfiguration").flatMap { try? ShaderRequestConfiguration.decodePreferences($0) }
        configuration = saved ?? fallback ?? .init()
        configuration.shaderTool = Bundle.main.resourceURL?.appendingPathComponent("Tools/holodeck-shader-tool").path ?? ""
        #if DEBUG
        if namespace != nil, fixture.hasExplicitStorageSuite, let journal = ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_REQUEST_JOURNAL"],
           let bytes = journal.data(using: .utf8),
           let records = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: directory.appendingPathComponent("journal.json"), options: .atomic)
            for record in records {
                if let status = record["status"] as? [String: Any], let id = status["id"] as? String, UUID(uuidString: id) != nil {
                    try? FileManager.default.createDirectory(at: directory.appendingPathComponent(id), withIntermediateDirectories: true)
                }
            }
        }
        #endif
        #if DEBUG
        holdsStartupSelection = namespace != nil && fixture.hasExplicitStorageSuite && fixture.contains("--ui-test-hold-startup-selection")
        #endif
        let service = service, config = configuration
        let initialization = Task {
            try await service.initialize(configuration: config)
            return await service.configurationValue()
        }
        self.initialization = initialization
        observation = Task { [weak self] in
            do { _ = try await initialization.value }
            catch { self?.error = error.localizedDescription }
            for await state in await service.localUpdates() {
                guard let self else { break }
                self.jobs = state.jobs; self.pendingCleanup = state.pendingCleanup
                self.recoveries = state.recoveries; self.canDisableRequests = state.canDisableRequests
                self.applyAcceptedSetup(state.setup)
            }
        }
        publicationObservation = Task { [weak self] in
            _ = try? await initialization.value
            var generation: UUID?
            for await event in await service.publicationUpdates() {
                guard let self else { break }
                if generation != event.generation { generation = event.generation; self.publicationSequence = nil }
                self.onPublicationEvent?(event)
                if let status = event.publication, status.sequence != self.publicationSequence,
                   await service.isCurrentPublication(status, generation: event.generation) {
                    self.publicationSequence = status.sequence; self.onPublication?(status)
                }
            }
        }
    }
    isolated deinit { observation?.cancel(); publicationObservation?.cancel() }
    private func refreshAcceptedSetup() async { applyAcceptedSetup(await service.setupSnapshot()) }
    private func applyAcceptedSetup(_ snapshot: ShaderRequestSetupSnapshot) {
        guard snapshot.revision > setupRevision else { return }
        setupRevision = snapshot.revision
        guard snapshot.phase != .blockedInitialization, let accepted = snapshot.configuration else { return }
        if acceptedSetup != accepted {
            if let previous = acceptedSetup {
                // Preserve fields edited while an accepted repository transition was in flight.
                var merged = accepted
                for field: WritableKeyPath<ShaderRequestConfiguration, String> in [\.codex, \.python, \.git, \.shaderTool, \.model, \.reasoning] {
                    if configuration[keyPath: field] != previous[keyPath: field] { merged[keyPath: field] = configuration[keyPath: field] }
                }
                configuration = merged
            } else { configuration = accepted }
            acceptedSetup = accepted
        }
        if snapshot.phase == .requiresVerification { message = "Settings restored. Verify setup to enable requests." }
        if !snapshot.blocked { saveAccepted(accepted) }
    }
    private func saveAccepted(_ accepted: ShaderRequestConfiguration) {
        guard backedUpSetup != accepted else { return }
        defaults?.set(try? JSONEncoder().encode(accepted), forKey: "holodeck.requestConfiguration")
        backedUpSetup = accepted
    }
    private func initializeAcceptedConfiguration() async throws {
        _ = try await initialization?.value
        if !didInitialize { await refreshAcceptedSetup(); didInitialize = true }
    }
    func initialized() async throws {
        try await initializeAcceptedConfiguration()
        while true {
            if let task = selectionTask, let id = selectionID {
                let proposal = selectionIsProposal
                do { _ = try await finishSelection(task, id: id, proposal: proposal) }
                catch { if !proposal { throw error } }
            } else if let proposal = pendingRepository {
                pendingRepository = nil
                let id = UUID(), service = service
                selectionID = id; selectionIsProposal = true
                selectionTask = Task {
                    #if DEBUG
                    await self.waitForStartupSelectionIfNeeded()
                    #endif
                    try Task.checkCancellation()
                    return Selection(configuration: try await service.selectRepository(proposal), publication: nil)
                }
            } else { return }
        }
    }
    private func finishSelection(_ task: Task<Selection, Error>, id: UUID, proposal: Bool = false) async throws -> Selection {
        defer {
            if selectionID == id { selectionTask = nil; selectionID = nil; selectionIsProposal = false }
        }
        do {
            let result = try await task.value
            if selectionID == id { acceptSelection(result.configuration) }
            return result
        } catch {
            let snapshot = await service.setupSnapshot()
            if selectionID == id {
                if snapshot.phase != .blockedInitialization, !snapshot.blocked, let accepted = snapshot.configuration {
                    acceptSelection(accepted)
                }
                if proposal { self.error = "The proposed shader folder was not accepted: " + error.localizedDescription }
            }
            throw error
        }
    }
    #if DEBUG
    var holdsStartupSelection = false
    var isStartupSelectionHeld = false
    @ObservationIgnored private var startupSelectionContinuation: CheckedContinuation<Void, Never>?
    private func waitForStartupSelectionIfNeeded() async {
        guard holdsStartupSelection else { return }
        holdsStartupSelection = false; isStartupSelectionHeld = true
        await withCheckedContinuation { startupSelectionContinuation = $0 }
        isStartupSelectionHeld = false
    }
    func finishStartupSelection() { startupSelectionContinuation?.resume(); startupSelectionContinuation = nil }
    #endif
    var hasUnfinishedJobs: Bool { pendingCleanup || recoveries.contains { $0.blocksCheckoutWork } || jobs.contains { !$0.stage.terminal } }
    /// A startup bookmark is a proposal until the service accepts it.
    func proposeRepository(_ url: URL) {
        guard !configuration.enabled, !hasUnfinishedJobs else { return }
        pendingRepository = url
    }
    private func acceptSelection(_ accepted: ShaderRequestConfiguration) {
        configuration.repository = accepted.repository; configuration.checkoutID = accepted.checkoutID; configuration.enabled = accepted.enabled
        // Backup only the authoritative configuration, never unrelated editable draft fields.
        saveAccepted(accepted)
    }
    func reloadRepository(_ url: URL) async throws -> CatalogReloadResult {
        try await initializeAcceptedConfiguration()
        if selectionIsProposal || pendingRepository != nil { try await initialized() }
        if let task = selectionTask, let id = selectionID { _ = try? await finishSelection(task, id: id) }
        let id = UUID(), service = service
        selectionID = id; selectionIsProposal = false
        let task = Task {
            let result = try await service.reloadRepository(url)
            return Selection(configuration: result.configuration, publication: result.publication)
        }
        selectionTask = task
        let result = try await finishSelection(task, id: id)
        guard let publication = result.publication else { throw ShaderRequestError.invalidRequest }
        return publication
    }
    func verify() {
        guard !checking else { return }
        checking = true; error = nil; message = "Checking tools, Git access, model and image review…"
        Task {
            defer { checking = false }
            do {
                try await initialized()
                let candidate = configuration
                try await service.verify(configuration: candidate)
                configuration = await service.configurationValue()
                saveAccepted(configuration); message = "Ready for shader requests"
            } catch { self.error = error.localizedDescription; message = "Setup needs attention" }
        }
    }
    func disable() {
        Task {
            do {
                try await service.disable(); configuration.enabled = false
                saveAccepted(await service.configurationValue()); message = "Requests disabled"
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func retryCleanup(_ id: UUID, repository: String, python: String, git: String) {
        checking = true; error = nil
        Task {
            defer { checking = false }
            do {
                try await service.retryCleanup(id, repository: repository, python: python, git: git)
                configuration = await service.configurationValue(); saveAccepted(configuration)
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func repairMaintenance(_ id: UUID, configuration: ShaderRequestConfiguration) {
        checking = true; error = nil
        Task {
            defer { checking = false }
            do { try await service.repairMaintenanceRecovery(id, configuration: configuration) }
            catch { self.error = error.localizedDescription }
        }
    }
    func retryReconciliation() {
        checking = true; error = nil
        Task {
            defer { checking = false }
            do { try await service.retryReconciliation(); await refreshAcceptedSetup() }
            catch { self.error = error.localizedDescription }
        }
    }
    func detach(_ target: ShaderCheckoutDetachTarget) {
        checking = true; error = nil
        Task {
            defer { checking = false }
            do {
                try await service.detachCheckout(target)
                configuration = await service.configurationValue(); saveAccepted(configuration)
                message = "Checkout detached; files and evidence retained. Verify setup to enable requests."
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancel(_ id: UUID) { Task { do { try await service.cancelQueued(id) } catch { self.error = error.localizedDescription } } }
    func delete(_ id: UUID) { Task { do { try await service.deleteFinished(id) } catch { self.error = error.localizedDescription } } }
    func openArtifacts(_ id: UUID) { NSWorkspace.shared.open(directory.appendingPathComponent(id.uuidString)) }
    func logs(_ id: UUID) -> String {
        let file = directory.appendingPathComponent(id.uuidString).appendingPathComponent("worker.log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "Logs appear when the worker starts." }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 80_000 ? end - 80_000 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return error.localizedDescription }
    }
    func frames(_ id: UUID) -> [URL] {
        let root = directory.appendingPathComponent(id.uuidString).appendingPathComponent("evidence")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
    }
}
