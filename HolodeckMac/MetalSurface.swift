import AppKit
import HolodeckCore
import MetalKit
import SwiftUI

struct MetalSurface: NSViewRepresentable {
    let model: MacModel
    final class Coordinator {
        var installation: Task<Void, Never>?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MacMetalView {
        let view = MacMetalView()
        view.setAccessibilityIdentifier("shader-surface")
        context.coordinator.installation = Task { @MainActor [weak model, weak view] in
            guard !Task.isCancelled, let model, let view else { return }
            model.installRenderer(in: view)
            view.updateBackingSize()
        }
        view.onResize = { [weak model] size in model?.renderer?.resize(nativeSize: size) }
        view.updateBackingSize()
        return view
    }
    func updateNSView(_ nsView: MacMetalView, context: Context) { nsView.updateBackingSize() }
    static func dismantleNSView(_ nsView: MacMetalView, coordinator: Coordinator) {
        coordinator.installation?.cancel()
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
        let name = model.windowAutosaveName
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
        Task { @MainActor [weak model] in model?.updateActivity() }
    }
    isolated deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
