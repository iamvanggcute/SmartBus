//
//  FormFieldView.swift
//  SmartBus
//
//  Ô nhập có nhãn phía trên, nền xám bo góc và dòng báo lỗi bên dưới (theo thiết kế).
//

import UIKit

final class FormFieldView: UIView {
    let textField = UITextField()

    private let titleLabel = UILabel()
    private let container = UIView()
    private let errorLabel = UILabel()
    private let isSecure: Bool
    private lazy var toggleButton = UIButton(type: .system)

    var text: String {
        get { textField.text ?? "" }
        set { textField.text = newValue }
    }

    init(title: String, isSecure: Bool = false) {
        self.isSecure = isSecure
        super.init(frame: .zero)
        titleLabel.text = title
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hiện/ẩn lỗi dưới ô nhập. Truyền `nil` để xóa lỗi.
    func setError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        container.layer.borderColor = (message == nil ? Theme.line : Theme.danger).cgColor
        container.layer.borderWidth = message == nil ? 1 : 1.5
    }

    private func setupViews() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.ink

        container.backgroundColor = Theme.background
        container.layer.cornerRadius = 14
        container.layer.borderWidth = 1
        container.layer.borderColor = Theme.line.cgColor

        textField.font = .systemFont(ofSize: 15)
        textField.textColor = Theme.ink
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.clearButtonMode = isSecure ? .never : .whileEditing
        textField.isSecureTextEntry = isSecure
        textField.accessibilityLabel = titleLabel.text

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = Theme.dangerText
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        let fieldRow = UIStackView(arrangedSubviews: [textField])
        fieldRow.axis = .horizontal
        fieldRow.spacing = 8
        fieldRow.alignment = .center
        if isSecure {
            toggleButton.tintColor = Theme.muted
            toggleButton.setImage(UIImage(systemName: "eye"), for: .normal)
            toggleButton.accessibilityLabel = "Hiện mật khẩu"
            toggleButton.addTarget(self, action: #selector(toggleSecureEntry), for: .touchUpInside)
            toggleButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
            toggleButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
            fieldRow.addArrangedSubview(toggleButton)
        }

        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 52),
            fieldRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            fieldRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: isSecure ? -4 : -12),
            fieldRow.topAnchor.constraint(equalTo: container.topAnchor),
            fieldRow.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let stack = UIStackView(arrangedSubviews: [titleLabel, container, errorLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func toggleSecureEntry() {
        textField.isSecureTextEntry.toggle()
        let hidden = textField.isSecureTextEntry
        toggleButton.setImage(UIImage(systemName: hidden ? "eye" : "eye.slash"), for: .normal)
        toggleButton.accessibilityLabel = hidden ? "Hiện mật khẩu" : "Ẩn mật khẩu"
    }
}
