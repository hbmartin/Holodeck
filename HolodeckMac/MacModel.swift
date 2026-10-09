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
    var query = ""
    var favoritesOnly = false
    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: "holodeck.sidebarVisible") }
    }
    var searchFocusRequest = 0
    var startupError: String?
    var sleeping = false
    private(set) var renderer: Renderer?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let device: (any MTLDevice)?
    @ObservationIgnored private let compilerFactory: @Sendable (any MTLDevice, MTLPixelFormat) -> any ShaderCompiling

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var defaults = UserDefaults.standard
        var service = CatalogService()
        var metalDevice = MTLCreateSystemDefaultDevice()
        #if DEBUG
        if let index = arguments.firstIndex(of: "--ui-test-storage-suite"), index + 1 < arguments.count {
            defaults = UserDefaults(suiteName: arguments[index + 1]) ?? .standard
            if let json = ProcessInfo.processInfo.environment["HOLODECK_UI_TEST_CATALOG"],
               let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: Data(json.utf8)),
               (try? snapshot.validate()) != nil {
                let data = Data(json.utf8)
                service = CatalogService(storage: CatalogStorage(read: { name in name == "snapshot.json" ? data : nil }, write: { _, _ in }), enabled: false)
            }
            if arguments.contains("--ui-test-empty-cache") {
                service = CatalogService(network: CatalogNetwork { _, _ in throw CatalogError.invalidResponse }, storage: .disabled)
            }
            if arguments.contains("--ui-test-metal-unavailable") { metalDevice = nil }
        }
        #endif
        self.defaults = defaults
        self.device = metalDevice
        compilerFactory = { ShaderCompiler(device: $0, pixelFormat: $1) }
        favorites = SceneFavorites(defaults: defaults)
        sidebarVisible = defaults.object(forKey: "holodeck.sidebarVisible") as? Bool ?? true
        session = ViewerSession(catalogService: service, preferences: .userDefaults(defaults), policy: .mac)
    }

    var filteredScenes: [ShaderDefinition] {
        SceneLibrary.filter(session.shaders, query: query, favoritesOnly: favoritesOnly, favorites: favorites.ids)
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
            view.delegate = renderer
            session.attach(renderer)
            updateActivity()
        } catch {
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
        guard let id, let shader = session.shaders.first(where: { $0.id == id }) else { return }
        // Selecting the active scene again is an explicit restart/retry after a catalog update.
        if session.pendingSelection?.shader.id != id { session.select(shader) }
    }
}
