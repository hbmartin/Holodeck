import AppKit
import MetalKit
import Dependencies
import HolodeckCore
import Observation

@MainActor @Observable
final class MacModel {
    let session: ViewerSession
    let favorites: SceneFavorites
    let defaults: UserDefaults
    let windowAutosaveName: String
    var query = ""
    var favoritesOnly = false
    var collectionID = "all"
    var mood = ""
    var motion = ""
    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: "holodeck.sidebarVisible") }
    }
    var searchFocusRequest = 0
    var startupError: String?
    private(set) var rendererUnavailableReason: String?
    var sleeping = false
    private(set) var renderer: Renderer?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let device: (any MTLDevice)?
    @ObservationIgnored private let compilerFactory: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling
    @ObservationIgnored private let filterCache = SceneFilterCache()

    init() {
        var windowNamespace = "live"
        var defaults = UserDefaults.standard
        var service = CatalogService()
        var metalDevice = MTLCreateSystemDefaultDevice()
        #if DEBUG
        let configuration = UITestConfiguration(applicationID: "me.haroldmartin.HolodeckMac")
        if let suite = configuration.storageSuite {
            windowNamespace = suite
            defaults = UserDefaults(suiteName: suite)!
            service = configuration.makeCatalogService()
            if configuration.contains("--ui-test-metal-unavailable") { metalDevice = nil }
        }
        #endif
        self.defaults = defaults
        windowAutosaveName = "HolodeckViewer-" + windowNamespace
        self.device = metalDevice
        compilerFactory = { ShaderCompiler(device: $0, pixelFormat: $1) }
        favorites = SceneFavorites(defaults: defaults)
        sidebarVisible = defaults.object(forKey: "holodeck.sidebarVisible") as? Bool ?? true
        session = ViewerSession(catalogService: service, preferences: .userDefaults(defaults), policy: .mac)
    }

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
            rendererUnavailableReason = error.localizedDescription
            startupError = error.localizedDescription
        }
    }

    func updateActivity(appActive: Bool? = nil) {
        session.setActive((appActive ?? NSApp.isActive) && !sleeping && window?.isMiniaturized != true && window?.isVisible == true)
    }
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
