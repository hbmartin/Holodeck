import UIKit

final class ShaderCardCell: UICollectionViewCell {
    static let reuseIdentifier = "ShaderCard"
    private let gradient = CAGradientLayer()
    private let categoryLabel = UILabel()
    private let titleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let stateLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.insertSublayer(gradient, at: 0)
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
        descriptionLabel.font = .systemFont(ofSize: 19, weight: .regular)
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        descriptionLabel.numberOfLines = 3
        stateLabel.font = .systemFont(ofSize: 15, weight: .bold)
        stateLabel.textColor = .white
        [titleLabel, descriptionLabel, stateLabel].forEach { $0.textColor = .white }

        let stack = UIStackView(arrangedSubviews: [categoryLabel, titleLabel, descriptionLabel, stateLabel])
        stack.axis = .vertical
        stack.spacing = 9
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
    }

    required init?(coder: NSCoder) { fatalError("Shader cards are created programmatically.") }

    func configure(shader: ShaderDefinition, active: Bool, loading: Bool) {
        categoryLabel.text = shader.category.rawValue
        titleLabel.text = shader.title
        descriptionLabel.text = shader.description
        stateLabel.text = loading ? "LOADING…" : (active ? "NOW SHOWING" : " ")
        gradient.colors = shader.colors.map {
            UIColor(red: CGFloat($0.x * 0.65), green: CGFloat($0.y * 0.65),
                    blue: CGFloat($0.z * 0.65), alpha: 1).cgColor
        }
        accessibilityIdentifier = "shader-\(shader.id)"
        accessibilityLabel = "\(shader.title), \(shader.category.rawValue), \(shader.description)"
        accessibilityValue = loading ? "Loading" : (active ? "Now showing" : "")
        accessibilityTraits = active ? [.button, .selected] : [.button]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = contentView.bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 18).cgPath
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
