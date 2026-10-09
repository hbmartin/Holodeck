import AppKit
import HolodeckCore
import MetalKit
import SwiftUI

struct MetalSurface: NSViewRepresentable {
    let model: MacModel
    func makeNSView(context: Context) -> MacMetalView {
        let view = MacMetalView()
        view.setAccessibilityIdentifier("shader-surface")
        model.installRenderer(in: view)
        view.onResize = { [weak model] size in model?.renderer?.resize(nativeSize: size) }
        view.updateBackingSize()
        return view
    }
    func updateNSView(_ nsView: MacMetalView, context: Context) { nsView.updateBackingSize() }
    static func dismantleNSView(_ nsView: MacMetalView, coordinator: ()) {
        nsView.isPaused = true
        nsView.delegate = nil
        nsView.onResize = nil
    }
}

final class MacMetalView: MTKView {
    var onResize: ((CGSize) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateBackingSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingSize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingSize()
    }
    func updateBackingSize() { onResize?(convertToBacking(bounds).size) }
}

/// Native autosave also restores geometry when the viewer window is reopened.
struct WindowBridge: NSViewRepresentable {
    let model: MacModel
    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.model = model
        return view
    }
    func updateNSView(_ nsView: WindowObserverView, context: Context) { }
}

final class WindowObserverView: NSView {
    weak var model: MacModel?
    private var tokens: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        guard let window, let model else { return }
        model.window = window
        window.isReleasedWhenClosed = false
        MacAppDelegate.viewerWindow = window
        // Namespace test windows so UI tests never change real window preferences.
        let arguments = ProcessInfo.processInfo.arguments
        let suite = arguments.firstIndex(of: "--ui-test-storage-suite")
            .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "live"
        let name = "HolodeckViewer-" + suite
        window.setFrameAutosaveName(name)
        window.setFrameUsingName(name)
        window.setAccessibilityIdentifier("holodeck-viewer-window")
        for notification in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) { [weak model] _ in
                Task { @MainActor in model?.updateActivity() }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.session.setActive(false) }
        })
        model.updateActivity()
    }
    isolated deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
