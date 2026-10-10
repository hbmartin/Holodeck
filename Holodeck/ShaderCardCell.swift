import HolodeckCore
import UIKit

final class ShaderCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ShaderCard"
    private let gradient = CAGradientLayer()
    private let previewImageView = UIImageView()
    private let updatedLabel = UILabel()
    private(set) var previewTask: Task<Void, Never>?
    private var representedPreview: ShaderPreview?
    private var catalogService: CatalogService?
    private var requestedPixels = CGSize.zero
    private var displayedPixels = CGSize.zero
    private var requestID = UUID()
    private let categoryLabel = UILabel()
    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let stateLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        previewImageView.contentMode = .scaleAspectFill
        previewImageView.clipsToBounds = true
        contentView.addSubview(previewImageView)
        contentView.layer.addSublayer(gradient)
        contentView.layer.cornerRadius = 18
        contentView.clipsToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)

        categoryLabel.font = .systemFont(ofSize: 15, weight: .bold)
        categoryLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .white
        descriptionLabel.font = .systemFont(ofSize: 19, weight: .regular)
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        descriptionLabel.numberOfLines = 3
        stateLabel.font = .systemFont(ofSize: 15, weight: .bold)
        stateLabel.textColor = .white

        updatedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        updatedLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        let stack = UIStackView(arrangedSubviews: [categoryLabel, titleLabel, descriptionLabel, updatedLabel, stateLabel])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
        isAccessibilityElement = true
        updateFocusAppearance()
        registerForTraitChanges([UITraitDisplayScale.self]) { (cell: ShaderCardCell, _: UITraitCollection) in
            cell.requestPreviewIfNeeded()
        }
    }

    required init?(coder: NSCoder) { fatalError("Shader cards are created programmatically.") }

    func configure(shader: ShaderDefinition, active: Bool, loading: Bool, catalogService: CatalogService? = nil) {
        categoryLabel.text = shader.category.rawValue
        updatedLabel.text = shader.updatedAt.map { "Updated " + $0.formatted(date: .abbreviated, time: .omitted) }
        updatedLabel.isHidden = shader.updatedAt == nil
        let previousHash = representedPreview?.hash
        representedPreview = shader.preview
        self.catalogService = catalogService
        if previousHash != shader.preview?.hash {
            previewTask?.cancel()
            previewTask = nil
            previewImageView.image = nil
            requestedPixels = .zero
            displayedPixels = .zero
            requestID = UUID()
        }
        requestPreviewIfNeeded()
        titleLabel.text = shader.title
        descriptionLabel.text = shader.description
        stateLabel.text = loading ? "LOADING…" : (active ? "NOW SHOWING" : " ")
        gradient.colors = shader.colors.map {
            UIColor(red: CGFloat($0.x * 0.65), green: CGFloat($0.y * 0.65),
                    blue: CGFloat($0.z * 0.65), alpha: 0.78).cgColor
        }
        accessibilityIdentifier = "shader-\(shader.id)"
        accessibilityLabel = "\(shader.title), \(shader.category.rawValue), \(shader.description)" + (updatedLabel.text.map { ", " + $0 } ?? "")
        accessibilityValue = loading ? "Loading" : (active ? "Now showing" : "")
        accessibilityTraits = active ? [.button, .selected] : [.button]
    }

    deinit { previewTask?.cancel() }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewTask?.cancel()
        previewTask = nil
        representedPreview = nil
        catalogService = nil
        requestedPixels = .zero
        displayedPixels = .zero
        requestID = UUID()
        previewImageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewImageView.frame = contentView.bounds
        gradient.frame = contentView.bounds
        requestPreviewIfNeeded()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 18).cgPath
    }

    private func requestPreviewIfNeeded() {
        guard let preview = representedPreview, let catalogService,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        let scale = max(1, traitCollection.displayScale) * 1.045
        let pixels = CGSize(width: min(2048, ceil(contentView.bounds.width * scale / 64) * 64),
                            height: min(2048, ceil(contentView.bounds.height * scale / 64) * 64))
        if previewTask != nil, pixels.width <= requestedPixels.width, pixels.height <= requestedPixels.height { return }
        if previewImageView.image != nil, pixels.width <= displayedPixels.width, pixels.height <= displayedPixels.height { return }
        previewTask?.cancel()
        requestedPixels = pixels
        let id = UUID()
        requestID = id
        previewTask = Task { [weak self] in
            let image = try? await catalogService.previewImage(preview, targetPixelSize: pixels)
            guard !Task.isCancelled, let self, self.requestID == id, self.representedPreview?.hash == preview.hash else { return }
            self.previewTask = nil
            if let image {
                self.displayedPixels = pixels
                self.previewImageView.image = UIImage(cgImage: image)
            }
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { self.updateFocusAppearance() }
    }

    private func updateFocusAppearance() {
        transform = isFocused ? CGAffineTransform(scaleX: 1.045, y: 1.045) : .identity
        contentView.layer.borderWidth = isFocused ? 3 : 1
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(isFocused ? 1 : 0.18).cgColor
    }
}
