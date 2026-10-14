import UIKit
import HolodeckCore

@MainActor
final class TVRequestsController {
    private weak var presenter: UIViewController?
    private let renderer: Renderer
    private let client: LocalCatalogClient
    private let session: ViewerSession
    private let defaults: UserDefaults?
    private let covered: () -> Bool
    var onLockChanged: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var foreground = false
    private var connected = false
    private var enabled = false
    private var supported = false
    private var hostID: String?
    private var pendingManual: UUID?
    private var jobs: [ShaderRequestStatus] = []
    private var seenTerminal: Set<UUID> = []
    private var deliveries: Set<UUID> = []
    private var answering: Set<UUID> = []
    private weak var clarificationAlert: UIAlertController?
    private var dismissedShaders: Set<String> = []
    private var attemptedVersions: Set<String> = []
    private var optimizationRequests: [String: UUID] = [:]
    private var measuringHash: String?
    private var monitor = ShaderPerformanceMonitor()
    private var submittingPerformance = false
    private var lastRevision: String?
    private var deliveryNonce = UUID().uuidString
    private var requestedDeliveries: Set<UUID> = []
    private let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let label = UILabel()
    private var banner: String?
    private var bannerUntil = Date.distantPast
    private var ticker: Timer?
    var blocksBrowsing: Bool { connected && (pendingManual != nil || jobs.contains { $0.blocksBrowsing }) }
    var canInput: Bool { supported && enabled && connected && !blocksBrowsing }
    var availabilityMessage = "Connect to a configured Mac to submit requests."

