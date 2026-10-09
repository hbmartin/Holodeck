import AppKit
import HolodeckCore
import SwiftUI

struct ViewerView: View {
    @Bindable var model: MacModel
    private enum FocusTarget: Hashable { case search, library }
    @FocusState private var focus: FocusTarget?

    var body: some View {
        @Bindable var session = model.session
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
                                Text(session.pendingSelection.map { "Loading \($0.shader.title)…" } ??
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
                   if !$0 { session.failure = nil; model.startupError = nil }
               })) {
            if let failure = session.failure {
                Button("Retry") { session.retry(failure) }
            }
            Button("OK", role: .cancel) { session.failure = nil; model.startupError = nil }
        } message: { Text(model.startupError ?? session.failure?.message ?? "") }
        .onChange(of: model.searchFocusRequest) { focus = .search }
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
            Toggle("Favorites", isOn: $model.favoritesOnly)
                .toggleStyle(.button).accessibilityIdentifier("favorites-filter")
                .padding(.horizontal, 12).padding(.bottom, 8)
            if model.filteredScenes.isEmpty {
                ContentUnavailableView(model.session.shaders.isEmpty ? "No Scenes Yet" :
                                       (model.favoritesOnly && model.query.isEmpty ? "No Favorites Yet" : "No Matching Scenes"),
                                       systemImage: model.favoritesOnly ? "star" : "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: {
                    model.select($0)
                    focus = .library
                })) {
                    ForEach([ShaderDefinition.Category.procedural, .material], id: \.rawValue) { category in
                        let scenes = model.filteredScenes.filter { $0.category == category }
                        if !scenes.isEmpty {
                            Section(category.rawValue) {
                                ForEach(scenes) { shader in
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
                        }
                    }
                }
                .listStyle(.sidebar).focused($focus, equals: .library).accessibilityIdentifier("scene-list")
            }
        }
    }
}
