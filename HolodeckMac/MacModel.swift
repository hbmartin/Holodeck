import AppKit
import MetalKit
import Dependencies
import HolodeckCore
import Observation

@MainActor @Observable
final class MacModel {
    struct RendererFailure: Identifiable {
        let id = UUID()
        let message: String
    }
    let library: MacLibraryModel?
    let session: ViewerSession
    let favorites: SceneFavorites
    let defaults: UserDefaults?
    let windowAutosaveName: String?
    var query = ""
    var favoritesOnly = false
    var collectionID = "all"
    var mood = ""
    var motion = ""
    var sidebarVisible: Bool {
        didSet { defaults?.set(sidebarVisible, forKey: "holodeck.sidebarVisible") }
    }
    var searchFocusRequest = 0
    var startupError: RendererFailure?
    private(set) var rendererUnavailableReason: String?
    var sleeping = false
    private(set) var renderer: Renderer?
    private(set) var hasAttemptedRendererInstallation = false
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let device: (any MTLDevice)?
    @ObservationIgnored private let compilerFactory: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling
    @ObservationIgnored private let filterCache = SceneFilterCache()
    @ObservationIgnored private let alerts: MacAlertCoordinator

    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?

    init() {
        #if DEBUG
        MacInspectionLifecycle.snapshot.modelCreations += 1
        #endif
        var autosaveName: String? = "HolodeckViewer-live"
        var defaults: UserDefaults? = UserDefaults.standard
        var directoryCatalog: DirectoryCatalog?
        let localCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Holodeck/LocalViewerCache")
        var configuredService: CatalogService?
        var usesDirectory = true
        var libraryTestNamespace: String?
        var testingAdvertises = false
        var metalDevice = MTLCreateSystemDefaultDevice()
        #if DEBUG
        let configuration = UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac")
        let driver = MacUITestDriver(configuration: configuration)
        driver.prepareStorage()
        if let suite = configuration.storageSuite {
            let name = MacUITestDriver.windowAutosaveName(for: suite)
            let cleanup = configuration.contains("--ui-test-cleanup-storage-suite")
            autosaveName = configuration.hasExplicitStorageSuite && !cleanup ? name : nil
            defaults = configuration.makeUserDefaults()
            configuredService = configuration.makeCatalogService()
            usesDirectory = false
            if configuration.contains("--ui-test-local-library"), !cleanup, let cache = configuration.fixtureCacheDirectory {
                let selected = DirectoryCatalog(directory: cache.appendingPathComponent("publications"))
                directoryCatalog = selected
                configuredService = CatalogService(source: selected.source, storage: .disk(at: cache.appendingPathComponent("viewer")))
                usesDirectory = true
                libraryTestNamespace = suite
                testingAdvertises = configuration.contains("--ui-test-local-network")
            }
            if configuration.contains("--ui-test-metal-unavailable") { metalDevice = nil }
        }
        #endif
        if usesDirectory, directoryCatalog == nil { directoryCatalog = DirectoryCatalog() }
        let service = configuredService ?? CatalogService(source: directoryCatalog!.source, storage: .disk(at: localCache))
        self.defaults = defaults
        windowAutosaveName = autosaveName
        self.device = metalDevice
        compilerFactory = { ShaderCompiler(device: $0, pixelFormat: $1) }
        favorites = defaults.map { SceneFavorites(defaults: $0) } ?? .inMemory()
        sidebarVisible = defaults?.object(forKey: "holodeck.sidebarVisible") as? Bool ?? true
        session = ViewerSession(catalogService: service, preferences: defaults.map(ShaderPreferences.userDefaults) ?? .inMemory(), policy: .mac)
        library = usesDirectory ? MacLibraryModel(catalog: directoryCatalog!, session: session, defaults: defaults, testingNamespace: libraryTestNamespace, testingAdvertises: testingAdvertises) : nil
        #if DEBUG
        alerts = MacAlertCoordinator(didPresent: driver.didPresentFailure)
        driver.observeStartupActivation(in: self)
        #else
        alerts = MacAlertCoordinator()
        #endif
        if !usesDirectory { session.refresh() }
        let previewService = service
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        pressure.setEventHandler { @Sendable in Task { await previewService.trimPreviewCaches() } }
        memoryPressure = pressure
        pressure.resume()
    }

    deinit { memoryPressure?.cancel() }

    var filteredScenes: [ShaderDefinition] {
        filterCache.filter(session.catalog, query: query, favoritesOnly: favoritesOnly, favorites: favorites.ids,
                           collectionID: collectionID, mood: mood.isEmpty ? nil : mood, motion: motion.isEmpty ? nil : motion)
    }
    var collections: [CatalogCollection] { session.catalog?.collections ?? [] }
    var moods: [String] { session.catalog?.moods ?? [] }
    var motions: [String] { session.catalog?.motions ?? [] }
    var hasFilters: Bool { collectionID != "all" || !mood.isEmpty || !motion.isEmpty || !query.isEmpty || favoritesOnly }
    func resetFilters() { collectionID = "all"; mood = ""; motion = ""; query = ""; favoritesOnly = false }
    func reconcileFilters() {
        if !collections.contains(where: { $0.id == collectionID }) { collectionID = "all" }
        if !moods.contains(mood) { mood = "" }
        if !motions.contains(motion) { motion = "" }
    }
    var selectedID: String? { session.pendingSelection?.shader.id ?? session.activeShader?.id }

    func installRenderer(in view: MTKView) {
        defer {
            hasAttemptedRendererInstallation = true
            presentFailuresIfNeeded()
        }
        if let renderer {
            renderer.bind(to: view)
            updateActivity()
            return
        }
        do {
            let renderer = try withDependencies {
                $0.context = .live
                $0.metalDevice = device
                $0.shaderCompilerFactory = compilerFactory
            } operation: {
                @Dependency(\.rendererFactory) var factory
                return try factory(view)
            }
            renderer.configure(.mac)
            self.renderer = renderer
            rendererUnavailableReason = nil
            startupError = nil
            view.delegate = renderer
            session.attach(renderer)
            updateActivity()
        } catch {
            let message = error.localizedDescription
            rendererUnavailableReason = message
            if startupError?.message != message {
                startupError = RendererFailure(message: message)
            }
        }
    }

    func updateActivity(appActive: Bool? = nil) {
        session.setActive((appActive ?? NSApp.isActive) && !sleeping && window?.isMiniaturized != true && window?.isVisible == true)
        presentFailuresIfNeeded()
    }
    func presentFailuresIfNeeded() { alerts.presentNextFailure(in: self) }
    func focusSearch() {
        sidebarVisible = true
        searchFocusRequest += 1
    }
    func select(_ id: String?) {
        guard renderer != nil, let id, let shader = session.shaders.first(where: { $0.id == id }) else { return }
        // Selecting the active scene again is an explicit restart/retry after a catalog update.
        if session.pendingSelection?.shader.id != id { session.select(shader) }
    }
}