    init(presenter: UIViewController, renderer: Renderer, client: LocalCatalogClient,
         session: ViewerSession, defaults: UserDefaults?, covered: @escaping () -> Bool) {
        self.presenter = presenter; self.renderer = renderer; self.client = client
        self.session = session; self.defaults = defaults; self.covered = covered
        label.numberOfLines = 4; label.font = .systemFont(ofSize: 21, weight: .medium); label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false; overlay.isHidden = true
        overlay.layer.cornerRadius = 16; overlay.clipsToBounds = true
        overlay.accessibilityIdentifier = "request-progress"
        overlay.contentView.addSubview(label); presenter.view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.leadingAnchor, constant: 30),
            overlay.trailingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.trailingAnchor, constant: -30),
            overlay.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.leadingAnchor.constraint(equalTo: overlay.contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: overlay.contentView.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: overlay.contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: overlay.contentView.bottomAnchor, constant: -18)
        ])
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.displayProgress() }
        }
        renderer.onPresentedFrame = { [weak self] time, gpu in self?.presented(time: time, gpu: gpu) }
        renderer.onDisplayObservation = { [weak self] time in self?.presented(time: time, gpu: nil, deliveredFrames: 0) }
        renderer.onMeasurementReset = { [weak self] in self?.monitor.reset(at: ProcessInfo.processInfo.systemUptime) }
    }
    deinit { pollTask?.cancel(); ticker?.invalidate() }
    func setForeground(_ value: Bool) {
        foreground = value
        monitor.reset(at: ProcessInfo.processInfo.systemUptime)
        pollTask?.cancel(); pollTask = nil
        if value {
            deliveryNonce = UUID().uuidString; requestedDeliveries.removeAll()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
        } else { connected = false; clarificationAlert?.dismiss(animated: false); onLockChanged?(); displayProgress() }
    }
    func applyConnection(_ state: LocalClientState) {
        supported = state.requestsSupported
        if case .connected = state.status { } else { connected = false; clarificationAlert?.dismiss(animated: true); onLockChanged?() }
    }
    private var pendingKey: String? { hostID.map { "holodeck.pendingRequest.\($0)" } }
    private func savePending(_ id: UUID?) {
        pendingManual = id
        if let pendingKey { defaults?.set(id?.uuidString, forKey: pendingKey) }
        onLockChanged?(); displayProgress()
    }
    private func poll() async {
        guard foreground else { return }
        do {
            guard supported else { connected = false; onLockChanged?(); return }
            let mac = await client.requestMacID()
            if hostID != mac {
                hostID = mac
                pendingManual = pendingKey.flatMap { defaults?.string(forKey: $0) }.flatMap(UUID.init(uuidString:))
            }
            let reply = try await client.requestControl(operation: "requestStatus")
            connected = true; enabled = reply.enabled; availabilityMessage = reply.message
            var current = reply.jobs
            if let pendingManual, !current.contains(where: { $0.id == pendingManual }) {
                let specific = try await client.requestControl(operation: "requestStatus", payload: .init(requestID: pendingManual))
                current += specific.jobs
                if specific.jobs.isEmpty { savePending(nil) }
            }
            for previous in jobs where !previous.stage.terminal && !current.contains(where: { $0.id == previous.id }) {
                let terminal = try await client.requestControl(operation: "requestStatus", payload: .init(requestID: previous.id))
                current += terminal.jobs.filter { incoming in !current.contains { $0.id == incoming.id } }
            }
            jobs = current
            if let revision = reply.publicationRevision, revision != lastRevision {
                lastRevision = revision
                await session.refresh(force: true).value
            }
            onLockChanged?(); displayProgress()
            for job in current {
                if job.stage.terminal, seenTerminal.insert(job.id).inserted {
                    if pendingManual == job.id { savePending(nil) }
                    if job.stage == .completed, let result = job.result {
                        let name = session.shaders.first(where: { $0.id == result.shaderID })?.title ?? result.shaderID
                        showBanner((result.changed ? (result.outputKind == .new ? "Created " : "Updated ") : "Already matches: ") + name +
                                   (result.approximations.isEmpty ? "" : "\n" + result.approximations.joined(separator: "; ")))
                    } else if job.stage == .failed || job.stage == .cancelled {
                        showBanner(job.message)
                        if job.request.purpose == .performance { attemptedVersions.insert(job.request.context.shaderID + ":" + job.request.context.sourceHash) }
                    }
                } else if job.stage == .awaitingClarification {
                    offerClarification(job)
                } else if job.stage == .awaitingActivation, !covered(), !deliveries.contains(job.id) {
                    await deliver(job)
                }
            }
        } catch {
            connected = false
            availabilityMessage = error.localizedDescription
            clarificationAlert?.dismiss(animated: true)
            if case LocalCatalogError.rejected = error { savePending(nil) }
            onLockChanged?(); displayProgress()
        }
    }
    func compose() {
        guard canInput, let presenter else { showBanner(availabilityMessage); return }
        Task {
            do {
                let context = try await renderer.captureSnapshot()
                guard canInput, presenter.presentedViewController == nil else { return }
                let alert = UIAlertController(title: "Shader Request", message: "Watching \(context.name). Describe a change or a new scene.", preferredStyle: .alert)
                let submit = UIAlertAction(title: "Submit", style: .default) { [weak self, weak alert] _ in
                    guard let prompt = alert?.textFields?.first?.text, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    self?.submit(ShaderRequest(prompt: prompt, context: context))
                }
                submit.isEnabled = false
                alert.addTextField { field in
                    field.placeholder = "What would you like to see?"; field.accessibilityIdentifier = "shader-request-input"
                    field.returnKeyType = .done
                    field.addAction(UIAction { [weak field, weak submit] _ in
                        submit?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }, for: .editingChanged)
                }
                alert.addAction(submit)
                alert.addAction(UIAlertAction(title: "Back", style: .cancel))
                presenter.present(alert, animated: true)
            } catch { showBanner(error.localizedDescription) }
        }
    }
    private func submit(_ request: ShaderRequest) {
        if request.purpose == .creative {
            renderer.cancelPendingSelection()
            savePending(request.id)
        }
        Task {
            do {
                let reply = try await client.requestControl(operation: "requestSubmit", payload: .init(request: request))
                jobs += reply.jobs.filter { incoming in !jobs.contains { $0.id == incoming.id } }
                connected = true
                if request.purpose == .performance { showBanner("Requesting performance improvements for \(request.context.name)…") }
                onLockChanged?(); displayProgress()
            } catch {
                // An uncertain transport acknowledgement keeps the stable request ID for reconciliation.
                if error is ShaderRequestError {
                    if request.purpose == .creative { savePending(nil) }
                    showBanner(error.localizedDescription)
                } else { connected = false; onLockChanged?() }
            }
        }
    }
    private func offerClarification(_ job: ShaderRequestStatus) {
        guard !answering.contains(job.id), let question = job.clarification,
              let presenter, presenter.presentedViewController == nil, foreground, !covered() else { return }
        let alert = UIAlertController(title: "One detail needed", message: question.question, preferredStyle: .alert)
        func answer(_ text: String) {
            answering.insert(job.id)
            Task { [weak self] in
                guard let self else { return }
                defer { self.answering.remove(job.id) }
                do {
                    let reply = try await self.client.requestControl(operation: "requestAnswer", payload: .init(requestID: job.id, answer: text))
                    if let updated = reply.jobs.first(where: { $0.id == job.id }), let index = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[index] = updated }
                } catch { self.showBanner(error.localizedDescription) }
            }
        }
        for option in question.options.prefix(6) {
            let action = UIAlertAction(title: option, style: .default) { _ in answer(option) }
            alert.addAction(action)
            if alert.preferredAction == nil { alert.preferredAction = action }
        }
        alert.addTextField { $0.placeholder = "Your answer"; $0.returnKeyType = .done }
        alert.addAction(UIAlertAction(title: "Send Answer", style: .default) { [weak alert] _ in
            if let text = alert?.textFields?.first?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer(text) }
        })
        clarificationAlert = alert
        presenter.present(alert, animated: true)
    }
    private func deliver(_ job: ShaderRequestStatus) async {
        guard let result = job.result else { return }
        deliveries.insert(job.id)
        defer { deliveries.remove(job.id) }
        do {
            if !requestedDeliveries.contains(job.id) {
                _ = try await client.requestControl(operation: "requestDelivery", payload: .init(requestID: job.id, answer: deliveryNonce))
                requestedDeliveries.insert(job.id)
                return
            }
            await session.refresh(force: true).value
            guard let output = session.shaders.first(where: { $0.id == result.shaderID }) else {
                throw ShaderRequestError.unavailable("Output shader is no longer in the library.")
            }
            if job.request.purpose == .performance {
                attemptedVersions.insert(output.id + ":" + output.sourceHash)
                optimizationRequests[output.id] = job.id
                if session.activeShader?.id != job.request.context.shaderID || pendingManual != nil {
                    _ = try await client.requestControl(operation: "requestActivated", payload: .init(requestID: job.id))
                    return
                }
            }
            if session.activeShader?.id != output.id || session.activeShader?.sourceHash != output.sourceHash {
                await session.select(output).value
            }
            if job.request.purpose == .performance, session.activeShader?.id != output.id || pendingManual != nil {
                _ = try await client.requestControl(operation: "requestActivated", payload: .init(requestID: job.id))
                return
            }
            guard session.activeShader?.id == output.id, session.activeShader?.sourceHash == output.sourceHash else {
                throw ShaderRequestError.unavailable(session.selectionDiagnostic ?? "TV activation failed")
            }
            let activated = try await renderer.captureSnapshot()
            guard activated.sourceHash == output.sourceHash else { throw ShaderRequestError.unavailable("The activated frame does not match the delivered shader.") }
            _ = try await client.requestControl(operation: "requestActivated", payload: .init(requestID: job.id, sourceHash: output.sourceHash))
            monitor.reset(at: ProcessInfo.processInfo.systemUptime)
        } catch {
            guard foreground, !covered() else { return }
            if error is ShaderRequestError {
                _ = try? await client.requestControl(operation: "requestActivated", payload: .init(requestID: job.id, diagnostic: error.localizedDescription))
                requestedDeliveries.remove(job.id)
            } else { connected = false; onLockChanged?() }
        }
    }
    private func presented(time: Double, gpu: Double?, deliveredFrames: Int = 1) {
        guard foreground, connected, enabled, !covered(), !blocksBrowsing, let shader = session.activeShader else {
            monitor.reset(at: time); return
        }
        if measuringHash != shader.sourceHash { measuringHash = shader.sourceHash; monitor.reset(at: time) }
        guard !dismissedShaders.contains(shader.id), !submittingPerformance,
              !jobs.contains(where: { !$0.stage.terminal && $0.request.purpose == .performance && $0.request.context.shaderID == shader.id }),
              let evidence = monitor.observe(at: time, deliveredFrames: deliveredFrames, gpuMilliseconds: gpu) else { return }
        submittingPerformance = true
        Task {
            defer { submittingPerformance = false }
            do {
                let context = try await renderer.captureSnapshot()
                guard context.sourceHash == shader.sourceHash else { return }
                let evidence = PerformanceEvidence(framesPerSecond: evidence.fps, gpuMilliseconds: evidence.gpu,
                                                   device: "\(UIDevice.current.model) / \(renderer.device.name) / \(UIDevice.current.systemVersion)", sourceHash: shader.sourceHash)
                if attemptedVersions.contains(shader.id + ":" + shader.sourceHash) {
                    offerPerformanceRetry(context: context, evidence: evidence)
                } else {
                    submit(performanceRequest(context: context, evidence: evidence, origin: .automatic))
                }
            } catch { showBanner(error.localizedDescription) }
        }
    }
    private func performanceRequest(context: ShaderRequestContext, evidence: PerformanceEvidence, origin: ShaderRequest.Origin) -> ShaderRequest {
        ShaderRequest(purpose: .performance, origin: origin,
                      prompt: "Improve playback performance of \(context.name) without changing composition, colors, motion or visible detail. Observed playback remains below 27 fps at a 30 fps target.",
                      context: context, performance: evidence, parentRequestID: origin == .manual ? optimizationRequests[context.shaderID] : nil)
    }
    private func offerPerformanceRetry(context: ShaderRequestContext, evidence: PerformanceEvidence) {
        guard let presenter, presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "This shader is still slow", message: "Request another performance improvement for \(context.name)?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            guard let self else { return }; self.submit(self.performanceRequest(context: context, evidence: evidence, origin: .manual))
        })
        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel) { [weak self] _ in self?.dismissedShaders.insert(context.shaderID) })
        presenter.present(alert, animated: true)
    }
    private func showBanner(_ message: String) { banner = message; bannerUntil = Date().addingTimeInterval(12); displayProgress() }
    private func displayProgress() {
        if let job = jobs.first(where: { $0.blocksBrowsing }), connected {
            label.text = "\(job.message) · \(Int(Date().timeIntervalSince(job.createdAt)))s\n\(job.request.prompt)"
        } else if pendingManual != nil, !connected {
            label.text = "Reconnecting to your Mac. Your request continues; cached Gallery browsing is available."
        } else if let job = jobs.first(where: { !$0.stage.terminal && $0.request.purpose == .performance }) {
            label.text = "Optimizing \(job.request.context.name) · \(job.message)"
        } else if bannerUntil > Date() { label.text = banner }
        else { label.text = nil }
        overlay.isHidden = label.text == nil
    }
}
