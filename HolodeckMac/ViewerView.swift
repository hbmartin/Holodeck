import AppKit
import HolodeckCore
import SwiftUI

struct ViewerView: View {
    @Bindable var model: MacModel
    private enum FocusTarget: Hashable { case search, library }
    @FocusState private var focus: FocusTarget?
    @State private var consumedSearchRequest = 0

    var body: some View {
        @Bindable var session = model.session
        let displayedFailure = session.failure
        let displayedStartupError = model.startupError
        HStack(spacing: 0) {
            if model.sidebarVisible {
                sidebar.frame(width: 280)
                Divider()
            }
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, geometry.size.height * 16 / 9)
                    ZStack {
                        Color.black
                        MetalSurface(model: model)
                            .frame(width: width, height: width * 9 / 16)
                        if session.activeShader == nil {
                            VStack(spacing: 12) {
                                if session.pendingSelection != nil || session.isRefreshing { ProgressView().tint(.white) }
                                Text(model.rendererUnavailableReason ?? session.pendingSelection.map { "Loading \($0.shader.title)…" } ??
                                     (session.isRefreshing ? "Downloading scenes…" : "Choose a scene to begin"))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let shader = session.activeShader {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(shader.title).font(.title3.bold()).accessibilityIdentifier("active-scene-title")
                            Text(shader.category.rawValue).font(.caption).foregroundStyle(.secondary)
                            if let discovery = shader.discovery {
                                Text(discovery.summary).font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("active-scene-discovery")
                            }
                            Text(shader.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button { model.favorites.toggle(shader.id) } label: {
                            Image(systemName: model.favorites.ids.contains(shader.id) ? "star.fill" : "star")
                        }
                        .help(model.favorites.ids.contains(shader.id) ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityLabel(model.favorites.ids.contains(shader.id) ? "Remove from Favorites" : "Add to Favorites")
                        .accessibilityIdentifier("toggle-favorite")
                    }.padding(20)
                }
                if let pending = session.pendingSelection, session.activeShader != nil {
                    HStack { ProgressView().controlSize(.small); Text("Loading \(pending.shader.title)…"); Spacer() }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
                if let updateFailure = session.catalogUpdateFailure {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                        Text(updateFailure.message).accessibilityIdentifier("catalog-update-notice")
                        Spacer()
                        Button("Retry") { session.retry(updateFailure) }
                            .accessibilityIdentifier("retry-scene-updates").disabled(session.isRefreshing)
                    }
                    .font(.callout).padding(12).background(.quaternary)
                }
            }
        }
        .background(WindowBridge(model: model).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help("Toggle Sidebar").accessibilityLabel("Toggle Sidebar").accessibilityIdentifier("toggle-sidebar")
            }
            ToolbarItem {
                Button { session.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Check for Scene Updates").accessibilityLabel("Check for Scene Updates")
                    .accessibilityIdentifier("refresh-scenes").disabled(session.isRefreshing)
            }
        }
        .alert(model.startupError != nil ? "Renderer Unavailable" : "Unable to Load Scenes",
               isPresented: Binding(get: { session.failure != nil || model.startupError != nil }, set: {
                   if !$0 {
                       if let displayedFailure { session.dismissFailure(id: displayedFailure.id) }
                       if model.startupError == displayedStartupError { model.startupError = nil }
                   }
               })) {
            if let failure = displayedFailure {
                Button("Retry") { session.retry(failure) }
            }
            Button("OK", role: .cancel) {
                if let displayedFailure { session.dismissFailure(id: displayedFailure.id) }
                if model.startupError == displayedStartupError { model.startupError = nil }
            }
        } message: { Text(displayedStartupError ?? displayedFailure?.message ?? "") }
        .onChange(of: session.catalog?.publicationRevision) { model.reconcileFilters() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.updateActivity(appActive: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.updateActivity(appActive: false) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            model.sleeping = true; model.updateActivity()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.sleeping = false; model.updateActivity()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search scenes", text: $model.query)
                .textFieldStyle(.roundedBorder).focused($focus, equals: .search)
                .accessibilityIdentifier("scene-search").padding(12)
                .task(id: model.searchFocusRequest) {
                    let request = model.searchFocusRequest
                    guard request > consumedSearchRequest else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    consumedSearchRequest = request
                    focus = .search
                }
            VStack(spacing: 8) {
                Picker("Collection", selection: $model.collectionID) {
                    Text("All").tag("all")
                    ForEach(model.collections) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("collection-filter")
                if !model.moods.isEmpty {
                    Picker("Mood", selection: $model.mood) {
                        Text("Any").tag("")
                        ForEach(model.moods, id: \.self) { Text($0.capitalized).tag($0) }
                    }.accessibilityIdentifier("mood-filter")
                }
                if !model.motions.isEmpty {
                    Picker("Motion", selection: $model.motion) {
                        Text("Any").tag("")
                        ForEach(model.motions, id: \.self) { Text($0.capitalized).tag($0) }
                    }.accessibilityIdentifier("motion-filter")
                }
                Toggle("Favorites", isOn: $model.favoritesOnly)
                    .toggleStyle(.button).accessibilityIdentifier("favorites-filter")
                Button("Reset Filters") { model.resetFilters() }
                    .disabled(!model.hasFilters).accessibilityIdentifier("reset-filters")
            }.padding(.horizontal, 12).padding(.bottom, 12)
            if model.filteredScenes.isEmpty {
                ContentUnavailableView(model.session.shaders.isEmpty ? "No Scenes Yet" :
                                       (model.favoritesOnly && model.query.isEmpty && model.collectionID == "all" && model.mood.isEmpty && model.motion.isEmpty ? "No Favorites Yet" : "No Matching Scenes"),
                                       systemImage: model.favoritesOnly ? "star" : "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: {
                    if let id = $0, id != model.selectedID { focus = .library }
                    model.select($0)
                })) {
                    ForEach(model.filteredScenes) { shader in
                        HStack(spacing: 10) {
                            ScenePreview(shader: shader, service: model.session.catalogService)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shader.title).lineLimit(2)
                                if model.session.pendingSelection?.shader.id == shader.id {
                                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                                } else if model.session.activeShader?.id == shader.id {
                                    Text("Now showing").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if model.favorites.ids.contains(shader.id) { Image(systemName: "star.fill").font(.caption).accessibilityHidden(true) }
                        }
                        .tag(shader.id)
                        .accessibilityIdentifier("shader-" + shader.id)
                        .accessibilityLabel(shader.title)
                        .accessibilityValue(model.session.pendingSelection?.shader.id == shader.id ? "Loading" :
                                            (model.session.activeShader?.id == shader.id ? "Now showing" : ""))
                    }
                }
                .listStyle(.sidebar).focused($focus, equals: .library).accessibilityIdentifier("scene-list")
                .disabled(model.renderer == nil)
            }
        }
    }
}
