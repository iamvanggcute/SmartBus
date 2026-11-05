//
//  MessageBannerView.swift
//  SmartBus
//
//  Khung thông báo có biểu tượng, tiêu đề và nội dung (lỗi / cảnh báo / thông tin).
//

import UIKit

final class MessageBannerView: UIView {
    enum Style {
        case error, warning, info

        var background: UIColor {
            switch self {
            case .error: return Theme.dangerSoft
            case .warning: return Theme.warningSoft
            case .info: return Theme.infoSoft
            }
        }

        var foreground: UIColor {
            switch self {
            case .error: return Theme.dangerText
            case .warning: return Theme.warningText
            case .info: return Theme.infoText
            }
        }

        var symbol: String {
            switch self {
            case .error, .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, message: String, style: Style) {
        backgroundColor = style.background
        iconView.image = UIImage(systemName: style.symbol)
        iconView.tintColor = style.foreground
        titleLabel.textColor = style.foreground
        messageLabel.textColor = style.foreground
        titleLabel.text = title
        messageLabel.text = message
        isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
    }

    func hide() {
        isHidden = true
    }

    private func setupViews() {
        layer.cornerRadius = 14
        isHidden = true
        isAccessibilityElement = false

        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [iconView, textStack])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }
}
