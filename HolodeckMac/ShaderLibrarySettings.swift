import AppKit
import SwiftUI
import Observation
import HolodeckCore

@MainActor @Observable
final class MacLibraryModel {
    let requests: MacRequestsModel
    var folder: URL?
    private var localReloading = false
    private var servicePublishing = false
    var isReloading: Bool { localReloading || servicePublishing }
    private var publicationOperationSequence: UInt64 = 0
    private var publicationFailureSequence: UInt64?
    private var publicationGeneration: UUID?
    private var publicationResolvedSequence: UInt64 = 0
    private enum ErrorOrigin: Hashable { case folder, publication, manualReload, server, approval, revocation }
    private var errors: [ErrorOrigin: String] = [:]
    private var representedCatalogFailure: (origin: ErrorOrigin, id: UUID)?
    var representedCatalogFailureID: UUID? { representedCatalogFailure?.id }
    func representsCatalogFailure(_ failure: ViewerSession.Failure) -> Bool {
        if case .catalog = failure.operation { return representedCatalogFailure?.id == failure.id }
        return false
    }
    var error: String? { errors[.folder] ?? errors[.server] ?? errors[.manualReload] ?? errors[.publication] ?? errors[.approval] ?? errors[.revocation] }
    var previewWarnings: [ShaderPreviewWarning] = []
    var serverState = LocalServerState()
    @ObservationIgnored private let catalog: DirectoryCatalog
    @ObservationIgnored private let server: LocalCatalogServer
    @ObservationIgnored private let session: ViewerSession
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    #if DEBUG
    var exposesFailureAssociationTests = false
    func injectUnrelatedCatalogFailureForTesting(revocation: Bool) {
        guard exposesFailureAssociationTests else { return }
        clearError(from: .folder); clearError(from: .manualReload); clearError(from: .publication)
        folder = folder ?? FileManager.default.temporaryDirectory
        setError(revocation ? "Previous revocation failed" : "Previous approval failed", from: revocation ? .revocation : .approval)
        session.failure = .init(message: "Independent catalog failure", operation: .catalog)
    }
    var isTestingReloadHeld = false
    @ObservationIgnored private var testingReloadContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var holdsNextReloadForTesting = false
    var testingSelectionFailure: String? { session.selectionFailure?.message }
    #endif

