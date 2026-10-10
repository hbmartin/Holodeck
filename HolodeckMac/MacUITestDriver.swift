#if DEBUG
import AppKit
import HolodeckCore

@MainActor
final class MacUITestDriver {
    private let configuration: UITestConfiguration
    private var replacesPresentedFailure: Bool

    init(configuration: UITestConfiguration) {
        self.configuration = configuration
        replacesPresentedFailure = configuration.contains("--ui-test-replace-presented-failure")
    }

    func prepareStorage() {
        guard configuration.contains("--ui-test-cleanup-storage-suite"),
              configuration.hasExplicitStorageSuite, let suite = configuration.storageSuite else { return }
        NSWindow.removeFrame(usingName: "HolodeckViewer-" + suite)
        configuration.cleanupStorageSuite()
    }

    func didPresentFailure(in model: MacModel) {
        guard replacesPresentedFailure else { return }
        replacesPresentedFailure = false
        if model.startupError != nil {
            model.startupError = MacModel.RendererFailure(message: "A newer renderer startup failure occurred.")
        } else if let failure = model.session.failure {
            model.session.failure = ViewerSession.Failure(message: "A newer scene download failure occurred.", operation: failure.operation)
        }
    }
}
#endif
