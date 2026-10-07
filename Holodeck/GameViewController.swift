import UIKit
import MetalKit

final class GameViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var renderer: Renderer?
    private let picker = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let hint = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let hintLabel = UILabel()
    private var hintTask: Task<Void, Never>?
    private var pendingShaderID: String?
    private var pickerIsVisible = false
    private lazy var selectGesture = UITapGestureRecognizer(target: self, action: #selector(openPickerFromRemote))
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 320, height: 232)
        layout.minimumLineSpacing = 24
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    override var canBecomeFirstResponder: Bool { true }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        pickerIsVisible ? [collectionView] : [view]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "shader-surface"
        buildPicker()
        buildHint()
        selectGesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        view.addGestureRecognizer(selectGesture)

        guard let metalView = view as? MTKView,
              let device = MTLCreateSystemDefaultDevice() else {
            showUnavailable("Metal rendering is unavailable on this device.")
            return
        }
        metalView.device = device
        guard let renderer = Renderer(metalKitView: metalView) else {
            showUnavailable("The renderer could not start. Relaunch Holodeck to try again.")
            return
        }
        self.renderer = renderer
        metalView.delegate = renderer
        chooseShader(ShaderCatalog.initialShader, isInitial: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        setSceneActive(view.window?.windowScene?.activationState == .foregroundActive)
    }

    func setSceneActive(_ active: Bool) {
        renderer?.setActive(active)
        if active {
            // UIKit may clear the first responder when the app leaves the foreground.
            becomeFirstResponder()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pickerIsVisible, presses.contains(where: { $0.type == .menu }) {
            hidePicker()
            return
        }
        super.pressesBegan(presses, with: event)
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
        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.spacing = 12
        statusRow.alignment = .center
        let heading = UIStackView(arrangedSubviews: [eyebrow, title, statusRow])
        heading.axis = .vertical
        heading.spacing = 8
        heading.translatesAutoresizingMaskIntoConstraints = false
        picker.contentView.addSubview(heading)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInset = UIEdgeInsets(top: 16, left: 72, bottom: 16, right: 72)
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
            picker.heightAnchor.constraint(equalToConstant: 430),
            heading.leadingAnchor.constraint(equalTo: picker.contentView.leadingAnchor, constant: 72),
            heading.trailingAnchor.constraint(equalTo: picker.contentView.trailingAnchor, constant: -72),
            heading.topAnchor.constraint(equalTo: picker.contentView.topAnchor, constant: 26),
            collectionView.leadingAnchor.constraint(equalTo: picker.contentView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: picker.contentView.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            collectionView.bottomAnchor.constraint(equalTo: picker.contentView.bottomAnchor, constant: -30)
        ])
    }

    private func buildHint() {
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.layer.cornerRadius = 18
        hint.clipsToBounds = true
        hintLabel.text = "Loading Plasma…"
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
        selectGesture.isEnabled = false
        hintTask?.cancel()
        hint.isHidden = true
        pickerIsVisible = true
        (view as? ShowcaseMetalView)?.acceptsFocus = false
        picker.isHidden = false
        if pendingShaderID == nil { updateStatus() }
        updateVisibleCards()
        view.layoutIfNeeded()
        collectionView.scrollToItem(at: preferredShaderIndexPath, at: .centeredHorizontally, animated: false)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hidePicker(cancelSelection: Bool = true) {
        if cancelSelection, renderer?.activeShader != nil {
            renderer?.cancelPendingSelection()
            pendingShaderID = nil
            spinner.stopAnimating()
        }
        pickerIsVisible = false
        selectGesture.isEnabled = true
        (view as? ShowcaseMetalView)?.acceptsFocus = true
        picker.isHidden = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func chooseShader(_ shader: ShaderDefinition, isInitial: Bool = false) {
        guard let renderer else { return }
        hintTask?.cancel()
        hint.isHidden = !isInitial
        pendingShaderID = shader.id
        statusLabel.text = "Loading \(shader.title)…"
        spinner.startAnimating()
        updateVisibleCards()

        Task { [weak self] in
            do {
                guard try await renderer.select(shader), let self else { return }
                self.pendingShaderID = nil
                self.spinner.stopAnimating()
                self.updateStatus()
                self.updateVisibleCards()
                self.hidePicker(cancelSelection: false)
                if isInitial { self.showStartupHint() }
            } catch {
                guard let self else { return }
                self.pendingShaderID = nil
                self.spinner.stopAnimating()
                self.showPicker()
                self.statusLabel.text = "Couldn’t load \(shader.title). Choose another shader."
                print("Shader compilation failed for \(shader.id): \(error)")
            }
        }
    }

    @objc private func openPickerFromRemote() {
        showPicker()
    }

    private func showStartupHint() {
        hintLabel.text = "Press Select to choose a shader"
        hint.isHidden = false
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint.isHidden = true
        }
    }

    private func updateStatus() {
        if let active = renderer?.activeShader {
            statusLabel.text = "Now showing \(active.title) · Select to play · Back to close"
        } else {
            statusLabel.text = "Select a shader to begin · Back to close"
        }
    }

    private func showUnavailable(_ message: String) {
        showPicker()
        statusLabel.text = message
        collectionView.isUserInteractionEnabled = false
    }

    private var preferredShaderIndexPath: IndexPath {
        let id = renderer?.activeShader?.id ?? ShaderCatalog.initialShader.id
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
                       loading: pendingShaderID == shader.id)
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
        preferredShaderIndexPath
    }
}
