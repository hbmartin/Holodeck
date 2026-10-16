import Dependencies
import Foundation
import Observation

@MainActor
public protocol SceneRendering: AnyObject {
    var activeShader: ShaderDefinition? { get }
    @discardableResult func select(_ shader: ShaderDefinition) async throws -> Bool
    func cancelPendingSelection()
    func setActive(_ active: Bool)
}

nonisolated public struct ViewerPolicy: Sendable {
    public enum CatalogErrorContext: Sendable { case generic, macLibrary, tvConnection }
    public let restoresLastScene: Bool
    public let replacesUpdatedScene: Bool
    /// Whether reactivation checks for updates before a renderer has been attached.
    public let refreshesWithoutRenderer: Bool
    public let catalogErrorContext: CatalogErrorContext
    public static let tv = Self(restoresLastScene: true, replacesUpdatedScene: false, refreshesWithoutRenderer: false, catalogErrorContext: .tvConnection)
    public static let mac = Self(restoresLastScene: false, replacesUpdatedScene: true, catalogErrorContext: .macLibrary)
    public init(restoresLastScene: Bool, replacesUpdatedScene: Bool, refreshesWithoutRenderer: Bool = true,
                catalogErrorContext: CatalogErrorContext = .generic) {
        self.restoresLastScene = restoresLastScene
        self.replacesUpdatedScene = replacesUpdatedScene
        self.refreshesWithoutRenderer = refreshesWithoutRenderer
        self.catalogErrorContext = catalogErrorContext
    }
}

@MainActor @Observable
public final class ViewerSession {
    public enum SelectionResult: Sendable, Equatable {
        case activated, superseded, cancelled, unavailable
        case failed(String)
        case temporarilyUnavailable(String)
    }
    public enum RefreshResult: Sendable, Equatable { case checked, skipped, cancelled; case failed(String) }
    public private(set) var refreshResult: RefreshResult = .skipped
    @ObservationIgnored private var lastSelectionResult: (generation: UInt64, result: SelectionResult)?
    public enum SelectionOrigin: Sendable { case startup, user, update }
    public struct PendingSelection {
        public let shader: ShaderDefinition
        public let origin: SelectionOrigin
        public let generation: UInt64
    }
    public enum Event {
        case catalogLoading, catalogCacheChecked, catalogChanged, catalogFailed, catalogFinished
        case selectionStarted(SelectionOrigin), activated(SelectionOrigin), selectionFailed
    }
    public struct Failure: Identifiable {
        public enum Operation { case catalog, selection(ShaderDefinition, SelectionOrigin) }
        public let id = UUID()
        public let message: String
        public let operation: Operation
        public init(message: String, operation: Operation) {
            self.message = message
            self.operation = operation
        }
    }

