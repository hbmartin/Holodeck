import AppKit
import SwiftUI

@main
struct HolodeckMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var model: MacModel?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-inspect-preferences") {
            _model = State(initialValue: nil)
            return
        }
        #endif
        let model = MacModel()
        _model = State(initialValue: model)
        MacAppDelegate.prepareTermination = { await model.library?.requests.service.suspend() }
    }
    var body: some Scene {
        Window("Holodeck", id: "viewer") {
            if let model {
                ViewerView(model: model)
                    .frame(minWidth: 740, minHeight: 480)
            } else {
                #if DEBUG
                PreferencesInspectionView()
                #endif
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .sidebar) {
                if let model {
                    Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                        .keyboardShortcut("s", modifiers: [.command, .control])
                    Button("Search Scenes") { model.focusSearch() }
                        .keyboardShortcut("f", modifiers: .command)
                }
            }
            CommandGroup(after: .appInfo) {
                if model?.library != nil { Button("Shader Requests") { openWindow(id: "requests") } }
                if let model {
                    Button(model.library == nil ? "Check for Scene Updates" : "Reload Shaders") {
                        if let library = model.library { library.reload() } else { model.session.refresh(force: true) }
                    }
                        .disabled(model.session.isRefreshing)
                }
            }
        }
        Window("Shader Requests", id: "requests") {
            if let requests = model?.library?.requests { RequestsView(model: requests) }
        }
        Settings {
            if let library = model?.library { ShaderLibrarySettings(library: library) }
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var viewerWindow: NSWindow?
    static var prepareTermination: (@MainActor () async -> Void)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareTermination else { return .terminateNow }
        Task { await prepare(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = Self.viewerWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
}