    init(catalog: DirectoryCatalog, session: ViewerSession, defaults: UserDefaults?, testingNamespace: String? = nil, testingAdvertises: Bool = false) {
        requests = MacRequestsModel(catalog: catalog, defaults: defaults, namespace: testingNamespace)
        self.catalog = catalog; self.session = session; self.defaults = defaults
        #if DEBUG
        MacInspectionLifecycle.snapshot.libraryCreations += 1
        server = testingNamespace.map { LocalCatalogServer.testing(catalog: catalog, namespace: $0, advertise: testingAdvertises) } ?? LocalCatalogServer(catalog: catalog)
        exposesFailureAssociationTests = testingNamespace != nil && UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac").hasExplicitStorageSuite && ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_ERROR_ASSOCIATION"] == "1"
        holdsNextReloadForTesting = testingNamespace != nil && UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac").contains("--ui-test-hold-library-reload")
        #else
        server = LocalCatalogServer(catalog: catalog)
        #endif
        let server = server
        let requestService = requests.service
        Task { await server.setRequestService(requestService) }
        requests.onPublication = { [weak self] status in
            guard let self, self.requests.configuration.enabled else { return }
            self.ready = true; self.previewWarnings = status.warnings
            if self.publicationFailureSequence == nil { self.clearError(from: .publication) }
            Task {
                await self.session.refresh(force: true).value
                if !self.sleeping { try? await self.startServer() }
            }
        }
        requests.onPublicationEvent = { [weak self] event in self?.applyPublicationEvent(event) }
        updates = Task { [weak self] in
            for await state in await server.updates() { self?.serverState = state }
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(sleeping) }
            })
        }
        var refreshBookmark = false
        #if DEBUG
        let fixture = UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac")
        let fixtureBookmark = testingNamespace != nil && fixture.hasExplicitStorageSuite
            ? ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_SHADER_BOOKMARK"].flatMap { Data(base64Encoded: $0) } : nil
        #else
        let fixtureBookmark: Data? = nil
        #endif
        if let bookmark = fixtureBookmark ?? defaults?.data(forKey: "holodeck.shaderFolderBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                folder = url; requests.proposeRepository(url); refreshBookmark = stale
            } catch { self.setError("Choose your shader folder again: \(error.localizedDescription)", from: .folder) }
        }
        let shouldRefreshBookmark = refreshBookmark
        localReloading = true
        Task {
            do {
                try await requests.initialized()
                if !requests.configuration.repository.isEmpty {
                    folder = URL(fileURLWithPath: requests.configuration.repository)
                }
                var restored = false
                do { restored = try await catalog.cached() != nil }
                catch { self.setError("Couldn’t restore the previous shader library: \(error.localizedDescription)", from: .publication) }
                if !restored, requests.configuration.enabled {
                    try await requests.service.ensurePublication()
                    restored = await catalog.publicationRevisionValue() != nil
                    if let status = await requests.service.publicationStatus() { previewWarnings = status.warnings }
                }
                if restored {
                    ready = true
                    await session.refresh(force: true).value
                    if !sleeping { try await startServer() }
                }
            } catch { showPublicationError(error, prefix: "Couldn’t rebuild the shader library: ") }
            await requests.service.activateScheduling()
            localReloading = false
            if !requests.configuration.enabled, folder != nil { reload(refreshBookmark: shouldRefreshBookmark) }
        }
    }

    isolated deinit {
        updates?.cancel(); scopedURL?.stopAccessingSecurityScopedResource()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func chooseFolder() {
        guard !isReloading, !requests.configuration.enabled, !requests.hasUnfinishedJobs else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the HolodeckShaders folder containing index.json, shared, and shaders."
        panel.prompt = "Choose Shader Folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url, saveBookmark: true)
        }
    }
    func reload(refreshBookmark: Bool = false) {
        guard !requests.configuration.enabled, !requests.hasUnfinishedJobs else { return }
        guard let folder else { chooseFolder(); return }
        load(folder, saveBookmark: refreshBookmark)
    }
    func rebuildPublication() {
        guard !isReloading else { return }
        localReloading = true
        Task {
            defer { localReloading = false }
            do {
                try await requests.initialized()
                try await requests.service.ensurePublication(force: true)
                if let status = await requests.service.publicationStatus() { previewWarnings = status.warnings }
                ready = true
                await session.refresh(force: true).value
                if !sleeping { try await startServer() }
            } catch { showPublicationError(error) }
        }
    }
    var canCancelPreparation: Bool { servicePublishing }
    func cancelLibraryPreparation() { Task { await requests.service.cancelPublication() } }
    private func applyPublicationEvent(_ event: ShaderRequestPublicationEvent) {
        if publicationGeneration != event.generation {
            publicationGeneration = event.generation; publicationOperationSequence = 0; publicationResolvedSequence = 0
            clearError(from: .publication)
        }
        guard event.operation.sequence >= publicationOperationSequence else { return }
        publicationOperationSequence = event.operation.sequence
        servicePublishing = event.operation.phase == .preparing
        if let failure = event.unresolvedFailure {
            publicationFailureSequence = failure.operationSequence
            setError(failure.message, from: .publication)
        } else {
            publicationResolvedSequence = event.operation.sequence
            clearError(from: .publication)
        }
        applyPublicationOperation(event.operation)
    }
    private func load(_ url: URL, saveBookmark: Bool) {
        guard !isReloading, !requests.configuration.enabled, !requests.hasUnfinishedJobs else { return }
        localReloading = true; clearError(from: .folder); clearError(from: .manualReload)
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { localReloading = false; if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                // Prepare the bookmark before replacing the current publication.
                let bookmark: Data?
                do { bookmark = saveBookmark ? try url.bookmarkData(options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil) : nil }
                catch { setError(error.localizedDescription, from: .folder); throw error }
                let result = try await requests.reloadRepository(url)
                previewWarnings = result.previewWarnings; clearError(from: .publication)
                if let bookmark { defaults?.set(bookmark, forKey: "holodeck.shaderFolderBookmark") }
                if folder != url {
                    scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
                    if url.startAccessingSecurityScopedResource() { scopedURL = url }
                }
                folder = URL(fileURLWithPath: requests.configuration.repository); ready = true
                await session.refresh(force: true).value
                #if DEBUG
                if holdsNextReloadForTesting {
                    holdsNextReloadForTesting = false
                    await withCheckedContinuation { continuation in
                        testingReloadContinuation = continuation; isTestingReloadHeld = true
                    }
                }
                #endif
                if !sleeping { try await startServer() }
            } catch { setError(error.localizedDescription, from: .manualReload) }
        }
    }
    private func applyPublicationOperation(_ status: ShaderRequestPublicationOperationStatus) {
        guard status.sequence >= publicationOperationSequence else { return }
        publicationOperationSequence = status.sequence
        servicePublishing = status.phase == .preparing
        if let failure = status.failure { showPublicationError(failure) }
        guard let revision = status.revision else { return }
        Task {
            let current = await catalog.publicationRevisionValue()
            guard publicationOperationSequence == status.sequence, revision == current else { return }
            clearError(from: .publication)
            if !ready {
                ready = true
                await session.refresh(force: true).value
                if !sleeping { try? await startServer() }
            }
        }
    }
    private func showPublicationError(_ error: Error, prefix: String = "") {
        guard !(error is CancellationError) else { return }
        if let failure = error as? ShaderRequestPublicationFailure {
            guard publicationGeneration == nil || failure.generation == publicationGeneration else { return }
            guard failure.operationSequence > publicationResolvedSequence,
                  failure.operationSequence >= (publicationFailureSequence ?? 0) else { return }
            publicationFailureSequence = failure.operationSequence
        } else { publicationFailureSequence = nil }
        setError(prefix + error.localizedDescription, from: .publication)
    }
    private func setError(_ message: String, from origin: ErrorOrigin) {
        errors[origin] = message
        if origin == .publication || origin == .manualReload || origin == .folder, let failure = session.catalogFailure {
            representedCatalogFailure = (origin, failure.id)
        }
    }
    private func clearError(from origin: ErrorOrigin) {
        errors[origin] = nil
        if representedCatalogFailure?.origin == origin { representedCatalogFailure = nil }
        if origin == .publication { publicationFailureSequence = nil }
    }
    private func startServer() async throws {
        #if DEBUG
        MacInspectionLifecycle.snapshot.serverStartAttempts += 1
        #endif
        do { try await server.start(); clearError(from: .server) }
        catch { setError(error.localizedDescription, from: .server); throw error }
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        Task {
            if value { await requests.service.suspend(); await server.stop() }
            else {
                await requests.service.resume()
                if ready { try? await startServer() }
            }
        }
    }
    #if DEBUG
    func finishTestingReload() {
        isTestingReloadHeld = false
        testingReloadContinuation?.resume(); testingReloadContinuation = nil
    }
    #endif
    func approve(_ id: UUID) { Task { do { try await server.approve(id); clearError(from: .approval) } catch { self.setError(error.localizedDescription, from: .approval) } } }
    func decline(_ id: UUID) { Task { await server.decline(id) } }
    func revoke(_ id: String) { Task { do { try await server.revoke(id); clearError(from: .revocation) } catch { self.setError(error.localizedDescription, from: .revocation) } } }
}

