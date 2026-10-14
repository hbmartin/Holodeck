import AppKit
import SwiftUI
import Observation
import HolodeckCore

@MainActor @Observable
final class MacLibraryModel {
    let requests: MacRequestsModel
    var folder: URL?
    var isReloading = false
    var error: String?
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
        holdsNextReloadForTesting = testingNamespace != nil && UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac").contains("--ui-test-hold-library-reload")
        #else
        server = LocalCatalogServer(catalog: catalog)
        #endif
        let server = server
        let requestService = requests.service
        Task { await server.setRequestService(requestService) }
        requests.onPublication = { [weak self] in
            guard let self else { return }
            self.ready = true
            Task {
                await self.session.refresh(force: true).value
                if !self.sleeping { try? await self.server.start() }
            }
        }
        updates = Task { [weak self] in
            for await state in await server.updates() { self?.serverState = state }
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(sleeping) }
            })
        }
        if let bookmark = defaults?.data(forKey: "holodeck.shaderFolderBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                folder = url
                requests.setRepository(url)
                isReloading = true
                Task {
                    do {
                        if try await catalog.cached() != nil {
                            ready = true
                            await session.refresh(force: true).value
                            if !sleeping { try await startServer() }
                        }
                    } catch { self.error = "Couldn’t restore the previous shader library: \(error.localizedDescription)" }
                    isReloading = false
                    if !requests.configuration.enabled { reload(refreshBookmark: stale) }
                }
            } catch { self.error = "Choose your shader folder again: \(error.localizedDescription)" }
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
    private func load(_ url: URL, saveBookmark: Bool) {
        guard !isReloading, !requests.configuration.enabled, !requests.hasUnfinishedJobs else { return }
        isReloading = true; error = nil
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            defer { isReloading = false; if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                // Prepare the bookmark before replacing the current publication.
                let bookmark = saveBookmark ? try url.bookmarkData(options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                let result = try await catalog.reload(from: url)
                previewWarnings = result.previewWarnings
                if let bookmark { defaults?.set(bookmark, forKey: "holodeck.shaderFolderBookmark") }
                if folder != url {
                    scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
                    if url.startAccessingSecurityScopedResource() { scopedURL = url }
                }
                folder = url; requests.setRepository(url); ready = true
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
            } catch { self.error = error.localizedDescription }
        }
    }
    private func startServer() async throws {
        #if DEBUG
        MacInspectionLifecycle.snapshot.serverStartAttempts += 1
        #endif
        try await server.start()
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        Task {
            if value { await requests.service.suspend(); await server.stop() }
            else {
                await requests.service.resume()
                if ready { do { try await startServer() } catch { self.error = error.localizedDescription } }
            }
        }
    }
    #if DEBUG
    func finishTestingReload() {
        isTestingReloadHeld = false
        testingReloadContinuation?.resume(); testingReloadContinuation = nil
    }
    #endif
    func approve(_ id: UUID) { Task { do { try await server.approve(id) } catch { self.error = error.localizedDescription } } }
    func decline(_ id: UUID) { Task { await server.decline(id) } }
    func revoke(_ id: String) { Task { do { try await server.revoke(id) } catch { self.error = error.localizedDescription } } }
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
                    if library.isReloading { ProgressView().controlSize(.small) }
                }.disabled(library.isReloading || library.requests.configuration.enabled || library.requests.hasUnfinishedJobs)
                HStack { Text(library.serverState.message); Spacer() }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("shader-serving-status")
                if let error = library.error {
                    HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer() }
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
