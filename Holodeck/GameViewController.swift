import UIKit
import MetalKit
import Dependencies

nonisolated enum RendererStartupError: LocalizedError {
    case metalUnavailable
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "Metal rendering is unavailable on this device."
        case .initializationFailed: return "The renderer could not start. Relaunch Holodeck to try again."
        }
    }
}

final class GameViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    @Dependency(\.rendererFactory) private var rendererFactory
    @Dependency(\.shaderPreferences) private var shaderPreferences
    @Dependency(\.continuousClock) private var hintClock
    private var startupShader = ShaderCatalog.initialShader
    private(set) var shaderSelectionTask: Task<Void, Never>?
    private var renderer: Renderer?
    private var unavailableMessage: String?
    private let picker = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let hint = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let hintLabel = UILabel()
    private(set) var hintTask: Task<Void, Never>?
    private enum SelectionOrigin { case startup, user }
    private struct PendingSelection {
        let shader: ShaderDefinition
        let origin: SelectionOrigin
        let generation: UInt64
    }
    private var pendingSelection: PendingSelection?
    private var selectionGeneration: UInt64 = 0
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
        shaderSelectionTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        pickerIsVisible && unavailableMessage == nil ? [collectionView] : [view]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "shader-surface"
        let savedID = shaderPreferences.lastShaderID()
        startupShader = ShaderCatalog.shaders.first { $0.id == savedID } ?? ShaderCatalog.initialShader
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
            chooseShader(startupShader, origin: .startup)
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
        renderer?.setActive(active)
        if unavailableMessage != nil { (view as? MTKView)?.isPaused = true }
        if active {
            // UIKit may clear the first responder when the app leaves the foreground.
            becomeFirstResponder()
            let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
            let focusIsRestored = pickerIsVisible && unavailableMessage == nil
                ? focused?.isDescendant(of: collectionView) == true : focused === view
            if !focusIsRestored {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
    }

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
        hintLabel.text = "Loading \(startupShader.title)…"
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
        (view as? ShowcaseMetalView)?.acceptsFocus = unavailableMessage != nil
        picker.isHidden = false
        if pendingSelection == nil { updateStatus() }
        updateVisibleCards()
        guard !wasVisible else { return }
        browsingIndexPath = preferredShaderIndexPath
        view.layoutIfNeeded()
        if unavailableMessage == nil {
            collectionView.scrollToItem(at: preferredShaderIndexPath, at: .centeredHorizontally, animated: false)
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hidePicker(cancelSelection: Bool = true) {
        guard unavailableMessage == nil else { return }
        if cancelSelection, pendingSelection?.origin == .user {
            selectionGeneration &+= 1
            renderer?.cancelPendingSelection()
            pendingSelection = nil
            spinner.stopAnimating()
            updateVisibleCards()
            if renderer?.activeShader == nil {
                chooseShader(startupShader, origin: .startup)
            }
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
        guard let renderer, unavailableMessage == nil else { return }
        hintTask?.cancel()
        hint.isHidden = true
        selectionGeneration &+= 1
        let selection = PendingSelection(shader: shader, origin: origin, generation: selectionGeneration)
        pendingSelection = selection
        showLoadingHintIfNeeded()
        statusLabel.text = "Loading \(shader.title)…"
        spinner.startAnimating()
        updateVisibleCards()

        shaderSelectionTask = withDependencies(from: self) {
            Task { [weak self] in
                guard self?.pendingSelection?.generation == selection.generation else { return }
                do {
                    guard try await renderer.select(shader), let self,
                          self.pendingSelection?.generation == selection.generation else { return }
                    self.pendingSelection = nil
                    self.shaderPreferences.setLastShaderID(shader.id)
                    self.spinner.stopAnimating()
                    self.updateStatus()
                    self.updateVisibleCards()
                    if origin == .startup {
                        if !self.pickerIsVisible { self.showStartupHint() }
                    } else {
                        self.hidePicker(cancelSelection: false)
                    }
                } catch {
                    guard let self, self.pendingSelection?.generation == selection.generation else { return }
                    self.pendingSelection = nil
                    self.spinner.stopAnimating()
                    self.showPicker()
                    self.statusLabel.text = "Couldn’t load \(shader.title). Choose another shader."
                    print("Shader compilation failed for \(shader.id): \(error)")
                }
            }
        }
    }

    @objc func openPickerFromRemote() {
        showPicker()
    }

    @objc func closePickerFromRemote() {
        guard pickerIsVisible, unavailableMessage == nil else { return }
        hidePicker()
    }

    private func showLoadingHintIfNeeded() {
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
        } else if let active = renderer?.activeShader {
            statusLabel.text = "Now showing \(active.title) · Select to play · Back to close"
        } else {
            statusLabel.text = "Select a shader to begin · Back to close"
        }
    }

    private func showUnavailable(_ message: String) {
        unavailableMessage = message
        pendingSelection = nil
        (view as? MTKView)?.isPaused = true
        spinner.stopAnimating()
        collectionView.isUserInteractionEnabled = false
        showPicker()
    }

    private var preferredShaderIndexPath: IndexPath {
        let id = renderer?.activeShader?.id ?? startupShader.id
        return IndexPath(item: ShaderCatalog.shaders.firstIndex(where: { $0.id == id }) ?? 0, section: 0)
    }

    private func updateVisibleCards() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? ShaderCardCell else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func configure(_ cell: ShaderCardCell, at indexPath: IndexPath) {
        let shader = ShaderCatalog.shaders[indexPath.item]
        cell.configure(shader: shader, active: renderer?.activeShader?.id == shader.id,
                       loading: pendingSelection?.shader.id == shader.id)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        ShaderCatalog.shaders.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ShaderCardCell.reuseIdentifier, for: indexPath) as! ShaderCardCell
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        chooseShader(ShaderCatalog.shaders[indexPath.item])
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        browsingIndexPath ?? preferredShaderIndexPath
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        if let indexPath = context.nextFocusedIndexPath { browsingIndexPath = indexPath }
    }
}