    public private(set) var catalog: ValidatedCatalog?
    public private(set) var shaders: [ShaderDefinition]
    public private(set) var startupShader: ShaderDefinition?
    public private(set) var activeShader: ShaderDefinition?
    public private(set) var pendingSelection: PendingSelection?
    public private(set) var isRefreshing = false
    public private(set) var requiresExplicitSelection = false
    public private(set) var hasCheckedCache: Bool
    public private(set) var catalogFailure: Failure?
    public private(set) var selectionDiagnostic: String?
    public private(set) var selectionFailure: Failure?
    public var failure: Failure? {
        get {
            if catalog == nil, let catalogFailure { return catalogFailure }
            return pendingSelection?.origin == .user ? nil : selectionFailure
        }
        set {
            if let newValue {
                switch newValue.operation {
                case .catalog: catalogFailure = newValue
                case .selection: selectionFailure = newValue
                }
            } else if let displayed = failure { dismissFailure(id: displayed.id) }
        }
    }
    public var catalogUpdateFailure: Failure? { catalog == nil ? nil : catalogFailure }
    @ObservationIgnored public var onEvent: ((Event) -> Void)?
    @ObservationIgnored public private(set) var selectionTask: Task<Void, Never>?
    @ObservationIgnored public private(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored public let catalogService: CatalogService
    @ObservationIgnored private var renderer: (any SceneRendering)?
    @ObservationIgnored private let preferences: ShaderPreferences
    @ObservationIgnored private let policy: ViewerPolicy
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var hasBeenActive = false
    @ObservationIgnored private var savedID: String?
    @ObservationIgnored private var forcedRefreshPending = false

    public init(catalogService: CatalogService, preferences: ShaderPreferences, policy: ViewerPolicy) {
        self.catalogService = catalogService
        self.preferences = preferences
        self.policy = policy
        hasCheckedCache = catalogService.initialCatalog != nil
        catalog = catalogService.initialCatalog
        shaders = catalogService.initialCatalog?.shaders ?? []
        savedID = policy.restoresLastScene ? preferences.lastShaderID() : nil
        startupShader = catalog?.startupShader(savedID: savedID)
    }

    isolated deinit {
        selectionTask?.cancel()
        refreshTask?.cancel()
        renderer?.setActive(false)
    }

    public func attach(_ renderer: any SceneRendering) {
        guard self.renderer == nil else { return }
        self.renderer = renderer
        renderer.setActive(active)
        if let startupShader { select(startupShader, origin: .startup) }
        refresh()
    }

    public func setActive(_ active: Bool) {
        let reactivated = active && hasBeenActive && !self.active
        if active { hasBeenActive = true }
        self.active = active
        renderer?.setActive(active)
        if reactivated, renderer != nil || policy.refreshesWithoutRenderer { refresh() }
    }

    @discardableResult
    public func refresh(force: Bool = false) -> Task<Void, Never> {
        if let refreshTask {
            if force { forcedRefreshPending = true }
            return refreshTask
        }
        isRefreshing = true
        refreshResult = .cancelled
        let service = catalogService
        let task = Task { [weak self] in
            defer {
                self?.isRefreshing = false
                self?.refreshTask = nil
                self?.forcedRefreshPending = false
                self?.onEvent?(.catalogFinished)
            }
            var forcePass = force
            repeat {
                let cached = await service.current()
                guard !Task.isCancelled else { return }
                self?.hasCheckedCache = true
                if let cached { self?.applyCatalog(cached) }
                self?.onEvent?(.catalogCacheChecked)
                do {
                    let outcome = try await service.refreshOutcome(force: forcePass)
                    let current = await service.current()
                    guard !Task.isCancelled, let self else { return }
                    if let current { self.applyCatalog(current) }
                    switch outcome {
                    case .updated, .unchanged:
                        self.refreshResult = .checked
                        self.catalogFailure = nil
                    case .throttled, .disabled:
                        self.refreshResult = .skipped
                        if self.catalog == nil {
                            if self.catalogFailure != nil { self.onEvent?(.catalogFailed) }
                            else { throw CatalogError.invalidManifest }
                        }
                    }
                } catch {
                    let current = await service.current()
                    guard !Task.isCancelled, let self else { return }
                    if let current { self.applyCatalog(current) }
                    self.refreshResult = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                    let message = self.catalogErrorMessage(error)
                    if self.catalogFailure?.message != message {
                        self.catalogFailure = Failure(message: message, operation: .catalog)
                    }
                    self.onEvent?(.catalogFailed)
                }
                forcePass = self?.forcedRefreshPending == true
                self?.forcedRefreshPending = false
            } while forcePass && !Task.isCancelled
        }
        refreshTask = task
        onEvent?(.catalogLoading)
        return task
    }

    /// Waits for the coalesced forced refresh, including its final follow-up pass.
    public func refreshForDelivery() async throws {
        await refresh(force: true).value
        try Task.checkCancellation()
        switch refreshResult {
        case .checked: return
        case .cancelled: throw CancellationError()
        case .failed(let message): throw ShaderRequestError.unavailable(message)
        case .skipped: throw ShaderRequestError.unavailable("A fresh catalog check is required before delivery.")
        }
    }

    public func selectForDelivery(_ shader: ShaderDefinition) async -> SelectionResult {
        guard renderer != nil else { return .unavailable }
        let task = select(shader), request = generation
        await task.value
        guard !Task.isCancelled else { return .cancelled }
        guard generation == request, lastSelectionResult?.generation == request else { return .superseded }
        return lastSelectionResult!.result
    }

    private func catalogErrorMessage(_ error: Error) -> String {
        if let local = error as? LocalCatalogError {
            if case .invalidFile = local { return local.localizedDescription }
            if policy.catalogErrorContext == .tvConnection { return local.localizedDescription }
        }
        if catalog != nil { return "Couldn’t check for scene updates. Cached scenes are still available." }
        switch policy.catalogErrorContext {
        case .macLibrary: return "Couldn’t load scenes. Choose or reload your shader folder and try again."
        case .tvConnection: return "Couldn’t load scenes. Check your connection to the Mac and try again."
        case .generic: return "Couldn’t load scenes. Try again."
        }
    }

    public func applyCatalog(_ snapshot: ValidatedCatalog) {
        guard snapshot.publicationRevision != catalog?.publicationRevision else { return }
        let firstCatalog = catalog == nil
        catalog = snapshot
        shaders = snapshot.shaders
        catalogFailure = nil
        startupShader = snapshot.startupShader(savedID: savedID)
        if firstCatalog, activeShader == nil, pendingSelection == nil, !requiresExplicitSelection {
            if let startupShader, renderer != nil { select(startupShader, origin: .startup) }
        } else if policy.replacesUpdatedScene, pendingSelection == nil,
                  let activeShader, let updated = shaders.first(where: { $0.id == activeShader.id }) {
            if updated.sourceHash != activeShader.sourceHash {
                select(updated, origin: .update)
            } else {
                // Metadata and previews can change without resetting the renderer's clock.
                self.activeShader = updated
            }
        }
        onEvent?(.catalogChanged)
    }

    @discardableResult
    public func select(_ shader: ShaderDefinition, origin: SelectionOrigin = .user) -> Task<Void, Never> {
        guard let renderer else { return Task {} }
        generation &+= 1
        selectionDiagnostic = nil
        let request = generation
        pendingSelection = PendingSelection(shader: shader, origin: origin, generation: request)
        // Invalidate in-flight renderer requests before this task gets executor time.
        renderer.cancelPendingSelection()
        onEvent?(.selectionStarted(origin))
        let task = Task { [weak self] in
            guard let self, self.generation == request else { return }
            do {
                guard try await renderer.select(shader), self.generation == request else {
                    if self.generation == request { self.lastSelectionResult = (request, .superseded); self.pendingSelection = nil }
                    return
                }
                self.lastSelectionResult = (request, .activated)
                self.activeShader = self.shaders.first { $0.id == shader.id && $0.sourceHash == shader.sourceHash } ?? shader
                self.pendingSelection = nil
                self.requiresExplicitSelection = false
                if origin != .update {
                    self.selectionFailure = nil
                } else if case .selection(let failed, .update) = self.selectionFailure?.operation, failed.id == shader.id {
                    self.selectionFailure = nil
                }
                if self.policy.restoresLastScene { self.preferences.setLastShaderID(shader.id) }
                self.onEvent?(.activated(origin))
                // If a refresh arrived during a user selection, resolve the newer source now.
                if self.policy.replacesUpdatedScene,
                   let updated = self.shaders.first(where: { $0.id == shader.id }),
                   updated.sourceHash != shader.sourceHash {
                    self.select(updated, origin: .update)
                }
            } catch {
                if !(error is CancellationError) {
                    Diagnostics.selection.error("Scene \(shader.id, privacy: .public) (\(String(describing: origin), privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
                }
                guard self.generation == request else { return }
                self.pendingSelection = nil
                let result: SelectionResult = error is CancellationError ? .cancelled :
                    (ShaderCompilationError.isSourceDefect(error) ? .failed(error.localizedDescription) : .temporarilyUnavailable(error.localizedDescription))
                self.lastSelectionResult = (request, result)
                self.selectionDiagnostic = error.localizedDescription
                if self.activeShader == nil { self.requiresExplicitSelection = true }
                if origin != .update || !self.hasUserSelectionFailure {
                    self.selectionFailure = Failure(message: "Couldn’t load \(shader.title). Try again or choose another scene.", operation: .selection(shader, origin))
                }
                self.onEvent?(.selectionFailed)
            }
        }
        selectionTask = task
        return task
    }

    public func cancelPendingSelection(resumeStartup: Bool = false) {
        generation &+= 1
        renderer?.cancelPendingSelection()
        pendingSelection = nil
        if resumeStartup, !requiresExplicitSelection, activeShader == nil, let startupShader {
            select(startupShader, origin: .startup)
        }
    }

    public func retry(_ failure: Failure) {
        guard self.failure?.id == failure.id || catalogUpdateFailure?.id == failure.id else { return }
        dismissFailure(id: failure.id)
        switch failure.operation {
        case .catalog: refresh(force: true)
        case .selection(let shader, let origin):
            select(shaders.first { $0.id == shader.id } ?? shader, origin: origin)
        }
    }

    public func dismissFailure(id: UUID) {
        if catalogFailure?.id == id { catalogFailure = nil }
        if selectionFailure?.id == id { selectionFailure = nil }
    }

    private var hasUserSelectionFailure: Bool {
        if case .selection(_, .user) = selectionFailure?.operation { return true }
        return false
    }

    public func shutdown() {
        forcedRefreshPending = false
        cancelPendingSelection()
        selectionTask?.cancel()
        refreshTask?.cancel()
        renderer?.setActive(false)
        onEvent = nil
    }
}
