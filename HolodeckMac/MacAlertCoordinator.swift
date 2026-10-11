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
            case .renderer(let failure):
                return model.startupError?.id == failure.id
            case .session(let failure):
                return model.session.failure?.id == failure.id
            }
        }
    }
    private struct Presentation {
        let alert: NSAlert
        let payload: Payload
        var escapeMonitor: Any?
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
            alert.addButton(withTitle: "OK")
            // AppKit gives the first button Return. Route Escape to the same action
            // without replacing that key equivalent.
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
            self.presentation?.isEnding = true
            if let monitor = self.presentation?.escapeMonitor {
                NSEvent.removeMonitor(monitor)
                self.presentation?.escapeMonitor = nil
            }
            guard let model else { self.presentation = nil; return }
            // Aborted sheets (for example, a closing window) leave their errors pending.
            switch payload {
            case .renderer(let failure):
                if response == .alertFirstButtonReturn, model.startupError?.id == failure.id { model.startupError = nil }
            case .session(let failure):
                if response == .alertFirstButtonReturn { model.session.retry(failure) }
                else if response == .alertSecondButtonReturn { model.session.dismissFailure(id: failure.id) }
            }
            // NSAlert orders out its sheet after this completion returns. Retain its
            // ownership until then so a new sheet cannot race the old sheet's teardown.
            Task { @MainActor [weak self, weak model, weak alert] in
                guard let self, let model, let alert, self.presentation?.alert === alert else { return }
                self.presentation = nil
                self.presentNextFailure(in: model)
            }
        }
        didPresent?(model)
    }
}
