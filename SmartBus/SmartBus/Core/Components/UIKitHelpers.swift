//
//  UIKitHelpers.swift
//  SmartBus
//
//  Thành phần giao diện nhỏ dùng chung: nhãn dạng viên thuốc, nút theo kiểu thiết kế, avatar.
//

import UIKit

/// Nhãn bo tròn có nền màu (trạng thái học sinh, chiều chuyến…).
final class PillLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 12, weight: .semibold)
        layer.cornerRadius = 11
        layer.masksToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ text: String, background: UIColor, foreground: UIColor) {
        self.text = text
        backgroundColor = background
        textColor = foreground
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

extension ManifestStatus {
    var colors: (background: UIColor, foreground: UIColor) {
        switch self {
        case .expected: return (Theme.background, Theme.slate)
        case .boarded: return (Theme.successSoft, Theme.successText)
        case .alighted: return (Theme.infoSoft, Theme.infoText)
        case .absent: return (UIColor(hex: 0xEDE9FE), UIColor(hex: 0x6D28D9))
        }
    }
}

enum AppButtonStyle {
    case primary, dark, accent, secondary, danger

    var background: UIColor {
        switch self {
        case .primary: return Theme.primary
        case .dark: return Theme.navy
        case .accent: return Theme.schoolBus
        case .secondary: return .white
        case .danger: return Theme.danger
        }
    }

    var foreground: UIColor {
        switch self {
        case .accent: return Theme.navy
        case .secondary: return Theme.ink
        default: return .white
        }
    }
}

enum AppButton {
    /// Nút cao 52pt, bo 14, tự đổi màu xám khi bị tắt.
    static func make(_ title: String, style: AppButtonStyle, symbol: String? = nil) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .fixed
        config.background.cornerRadius = 14
        config.baseBackgroundColor = style.background
        config.baseForegroundColor = style.foreground
        config.imagePadding = 8
        if let symbol { config.image = UIImage(systemName: symbol) }
        if style == .secondary {
            config.background.strokeColor = Theme.line
            config.background.strokeWidth = 1.5
        }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 16, weight: .semibold)
            return updated
        }
        let button = UIButton(configuration: config)
        button.configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            updated.baseBackgroundColor = button.isEnabled ? style.background : Theme.disabled
            updated.baseForegroundColor = button.isEnabled ? style.foreground : Theme.slate
            button.configuration = updated
        }
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }
}

/// Avatar tròn: ảnh chân dung nếu có, không thì chữ viết tắt.
final class AvatarView: UIView {
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()
    private var loadingPath: String?

    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        layer.cornerRadius = size / 2
        clipsToBounds = true
        backgroundColor = Theme.primarySoft

        initialsLabel.font = .systemFont(ofSize: size * 0.34, weight: .bold)
        initialsLabel.textColor = Theme.primary
        initialsLabel.textAlignment = .center
        imageView.contentMode = .scaleAspectFill
        for view in [initialsLabel, imageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, photoPath: String?) {
        initialsLabel.text = Self.initials(of: name)
        imageView.image = nil
        loadingPath = photoPath
        guard let photoPath else { return }
        Task { @MainActor [weak self] in
            let image = await ImageLoader.shared.image(for: photoPath)
            guard let self, self.loadingPath == photoPath else { return }
            self.imageView.image = image
        }
    }

    static func initials(of name: String) -> String {
        let words = name.split(separator: " ")
        let picked = [words.dropLast().last, words.last].compactMap { $0?.first }
        return String(picked).uppercased()
    }
}

extension UIViewController {
    func showAlert(title: String, message: String?, actionTitle: String = "Đóng", handler: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in handler?() })
        present(alert, animated: true)
    }
}

/// Khung trắng bo góc có đổ bóng nhẹ (card).
func makeCard(_ content: UIView, padding: CGFloat = 16) -> UIView {
    let card = UIView()
    card.backgroundColor = .white
    card.layer.cornerRadius = 18
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.06
    card.layer.shadowRadius = 10
    card.layer.shadowOffset = CGSize(width: 0, height: 4)
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
        content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
        content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
        content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding)
    ])
    return card
}

func makeLabel(_ text: String? = nil, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = Theme.ink, lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = lines
    return label
}
