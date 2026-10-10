import HolodeckCore
import UIKit
import MetalKit
import Dependencies

final class GameViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    @Dependency(\.rendererFactory) private var rendererFactory
    @Dependency(\.shaderPreferences) private var shaderPreferences
    @Dependency(\.catalogService) private var catalogService
    private lazy var session = withDependencies(from: self) {
        ViewerSession(catalogService: catalogService, preferences: shaderPreferences, policy: .tv)
    }
    private var catalog: ValidatedCatalog? { session.catalog }
    private var shaders: [ShaderDefinition] { session.shaders }
    private var collections: [CatalogCollection] { catalog?.collections ?? [] }
    private var collectionID = "all"
    private var mood = ""
    private var motion = ""
    private let filterCache = SceneFilterCache()
    private var visibleShaders: [ShaderDefinition] {
        filterCache.filter(catalog, collectionID: collectionID,
                           mood: mood.isEmpty ? nil : mood, motion: motion.isEmpty ? nil : motion)
    }
    private let filterControls = UIStackView()
    private let collectionButton = UIButton(type: .system)
    private let moodButton = UIButton(type: .system)
    private let motionButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let retryUpdatesButton = UIButton(type: .system)
    private let updateNotice = UILabel()
    private let emptyResults = UILabel()
    private var chooser: UIAlertController?
    private let cardsFocusGuide = UIFocusGuide()
    private weak var returnFocusButton: UIButton?
    private weak var chooserSourceButton: UIButton?
    private var startupShader: ShaderDefinition? { session.startupShader }
    private var pendingSelection: ViewerSession.PendingSelection? { session.pendingSelection }
    private typealias SelectionOrigin = ViewerSession.SelectionOrigin
    var shaderSelectionTask: Task<Void, Never>? { session.selectionTask }
    @Dependency(\.continuousClock) private var hintClock
    private var catalogErrorMessage: String?
    private var renderer: Renderer?
    private var unavailableMessage: String?
    private let picker = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let hint = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let hintLabel = UILabel()
    private(set) var hintTask: Task<Void, Never>?
    private var browsingShaderID: String?
    private var pickerIsVisible = false
    private var browsingIndexPath: IndexPath?
    private lazy var selectGesture = UITapGestureRecognizer(target: self, action: #selector(openPickerFromRemote))
    private lazy var menuGesture = UITapGestureRecognizer(target: self, action: #selector(closePickerFromRemote))
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 320, height: 232)
        layout.minimumLineSpacing = 24
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    deinit {
        hintTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        guard pickerIsVisible, unavailableMessage == nil, !shaders.isEmpty else { return [view] }
        if let returnFocusButton, !returnFocusButton.isHidden { return [returnFocusButton] }
        if visibleShaders.isEmpty { return [resetButton] }
        if let cell = collectionView.cellForItem(at: browsingIndexPath ?? preferredShaderIndexPath) { return [cell] }
        return [collectionView]
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // Route Down from controls into the preferred card without intercepting Up from cards.
        updateCardsFocusGuide(focused: context.nextFocusedView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "shader-surface"
        session.onEvent = { [weak self] event in self?.handleSessionEvent(event) }
        buildPicker()
        buildHint()
        selectGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        view.addGestureRecognizer(selectGesture)
        menuGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuGesture.isEnabled = false
        view.addGestureRecognizer(menuGesture)
        guard let metalView = view as? MTKView else {
            showUnavailable(RendererStartupError.metalUnavailable.localizedDescription)
            return
        }
        metalView.isPaused = true
        do {
            let renderer = try withDependencies(from: self) { try rendererFactory(metalView) }
            self.renderer = renderer
            metalView.delegate = renderer
            session.attach(renderer)
        } catch {
            showUnavailable(error.localizedDescription)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        setSceneActive(view.window?.windowScene?.activationState == .foregroundActive)
    }

    func setSceneActive(_ active: Bool) {
        session.setActive(active)
        if unavailableMessage != nil { (view as? MTKView)?.isPaused = true }
        if active {
            // UIKit may clear the first responder when the app leaves the foreground.
            becomeFirstResponder()
            let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
            let focusIsRestored = pickerIsVisible && unavailableMessage == nil
                ? (shaders.isEmpty ? focused === view : focused?.isDescendant(of: picker) == true) : focused === view
            if !focusIsRestored {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
    }

    private func refreshCatalog() {
        guard unavailableMessage == nil else { return }
        session.refresh()
    }

    private func handleSessionEvent(_ event: ViewerSession.Event) {
        defer { updateInteractionState() }
        switch event {
        case .catalogLoading:
            updateCatalogNotice()
            if shaders.isEmpty {
                catalogErrorMessage = nil
                statusLabel.text = catalogLoadingMessage
                hintLabel.text = catalogLoadingMessage
                hint.isHidden = pickerIsVisible
            }
        case .catalogCacheChecked:
            updateStatus()
            showLoadingHintIfNeeded()
        case .catalogFinished:
            updateCatalogNotice()
        case .catalogFailed:
            updateCatalogNotice()
            guard shaders.isEmpty else { return }
            catalogErrorMessage = "Couldn’t download shaders. Connect to the internet and press Select to retry."
            updateStatus()
            hintLabel.text = catalogErrorMessage
            hint.isHidden = pickerIsVisible
        case .catalogChanged:
            catalogErrorMessage = nil
            (view as? ShowcaseMetalView)?.acceptsFocus = !pickerIsVisible || unavailableMessage != nil
            refreshBrowsing()
        case .selectionStarted:
            hintTask?.cancel()
            hint.isHidden = true
            showLoadingHintIfNeeded()
            updateStatus()
            updateVisibleCards()
        case .activated(let origin):
            updateStatus()
            updateVisibleCards()
            if origin == .startup {
                if !pickerIsVisible { showStartupHint() }
            } else {
                hidePicker(cancelSelection: false)
            }
        case .selectionFailed:
            showPicker()
            updateStatus()
        }
    }

    func applyCatalog(_ snapshot: ValidatedCatalog) { session.applyCatalog(snapshot) }

    private func buildPicker() {
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.isHidden = true
        picker.accessibilityIdentifier = "shader-picker"
        view.addSubview(picker)

        let eyebrow = UILabel()
        eyebrow.text = "HOLODECK / SHADER SHOWCASE"
        eyebrow.font = .systemFont(ofSize: 16, weight: .bold)
        eyebrow.textColor = UIColor.white.withAlphaComponent(0.65)
        let title = UILabel()
        title.text = "Choose a shader"
        title.font = .systemFont(ofSize: 36, weight: .semibold)
        title.textColor = .white
        statusLabel.font = .systemFont(ofSize: 20)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        statusLabel.accessibilityIdentifier = "shader-status"
        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.accessibilityIdentifier = "shader-loading"
        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.accessibilityIdentifier = "shader-status-row"
        statusRow.spacing = 12
        statusRow.alignment = .center
        statusRow.heightAnchor.constraint(equalToConstant: max(40, spinner.intrinsicContentSize.height)).isActive = true
        buildFilterControls()
        updateNotice.font = .systemFont(ofSize: 17)
        updateNotice.textColor = UIColor.white.withAlphaComponent(0.7)
        updateNotice.accessibilityIdentifier = "catalog-update-notice"
        updateNotice.isHidden = true
        let heading = UIStackView(arrangedSubviews: [eyebrow, title, statusRow, updateNotice, filterControls])
        heading.axis = .vertical
        heading.spacing = 8
        heading.translatesAutoresizingMaskIntoConstraints = false
        picker.contentView.addSubview(heading)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "shader-cards"
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ShaderCardCell.self, forCellWithReuseIdentifier: ShaderCardCell.reuseIdentifier)
        emptyResults.text = "No matching shaders"
        emptyResults.textColor = .white
        emptyResults.textAlignment = .center
        emptyResults.font = .systemFont(ofSize: 24)
        emptyResults.accessibilityIdentifier = "no-matching-shaders"
        collectionView.backgroundView = emptyResults
        updateFilterControls()
        picker.contentView.addSubview(collectionView)
        picker.contentView.addLayoutGuide(cardsFocusGuide)
        cardsFocusGuide.preferredFocusEnvironments = [collectionView]
        NSLayoutConstraint.activate([
            cardsFocusGuide.topAnchor.constraint(equalTo: filterControls.bottomAnchor),
            cardsFocusGuide.bottomAnchor.constraint(equalTo: collectionView.topAnchor),
            cardsFocusGuide.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            cardsFocusGuide.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: picker.contentView.topAnchor, constant: 26),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            collectionView.heightAnchor.constraint(equalToConstant: 272),
            collectionView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30)
        ])
    }

    private func buildHint() {
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.accessibilityIdentifier = "shader-hint"
        hint.layer.cornerRadius = 18
        hint.clipsToBounds = true
        hintLabel.text = startupShader.map(loadingMessage) ?? catalogLoadingMessage
        hintLabel.font = .systemFont(ofSize: 23, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hint.contentView.addSubview(hintLabel)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            hintLabel.leadingAnchor.constraint(equalTo: hint.contentView.leadingAnchor, constant: 26),
            hintLabel.trailingAnchor.constraint(equalTo: hint.contentView.trailingAnchor, constant: -26),
            hintLabel.topAnchor.constraint(equalTo: hint.contentView.topAnchor, constant: 16),
            hintLabel.bottomAnchor.constraint(equalTo: hint.contentView.bottomAnchor, constant: -16)
        ])
    }

    private var catalogLoadingMessage: String { session.hasCheckedCache ? "Downloading shaders…" : "Loading scenes…" }

    private func updateInteractionState() {
        if unavailableMessage == nil && (pendingSelection != nil || (shaders.isEmpty && session.isRefreshing)) {
            spinner.startAnimating()
        } else { spinner.stopAnimating() }
        let idleRecovery = session.requiresExplicitSelection && session.activeShader == nil && pendingSelection == nil
        menuGesture.isEnabled = pickerIsVisible && unavailableMessage == nil && !idleRecovery
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        Task { await catalogService.trimPreviewCaches() }
    }

    private func showPicker() {
        let wasVisible = pickerIsVisible
        selectGesture.isEnabled = false
        hintTask?.cancel()
        hint.isHidden = true
        pickerIsVisible = true
        updateInteractionState()
        (view as? ShowcaseMetalView)?.acceptsFocus = unavailableMessage != nil || shaders.isEmpty
        picker.isHidden = false
        updateFilterControls()
        if pendingSelection == nil { updateStatus() }
        updateVisibleCards()
        guard !wasVisible else { return }
        returnFocusButton = nil
        let openingIndexPath = preferredShaderIndexPath
        browsingIndexPath = openingIndexPath
        browsingShaderID = visibleShaders.indices.contains(preferredShaderIndexPath.item) ? visibleShaders[preferredShaderIndexPath.item].id : nil
        view.layoutIfNeeded()
        if unavailableMessage == nil, !visibleShaders.isEmpty {
            collectionView.scrollToItem(at: preferredShaderIndexPath, at: .centeredHorizontally, animated: false)
            collectionView.layoutIfNeeded()
        }
        // Layout can deliver focus callbacks for the previously visible item.
        browsingIndexPath = openingIndexPath
        browsingShaderID = visibleShaders.indices.contains(openingIndexPath.item) ? visibleShaders[openingIndexPath.item].id : nil
        collectionView.setNeedsFocusUpdate()
        collectionView.updateFocusIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hidePicker(cancelSelection: Bool = true) {
        defer { updateInteractionState() }
        guard unavailableMessage == nil else { return }
        if cancelSelection, pendingSelection?.origin == .user {
            session.cancelPendingSelection(resumeStartup: true)
            updateVisibleCards()
        }
        // Back can reveal a loading startup, but never an empty viewer after a compile failure.
        if !shaders.isEmpty, session.activeShader == nil, pendingSelection == nil {
            updateStatus()
            return
        }
        pickerIsVisible = false
        chooser?.dismiss(animated: false)
        chooser = nil
        chooserSourceButton = nil
        returnFocusButton = nil
        selectGesture.isEnabled = true
        menuGesture.isEnabled = false
        (view as? ShowcaseMetalView)?.acceptsFocus = true
        picker.isHidden = true
        showLoadingHintIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func chooseShader(_ shader: ShaderDefinition, origin: SelectionOrigin = .user) {
        guard renderer != nil, unavailableMessage == nil else { return }
        session.select(shader, origin: origin)
    }

    @objc func openPickerFromRemote() {
        showPicker()
        if shaders.isEmpty { refreshCatalog() }
    }

    @objc func closePickerFromRemote() {
        guard pickerIsVisible, unavailableMessage == nil else { return }
        if let chooser, chooser.presentingViewController != nil {
            let sender = chooserSourceButton
            chooser.dismiss(animated: true) { [weak self] in self?.restoreControlFocus(to: sender) }
            self.chooser = nil
            chooserSourceButton = nil
            return
        }
        chooser = nil
        hidePicker()
    }

    private func showLoadingHintIfNeeded() {
        if shaders.isEmpty {
            hintLabel.text = catalogErrorMessage ?? catalogLoadingMessage
            hint.isHidden = pickerIsVisible
            return
        }
        guard !pickerIsVisible, renderer?.activeShader == nil,
              let selection = pendingSelection, selection.origin == .startup else { return }
        hintLabel.text = loadingMessage(selection.shader)
        hint.isHidden = false
    }

    private func showStartupHint() {
        hintLabel.text = "Press Select to choose a shader"
        hint.isHidden = false
        let clock = hintClock
        hintTask = withDependencies(from: self) {
            Task { [weak self] in
                do { try await clock.sleep(for: .seconds(4)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.hint.isHidden = true
            }
        }
    }

    private func updateStatus() {
        if let unavailableMessage {
            statusLabel.text = unavailableMessage
        } else if shaders.isEmpty {
            statusLabel.text = catalogErrorMessage ?? catalogLoadingMessage
        } else if let pendingSelection {
            statusLabel.text = loadingMessage(pendingSelection.shader)
        } else if case .selection(let shader, _) = session.failure?.operation {
            statusLabel.text = "Couldn’t load \(shader.title). Choose another shader."
        } else if let active = renderer?.activeShader {
            statusLabel.text = "Now showing \(active.title) · Select to play · Back to close"
        } else {
            statusLabel.text = "Select a shader to begin"
        }
    }

    private func loadingMessage(_ shader: ShaderDefinition) -> String { "Loading \(shader.title)…" }

    private func showUnavailable(_ message: String) {
        unavailableMessage = message
        session.cancelPendingSelection()
        (view as? MTKView)?.isPaused = true
        spinner.stopAnimating()
        collectionView.isUserInteractionEnabled = false
        showPicker()
    }

    private var preferredShaderIndexPath: IndexPath {
        let ids = [renderer?.activeShader?.id, startupShader?.id, catalog?.initialShader.id].compactMap { $0 }
        let visible = visibleShaders
        let index = ids.lazy.compactMap { id in visible.firstIndex { $0.id == id } }.first ?? 0
        return IndexPath(item: index, section: 0)
    }

    private func updateVisibleCards() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ShaderCardCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func configure(_ cell: ShaderCardCell, at indexPath: IndexPath) {
        guard visibleShaders.indices.contains(indexPath.item) else { return }
        let shader = visibleShaders[indexPath.item]
        cell.configure(shader: shader, active: renderer?.activeShader?.id == shader.id,
                       loading: pendingSelection?.shader.id == shader.id, catalogService: catalogService)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleShaders.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShaderCardCell.reuseIdentifier, for: indexPath) as! ShaderCardCell
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard visibleShaders.indices.contains(indexPath.item) else { return }
        chooseShader(visibleShaders[indexPath.item])
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        guard !visibleShaders.isEmpty else { return nil }
        return browsingIndexPath ?? preferredShaderIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if let indexPath = context.nextFocusedIndexPath {
            returnFocusButton = nil
            browsingIndexPath = indexPath
            browsingShaderID = visibleShaders.indices.contains(indexPath.item) ? visibleShaders[indexPath.item].id : nil
        }
    }

    private func buildFilterControls() {
        filterControls.axis = .horizontal
        filterControls.spacing = 24
        filterControls.alignment = .center
        for (button, id) in [(collectionButton, "collection-filter"), (moodButton, "mood-filter"), (motionButton, "motion-filter"), (resetButton, "reset-filters"), (retryUpdatesButton, "retry-scene-updates")] {
            button.accessibilityIdentifier = id
            button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
            filterControls.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
        collectionButton.addTarget(self, action: #selector(chooseCollection), for: .primaryActionTriggered)
        moodButton.addTarget(self, action: #selector(chooseMood), for: .primaryActionTriggered)
        motionButton.addTarget(self, action: #selector(chooseMotion), for: .primaryActionTriggered)
        resetButton.addTarget(self, action: #selector(resetFilters), for: .primaryActionTriggered)
        retryUpdatesButton.setTitle("Retry Updates", for: .normal)
        retryUpdatesButton.isHidden = true
        retryUpdatesButton.addTarget(self, action: #selector(retryUpdates), for: .primaryActionTriggered)
    }

    private func updateFilterControls() {
        filterControls.isHidden = shaders.isEmpty || unavailableMessage != nil
        collectionButton.setTitle("Collection: " + (collections.first { $0.id == collectionID }?.name ?? "All"), for: .normal)
        moodButton.setTitle("Mood: " + (mood.isEmpty ? "Any" : mood.capitalized), for: .normal)
        motionButton.setTitle("Motion: " + (motion.isEmpty ? "Any" : motion.capitalized), for: .normal)
        moodButton.isHidden = catalog?.moods.isEmpty != false
        motionButton.isHidden = catalog?.motions.isEmpty != false
        resetButton.setTitle("Reset Filters", for: .normal)
        resetButton.isHidden = collectionID == "all" && mood.isEmpty && motion.isEmpty
        emptyResults.isHidden = shaders.isEmpty || !visibleShaders.isEmpty
        updateCatalogNotice()
        updateCardsFocusGuide(focused: UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView)
    }

    private func updateCatalogNotice() {
        updateNotice.text = session.catalogUpdateFailure?.message
        updateNotice.isHidden = session.catalogUpdateFailure == nil
        let wasFocused = UIFocusSystem.focusSystem(for: view)?.focusedItem === retryUpdatesButton
        retryUpdatesButton.isHidden = session.catalogUpdateFailure == nil
        retryUpdatesButton.isEnabled = !session.isRefreshing
        if wasFocused, retryUpdatesButton.isHidden { restoreControlFocus(to: collectionButton) }
    }

    private func updateCardsFocusGuide(focused: UIView?) {
        cardsFocusGuide.isEnabled = pickerIsVisible && unavailableMessage == nil && !visibleShaders.isEmpty
            && focused?.isDescendant(of: filterControls) == true
    }

    @objc private func retryUpdates() {
        if let failure = session.catalogUpdateFailure { session.retry(failure) }
    }

    private func refreshBrowsing(returningTo button: UIButton? = nil) {
        let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIButton
        let focusedControl = focused?.isDescendant(of: filterControls) == true ? focused : nil
        if !collections.contains(where: { $0.id == collectionID }) { collectionID = "all" }
        if catalog?.moods.contains(mood) != true { mood = "" }
        if catalog?.motions.contains(motion) != true { motion = "" }
        updateFilterControls()
        browsingIndexPath = browsingShaderID.flatMap { id in visibleShaders.firstIndex { $0.id == id }.map { IndexPath(item: $0, section: 0) } }
        browsingIndexPath = browsingIndexPath ?? (visibleShaders.isEmpty ? nil : preferredShaderIndexPath)
        browsingShaderID = browsingIndexPath.map { visibleShaders[$0.item].id }
        collectionView.reloadData()
        updateStatus()
        if pickerIsVisible {
            view.layoutIfNeeded()
            if let browsingIndexPath { collectionView.scrollToItem(at: browsingIndexPath, at: .centeredHorizontally, animated: false) }
            collectionView.layoutIfNeeded()
            if chooser?.presentingViewController == nil { restoreControlFocus(to: button ?? focusedControl) }
        }
    }

    private func restoreControlFocus(to button: UIButton? = nil) {
        guard pickerIsVisible else { return }
        returnFocusButton = button.map { $0.isHidden || !$0.isEnabled ? collectionButton : $0 }
        defer { returnFocusButton = nil }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func showOptions(_ title: String, values: [(String, String)], selected: String, sender: UIButton,
                             apply: @escaping (String) -> Void) {
        guard chooser?.presentingViewController == nil else { return }
        chooserSourceButton = sender
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (value, label) in values {
            let action = UIAlertAction(title: label, style: .default) { [weak self] _ in
                apply(value)
                self?.chooser = nil
                self?.chooserSourceButton = nil
                self?.refreshBrowsing(returningTo: sender)
            }
            alert.addAction(action)
            if value == selected { alert.preferredAction = action }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.chooser = nil
            self?.chooserSourceButton = nil
            self?.restoreControlFocus(to: sender)
        })
        chooser = alert
        present(alert, animated: true)
    }

    @objc private func chooseCollection() {
        showOptions("Collection", values: [("all", "All")] + collections.map { ($0.id, $0.name) }, selected: collectionID, sender: collectionButton) { [weak self] in self?.collectionID = $0 }
    }
    @objc private func chooseMood() {
        showOptions("Mood", values: [("", "Any")] + (catalog?.moods ?? []).map { ($0, $0.capitalized) }, selected: mood, sender: moodButton) { [weak self] in self?.mood = $0 }
    }
    @objc private func chooseMotion() {
        showOptions("Motion", values: [("", "Any")] + (catalog?.motions ?? []).map { ($0, $0.capitalized) }, selected: motion, sender: motionButton) { [weak self] in self?.motion = $0 }
    }
    @objc private func resetFilters() { collectionID = "all"; mood = ""; motion = ""; refreshBrowsing(returningTo: collectionButton) }
}
