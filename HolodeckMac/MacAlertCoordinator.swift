import AppKit
import HolodeckCore

/// One captured failure owns each sheet's content and actions, including its dismissal.
@MainActor
final class MacAlertCoordinator {
    private enum Payload {
        case renderer(MacModel.RendererFailure)
        case session(ViewerSession.Failure)

        func isEligible(in model: MacModel) -> Bool {
            switch self {
            case .renderer:
                return model.startupError != nil
            case .session(let failure):
                switch failure.operation {
                case .catalog:
                    return model.session.catalog == nil && model.session.catalogFailure != nil
                case .selection:
                    if case .selection = model.session.failure?.operation { return true }
                    return false
                }
            }
        }
    }
    private struct Presentation {
        let alert: NSAlert
        let payload: Payload
        let escapeMonitor: Any?
        var isEnding = false
    }
    private var presentation: Presentation?
    private let didPresent: ((MacModel) -> Void)?

    init(didPresent: ((MacModel) -> Void)? = nil) { self.didPresent = didPresent }

    isolated deinit {
        if let monitor = presentation?.escapeMonitor { NSEvent.removeMonitor(monitor) }
    }

    func presentNextFailure(in model: MacModel) {
        if let presentation {
            if !presentation.isEnding, !presentation.payload.isEligible(in: model),
               let parent = presentation.alert.window.sheetParent {
                self.presentation?.isEnding = true
                parent.endSheet(presentation.alert.window, returnCode: .abort)
            }
            return
        }
        guard model.hasAttemptedRendererInstallation,
              let window = model.window, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        let payload: Payload
        if let failure = model.startupError { payload = .renderer(failure) }
        else if let failure = model.session.failure { payload = .session(failure) }
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        var escapeMonitor: Any?
        switch payload {
        case .renderer(let failure):
            alert.messageText = "Renderer Unavailable"
            alert.informativeText = failure.message
            let button = alert.addButton(withTitle: "OK")
            alert.window.defaultButtonCell = button.cell as? NSButtonCell
            // Replacing the default button's key equivalent also removes its Return
            // behavior. Route Escape to that button without changing its default cell.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert] event in
                guard let alert, event.window === alert.window || event.window?.attachedSheet === alert.window,
                      event.charactersIgnoringModifiers == "\u{1b}",
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                alert.buttons.first?.performClick(nil)
                return nil
            }
        case .session(let failure):
            alert.messageText = "Unable to Load Scenes"
            alert.informativeText = failure.message
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "OK").keyEquivalent = "\u{1b}"
        }
        presentation = Presentation(alert: alert, payload: payload, escapeMonitor: escapeMonitor)
        alert.beginSheetModal(for: window) { [weak self, weak model, weak alert] response in
            guard let self, let alert, self.presentation?.alert === alert else { return }
            if let monitor = self.presentation?.escapeMonitor { NSEvent.removeMonitor(monitor) }
            guard let model else { self.presentation = nil; return }
            // Aborted sheets (for example, a closing window) leave their errors pending.
            switch payload {
            case .renderer(let failure):
                if response == .alertFirstButtonReturn, model.startupError?.id == failure.id { model.startupError = nil }
            case .session(let failure):
                if response == .alertFirstButtonReturn { model.session.retry(failure) }
                else if response == .alertSecondButtonReturn { model.session.dismissFailure(id: failure.id) }
            }
            self.presentation = nil
            // The completion runs after this sheet closes, so the next error gets its own presentation.
            self.presentNextFailure(in: model)
        }
        didPresent?(model)
    }
}
