#if DEBUG
import AppKit
import SwiftUI

/// The UI runner reads saved frames through the app's own defaults access, without opening its container.
struct PreferencesInspectionView: NSViewRepresentable {
    func makeNSView(context: Context) -> PreferencesInspectionText { PreferencesInspectionText() }
    func updateNSView(_ view: PreferencesInspectionText, context: Context) {}
}

final class PreferencesInspectionText: NSTextField {
    private struct Snapshot: Encodable {
        let schemaVersion = 1
        let bundleIdentifier: String
        let domainExists: Bool
        let frames: [String: String]
    }

    init() {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError("Preferences inspection uses programmatic construction") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let identifier = Bundle.main.bundleIdentifier else { return }
        window.setFrameAutosaveName("")
        let domain = UserDefaults.standard.persistentDomain(forName: identifier)
        let frames = (domain ?? [:]).reduce(into: [String: String]()) { values, entry in
            if entry.key.hasPrefix("NSWindow Frame HolodeckViewer-"), let frame = entry.value as? String {
                values[entry.key] = frame
            }
        }
        let snapshot = Snapshot(bundleIdentifier: identifier, domainExists: domain != nil, frames: frames)
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
