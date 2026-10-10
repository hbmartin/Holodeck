import AppKit
import HolodeckCore

/// One captured failure owns each sheet's content and actions, including its dismissal.
@MainActor
final class MacAlertCoordinator {
    private enum Payload {
        case renderer(MacModel.RendererFailure)
        case session(ViewerSession.Failure)
    }
    private var alert: NSAlert?

    func presentNextFailure(in model: MacModel) {
        guard alert == nil, model.hasAttemptedRendererInstallation,
              let window = model.window, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        let payload: Payload
        if let failure = model.startupError { payload = .renderer(failure) }
        else if let failure = model.session.failure { payload = .session(failure) }
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch payload {
        case .renderer(let failure):
            alert.messageText = "Renderer Unavailable"
            alert.informativeText = failure.message
            alert.addButton(withTitle: "OK")
        case .session(let failure):
            alert.messageText = "Unable to Load Scenes"
            alert.informativeText = failure.message
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "OK").keyEquivalent = "\u{1b}"
        }
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self, weak model] response in
            guard let self, let model else { return }
            // Aborted sheets (for example, a closing window) leave their errors pending.
            switch payload {
            case .renderer(let failure):
                if response == .alertFirstButtonReturn, model.startupError?.id == failure.id { model.startupError = nil }
            case .session(let failure):
                if response == .alertFirstButtonReturn { model.session.retry(failure) }
                else if response == .alertSecondButtonReturn { model.session.dismissFailure(id: failure.id) }
            }
            self.alert = nil
            // The completion runs after this sheet closes, so the next error gets its own presentation.
            self.presentNextFailure(in: model)
        }
        #if DEBUG
        model.didPresentFailureForTesting()
        #endif
    }
}