struct ShaderLibrarySettings: View {
    @Bindable var library: MacLibraryModel
    var body: some View {
        Form {
            Section("Shader Library") {
                Text(library.folder?.path ?? "Choose a shader folder to begin.").textSelection(.enabled)
                    .accessibilityIdentifier("shader-folder-path")
                HStack {
                    Button("Choose Folder…", action: library.chooseFolder).accessibilityIdentifier("choose-shader-folder")
                    Button("Reload Shaders") { library.reload() }.disabled(library.folder == nil)
                        .accessibilityIdentifier("reload-shaders")
                    if library.isReloading { ProgressView().controlSize(.small).accessibilityIdentifier("shader-library-reloading") }
                }.disabled(library.isReloading || library.requests.configuration.enabled || library.requests.hasUnfinishedJobs)
                if library.folder != nil {
                    Button("Rebuild Library", action: library.rebuildPublication)
                        .disabled(library.isReloading || library.requests.hasUnfinishedJobs)
                        .accessibilityIdentifier("rebuild-shader-library")
                    if library.canCancelPreparation {
                        Button("Cancel Library Preparation", action: library.cancelLibraryPreparation)
                            .accessibilityIdentifier("cancel-library-preparation")
                    }
                }
                HStack { Text(library.serverState.message); Spacer() }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("shader-serving-status")
                if let error = library.error {
                    // Recreate the selectable native text when the diagnostic changes.
                    HStack { Text(error).foregroundStyle(.red).textSelection(.enabled).id(error); Spacer() }
                        .accessibilityElement(children: .combine).accessibilityLabel(error).accessibilityIdentifier("shader-library-error")
                }
                ForEach(library.previewWarnings, id: \.shaderID) { warning in
                    Text("\(warning.shaderID): using a gradient preview. \(warning.message)")
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("shader-preview-warning-" + warning.shaderID)
                }
                Text("Changes are shared after Reload Shaders. Previews are generated and cached on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                #if DEBUG
                if library.exposesFailureAssociationTests {
                    Button("Inject Approval Catalog Failure") { library.injectUnrelatedCatalogFailureForTesting(revocation: false) }.accessibilityIdentifier("test-approval-catalog-failure")
                    Button("Inject Revocation Catalog Failure") { library.injectUnrelatedCatalogFailureForTesting(revocation: true) }.accessibilityIdentifier("test-revocation-catalog-failure")
                }
                if library.isTestingReloadHeld {
                    if let failure = library.testingSelectionFailure {
                        Text(failure).accessibilityIdentifier("test-reload-selection-failure")
                    }
                    Button("Finish Test Reload", action: library.finishTestingReload)
                        .accessibilityIdentifier("finish-test-library-reload")
                }
                #endif
            }
            RequestSettingsView(model: library.requests)
            Section("Pairing Approvals from Apple TV") {
                if library.serverState.pending.isEmpty { Text("No pending requests.").foregroundStyle(.secondary) }
                ForEach(library.serverState.pending) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.name).bold()
                        Text("Pairing code: \(request.code)").font(.title2.monospacedDigit())
                        Text("Approve only when this code matches the code shown on your TV.").font(.caption)
                        HStack {
                            Button("Approve") { library.approve(request.id) }
                            Button("Decline") { library.decline(request.id) }
                        }
                    }.accessibilityIdentifier("tv-approval-request")
                }
            }
            Section("Approved TVs") {
                if library.serverState.approved.isEmpty { Text("No approved TVs.").foregroundStyle(.secondary) }
                ForEach(library.serverState.approved) { tv in
                    HStack { Text(tv.name); Spacer(); Button("Revoke") { library.revoke(tv.id) } }
                }
            }
        }.formStyle(.grouped).frame(width: 600, height: 560)
    }
}
