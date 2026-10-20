#if DEBUG
import AppKit
import HolodeckCore
import MetalKit

@MainActor
final class MacUITestDriver {
    private let configuration: UITestConfiguration
    private var replacesPresentedFailure: Bool
    private var extendsCatalogCorrelation: Bool
    private var repeatsRendererInstallation: Bool

    init(configuration: UITestConfiguration) {
        self.configuration = configuration
        extendsCatalogCorrelation = configuration.contains("--ui-test-extend-catalog-correlation") || configuration.contains("--ui-test-associate-presented-catalog")
        replacesPresentedFailure = configuration.contains("--ui-test-replace-presented-failure")
        repeatsRendererInstallation = configuration.contains("--ui-test-repeat-renderer-installation")
    }

    static func windowAutosaveName(for suite: String) -> String { "HolodeckViewer-" + suite }

    func prepareStorage() {
        guard configuration.contains("--ui-test-cleanup-storage-suite"),
              configuration.hasExplicitStorageSuite, let suite = configuration.storageSuite else { return }
        NSWindow.removeFrame(usingName: Self.windowAutosaveName(for: suite))
        configuration.cleanupStorageSuite()
        let requests = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holodeck/Requests-tests-\(suite)")
        try? FileManager.default.removeItem(at: requests)
        try? LocalCatalogServer.removeTestingSecrets(namespace: suite)
    }

    func observeStartupActivation(in model: MacModel) {
        guard configuration.contains("--ui-test-selection-failure") else { return }
        model.session.onEvent = { [weak model] event in
            guard case .activated(.startup) = event, let model,
                  let shader = model.session.shaders.first(where: { $0.id == "aurora" }) else { return }
            model.session.onEvent = nil
            model.session.failure = ViewerSession.Failure(message: "An older Aurora selection failure occurred.",
                                                         operation: .selection(shader, .user))
            model.presentFailuresIfNeeded()
        }
    }

    func didPresentFailure(in model: MacModel) {
        if model.library?.exposesFailureAssociationTests == true,
           let failure = model.session.failure, case .catalog = failure.operation {
            model.library?.catalogAlertPresentationCount += 1
        }
        if extendsCatalogCorrelation, let failure = model.session.failure, case .catalog = failure.operation {
            extendsCatalogCorrelation = false
            let correlationID = UUID()
            model.window?.attachedSheet?.setAccessibilityIdentifier("catalog-correlation-sheet")
            model.session.failure = failure.withCorrelationIDs(failure.correlationIDs.union([correlationID]))
            if configuration.contains("--ui-test-associate-presented-catalog") {
                model.library?.associateCatalogFailureForTesting(correlationID)
            }
        }
        if repeatsRendererInstallation, model.startupError != nil {
            repeatsRendererInstallation = false
            // Detect replacing this sheet even when the replacement has identical text.
            model.window?.attachedSheet?.setAccessibilityIdentifier("renderer-reinstallation-sheet")
            model.installRenderer(in: MTKView(frame: .zero))
        }
        guard replacesPresentedFailure else { return }
        replacesPresentedFailure = false
        if model.startupError != nil {
            model.startupError = MacModel.RendererFailure(message: "A newer renderer startup failure occurred.")
        } else if let failure = model.session.failure {
            if configuration.contains("--ui-test-selection-failure"),
               case .selection = failure.operation,
               let shader = model.session.shaders.first(where: { $0.id == "waves" }) {
                model.session.failure = ViewerSession.Failure(message: "A newer Waves selection failure occurred.",
                                                             operation: .selection(shader, .user))
            } else {
                model.session.failure = ViewerSession.Failure(message: "A newer scene download failure occurred.", operation: failure.operation)
            }
        }
    }
}
#endif
