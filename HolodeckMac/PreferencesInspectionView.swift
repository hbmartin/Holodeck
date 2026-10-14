#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum MacInspectionLifecycle {
    struct Snapshot: Codable {
        var modelCreations = 0
        var libraryCreations = 0
        var serverStartAttempts = 0
    }
    static var snapshot = Snapshot()
}

/// Reads only this app's defaults and creates no viewer or library model.
struct PreferencesInspectionView: View {
    @State private var refreshGeneration = 0
    var body: some View {
        VStack {
            PreferencesInspectionField(refreshGeneration: refreshGeneration)
            Button("Refresh Preferences") { refreshGeneration += 1 }
                .accessibilityIdentifier("ui-test-refresh-preferences")
        }
        .padding()
        .frame(minWidth: 600, minHeight: 180)
    }
}

private struct PreferencesInspectionField: NSViewRepresentable {
    let refreshGeneration: Int
    func makeNSView(context: Context) -> PreferencesInspectionText { PreferencesInspectionText() }
    func updateNSView(_ view: PreferencesInspectionText, context: Context) { view.refreshSnapshot() }
}

final class PreferencesInspectionText: NSTextField {
    private struct Snapshot: Encodable {
        let schemaVersion = 2
        let bundleIdentifier: String
        let domainExists: Bool
        let frames: [String: String]
        let lifecycle: MacInspectionLifecycle.Snapshot
    }
    init() {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError("Preferences inspection uses programmatic construction") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSnapshot()
    }
    func refreshSnapshot() {
        guard let window, let identifier = Bundle.main.bundleIdentifier else { return }
        window.setFrameAutosaveName("")
        let domain = UserDefaults.standard.persistentDomain(forName: identifier)
        let frames = (domain ?? [:]).reduce(into: [String: String]()) { values, entry in
            if entry.key.hasPrefix("NSWindow Frame HolodeckViewer-"), let frame = entry.value as? String {
                values[entry.key] = frame
            }
        }
        let snapshot = Snapshot(bundleIdentifier: identifier, domainExists: domain != nil, frames: frames,
                                lifecycle: MacInspectionLifecycle.snapshot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do {
            stringValue = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
            setAccessibilityIdentifier("ui-test-preferences-snapshot")
            setAccessibilityValue(stringValue)
        } catch {
            stringValue = "Unable to inspect saved window preferences: \(error.localizedDescription)"
            setAccessibilityIdentifier("ui-test-preferences-error")
        }
    }
}
#endif
