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
    private var catalog: CatalogSnapshot? { session.catalog }
    private var shaders: [ShaderDefinition] { session.shaders }
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
        pickerIsVisible && unavailableMessage == nil && !shaders.isEmpty ? [collectionView] : [view]
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
                ? (shaders.isEmpty ? focused === view : focused?.isDescendant(of: collectionView) == true) : focused === view
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
        switch event {
        case .catalogLoading:
            if shaders.isEmpty {
                catalogErrorMessage = nil
                statusLabel.text = "Downloading shaders…"
                hintLabel.text = "Downloading shaders…"
                hint.isHidden = pickerIsVisible
                spinner.startAnimating()
            }
        case .catalogFailed:
            guard shaders.isEmpty else { return }
            catalogErrorMessage = "Couldn’t download shaders. Connect to the internet and press Select to retry."
            spinner.stopAnimating()
            updateStatus()
            hintLabel.text = catalogErrorMessage
            hint.isHidden = pickerIsVisible
        case .catalogChanged:
            catalogErrorMessage = nil
            (view as? ShowcaseMetalView)?.acceptsFocus = !pickerIsVisible || unavailableMessage != nil
            browsingIndexPath = browsingShaderID.flatMap { id in
                shaders.firstIndex { $0.id == id }.map { IndexPath(item: $0, section: 0) }
            }
            collectionView.reloadData()
            if pickerIsVisible, !shaders.isEmpty {
                collectionView.scrollToItem(at: browsingIndexPath ?? preferredShaderIndexPath, at: .centeredHorizontally, animated: false)
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        case .selectionStarted:
            hintTask?.cancel()
            hint.isHidden = true
            showLoadingHintIfNeeded()
            statusLabel.text = "Loading \(pendingSelection?.shader.title ?? "shader")…"
            spinner.startAnimating()
            updateVisibleCards()
        case .activated(let origin):
            spinner.stopAnimating()
            updateStatus()
            updateVisibleCards()
            if origin == .startup {
                if !pickerIsVisible { showStartupHint() }
            } else {
                hidePicker(cancelSelection: false)
            }
        case .selectionFailed:
            spinner.stopAnimating()
            showPicker()
            if case .selection(let shader, _) = session.failure?.operation {
                statusLabel.text = "Couldn’t load \(shader.title). Choose another shader."
            }
        }
    }

    func applyCatalog(_ snapshot: CatalogSnapshot) { session.applyCatalog(snapshot) }

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
        let heading = UIStackView(arrangedSubviews: [eyebrow, title, statusRow])
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
        picker.contentView.addSubview(collectionView)
        NSLayoutConstraint.activate([
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
        hintLabel.text = startupShader.map { "Loading \($0.title)…" } ?? "Downloading shaders…"
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

    private func showPicker() {
        let wasVisible = pickerIsVisible
        selectGesture.isEnabled = false
        menuGesture.isEnabled = unavailableMessage == nil
        hintTask?.cancel()
        hint.isHidden = true
        pickerIsVisible = true
        (view as? ShowcaseMetalView)?.acceptsFocus = unavailableMessage != nil || shaders.isEmpty
        picker.isHidden = false
        if pendingSelection == nil { updateStatus() }
        updateVisibleCards()
        guard !wasVisible else { return }
        browsingIndexPath = preferredShaderIndexPath
        browsingShaderID = shaders.indices.contains(preferredShaderIndexPath.item) ? shaders[preferredShaderIndexPath.item].id : nil
        view.layoutIfNeeded()
        if unavailableMessage == nil, !shaders.isEmpty {
            collectionView.scrollToItem(at: preferredShaderIndexPath, at: .centeredHorizontally, animated: false)
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hidePicker(cancelSelection: Bool = true) {
        guard unavailableMessage == nil else { return }
        if cancelSelection, pendingSelection?.origin == .user {
            session.cancelPendingSelection()
            spinner.stopAnimating()
            updateVisibleCards()
            if session.activeShader == nil, let startupShader { chooseShader(startupShader, origin: .startup) }
        }
        pickerIsVisible = false
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
        hidePicker()
    }

    private func showLoadingHintIfNeeded() {
        if shaders.isEmpty {
            hintLabel.text = catalogErrorMessage ?? "Downloading shaders…"
            hint.isHidden = pickerIsVisible
            return
        }
        guard !pickerIsVisible, renderer?.activeShader == nil,
              let selection = pendingSelection, selection.origin == .startup else { return }
        hintLabel.text = "Loading \(selection.shader.title)…"
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
            statusLabel.text = catalogErrorMessage ?? "Downloading shaders…"
        } else if let active = renderer?.activeShader {
            statusLabel.text = "Now showing \(active.title) · Select to play · Back to close"
        } else {
            statusLabel.text = "Select a shader to begin · Back to close"
        }
    }

    private func showUnavailable(_ message: String) {
        unavailableMessage = message
        session.cancelPendingSelection()
        (view as? MTKView)?.isPaused = true
        spinner.stopAnimating()
        collectionView.isUserInteractionEnabled = false
        showPicker()
    }

    private var preferredShaderIndexPath: IndexPath {
        let id = renderer?.activeShader?.id ?? startupShader?.id
        return IndexPath(item: shaders.firstIndex(where: { $0.id == id }) ?? 0, section: 0)
    }

    private func updateVisibleCards() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ShaderCardCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func configure(_ cell: ShaderCardCell, at indexPath: IndexPath) {
        let shader = shaders[indexPath.item]
        cell.configure(shader: shader, active: renderer?.activeShader?.id == shader.id,
                       loading: pendingSelection?.shader.id == shader.id, catalogService: catalogService)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        shaders.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShaderCardCell.reuseIdentifier, for: indexPath) as! ShaderCardCell
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard shaders.indices.contains(indexPath.item) else { return }
        chooseShader(shaders[indexPath.item])
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        guard !shaders.isEmpty else { return nil }
        return browsingIndexPath ?? preferredShaderIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if let indexPath = context.nextFocusedIndexPath {
            browsingIndexPath = indexPath
            browsingShaderID = shaders.indices.contains(indexPath.item) ? shaders[indexPath.item].id : nil
        }
    }
}
