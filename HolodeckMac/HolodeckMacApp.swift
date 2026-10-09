import AppKit
import SwiftUI

@main
struct HolodeckMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var model = MacModel()
    var body: some Scene {
        Window("Holodeck", id: "viewer") {
            ViewerView(model: model)
                .frame(minWidth: 740, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .sidebar) {
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Search Scenes") { model.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(before: .windowList) {
                Button("Holodeck") { MacAppDelegate.viewerWindow?.makeKeyAndOrderFront(nil) }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Scene Updates") { model.session.refresh(force: true) }
                    .disabled(model.session.isRefreshing)
            }
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var viewerWindow: NSWindow?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.viewerWindow?.makeKeyAndOrderFront(nil) }
        return true
    }
}
