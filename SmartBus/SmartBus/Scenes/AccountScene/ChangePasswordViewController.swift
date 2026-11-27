//
//  ChangePasswordViewController.swift
//  SmartBus
//
//  Đổi mật khẩu (US43, thiết kế A-ChangePassword), dùng cho phụ xe và phụ huynh.
//  PATCH /auth/password → nhận token mới cho máy này; các thiết bị khác bị đăng xuất.
//  Quy tắc giống server: ≥ 8 ký tự, có cả chữ và số, khác mật khẩu hiện tại, tối đa 72 byte.
//

import UIKit

final class ChangePasswordViewController: UIViewController {
    private let authService = AuthService()
    private var isSaving = false

    private let banner = MessageBannerView()
    private let currentField = FormFieldView(title: "Mật khẩu hiện tại", isSecure: true)
    private let newField = FormFieldView(title: "Mật khẩu mới", isSecure: true)
    private let confirmField = FormFieldView(title: "Nhập lại mật khẩu mới", isSecure: true)
    private let rulesStack = UIStackView()
    private let saveButton = AppButton.make("Lưu mật khẩu mới", style: .primary)

    /// bcrypt chỉ dùng 72 byte đầu (04 §2.4).
    private let maxBytes = 72

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Đổi mật khẩu"
        view.backgroundColor = Theme.background
        setupLayout()
        render()
    }

    // MARK: - Layout

    private func setupLayout() {
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        banner.isHidden = true

        for (field, contentType) in [(currentField, UITextContentType.password),
                                     (newField, .newPassword),
                                     (confirmField, .newPassword)] {
            field.textField.textContentType = contentType
            field.textField.autocapitalizationType = .none
            field.textField.autocorrectionType = .no
            field.textField.returnKeyType = field === confirmField ? .done : .next
            field.textField.delegate = self
            field.textField.addTarget(self, action: #selector(textChanged(_:)), for: .editingChanged)
        }

        rulesStack.axis = .vertical
        rulesStack.spacing = 6

        let note = makeLabel("Sau khi đổi, các thiết bị khác đang đăng nhập tài khoản này sẽ bị đăng xuất. Máy này vẫn dùng tiếp bình thường.",
                             size: 13, color: Theme.muted)

        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let form = UIStackView(arrangedSubviews: [currentField, newField, rulesStack, confirmField])
        form.axis = .vertical
        form.spacing = 14

        let stack = UIStackView(arrangedSubviews: [banner, makeCard(form), note, saveButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20)
        ])
    }

    // MARK: - Rules

    private var currentPassword: String { currentField.textField.text ?? "" }
    private var newPassword: String { newField.textField.text ?? "" }
    private var confirmPassword: String { confirmField.textField.text ?? "" }

    private var hasMinLength: Bool { newPassword.count >= 8 }
    /// Giống server: có chữ (\p{L}) và có số (\p{Nd}).
    private var hasLetterAndDigit: Bool {
        newPassword.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            && newPassword.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }
    private var differsFromCurrent: Bool { !newPassword.isEmpty && newPassword != currentPassword }
    private var withinByteLimit: Bool { newPassword.utf8.count <= maxBytes }
    private var confirmMatches: Bool { !confirmPassword.isEmpty && confirmPassword == newPassword }

    private var canSave: Bool {
        !isSaving && !currentPassword.isEmpty && hasMinLength && hasLetterAndDigit
            && differsFromCurrent && withinByteLimit && confirmMatches
    }

    private func render() {
        rulesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var rules: [(String, Bool)] = [
            ("Ít nhất 8 ký tự", hasMinLength),
            ("Có cả chữ và số", hasLetterAndDigit),
            ("Khác mật khẩu hiện tại", differsFromCurrent)
        ]
        if !withinByteLimit { rules.append(("Tối đa \(maxBytes) byte", false)) }
        for (text, pass) in rules {
            rulesStack.addArrangedSubview(ruleRow(text, pass: pass))
        }

        if !confirmPassword.isEmpty, !confirmMatches {
            confirmField.setError("Mật khẩu nhập lại chưa khớp")
        } else {
            confirmField.setError(nil)
        }

        saveButton.isEnabled = canSave
        if var config = saveButton.configuration {
            config.title = isSaving ? "Đang lưu…" : "Lưu mật khẩu mới"
            config.showsActivityIndicator = isSaving
            saveButton.configuration = config
        }
    }

    private func ruleRow(_ text: String, pass: Bool) -> UIView {
        let mark = UILabel()
        mark.text = pass ? "✓" : "·"
        mark.font = .systemFont(ofSize: 11, weight: .bold)
        mark.textAlignment = .center
        mark.textColor = .white
        mark.backgroundColor = pass ? Theme.success : UIColor(hex: 0xCBD5E1)
        mark.layer.cornerRadius = 8
        mark.layer.masksToBounds = true
        mark.widthAnchor.constraint(equalToConstant: 16).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let label = makeLabel(text, size: 13, weight: pass ? .semibold : .regular, color: pass ? Theme.successText : Theme.slate)
        let row = UIStackView(arrangedSubviews: [mark, label])
        row.spacing = 8
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(text): \(pass ? "đạt" : "chưa đạt")"
        return row
    }

    @objc private func textChanged(_ sender: UITextField) {
        if sender === currentField.textField { currentField.setError(nil) }
        if sender === newField.textField { newField.setError(nil) }
        banner.isHidden = true
        render()
    }

    // MARK: - Save

    @objc private func saveTapped() {
        guard canSave else { return }
        view.endEditing(true)
        isSaving = true
        banner.isHidden = true
        render()

        // Server ngắt socket cũ trước khi trả token mới: báo trước để không bị coi là đăng xuất.
        RealtimeClient.shared.beginPasswordChange()
        Task {
            do {
                let response = try await authService.changePassword(current: currentPassword, new: newPassword)
                SessionManager.shared.updateToken(response.accessToken, expiresIn: response.expiresIn)
                RealtimeClient.shared.endPasswordChange(succeeded: true)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isSaving = false
                showSuccess()
            } catch {
                RealtimeClient.shared.endPasswordChange(succeeded: false)
                isSaving = false
                handle(error)
                render()
            }
        }
    }

    private func showSuccess() {
        for field in [currentField, newField, confirmField] { field.textField.text = nil }
        render()
        banner.show(title: "Đã đổi mật khẩu", message: "Các thiết bị khác đã bị đăng xuất.", style: .success)
        banner.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "Đã đổi mật khẩu. Các thiết bị khác đã bị đăng xuất.")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            navigationController?.popViewController(animated: true)
        }
    }

    private func handle(_ error: Error) {
        guard let apiError = error as? APIError, case .server(let serverError) = apiError else {
            banner.show(title: "Chưa đổi được mật khẩu", message: error.localizedDescription, style: .error)
            banner.isHidden = false
            return
        }
        switch serverError.code {
        case "WRONG_CURRENT_PASSWORD":
            currentField.setError(serverError.message)
            currentField.textField.becomeFirstResponder()
        case "WEAK_PASSWORD":
            newField.setError(serverError.message)
            newField.textField.becomeFirstResponder()
        case "VALIDATION_ERROR":
            currentField.setError(serverError.message(forField: "current_password"))
            newField.setError(serverError.message(forField: "new_password"))
        default:
            break
        }
        banner.show(title: "Chưa đổi được mật khẩu", message: serverError.message, style: .error)
        banner.isHidden = false
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

extension ChangePasswordViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        switch textField {
        case currentField.textField: newField.textField.becomeFirstResponder()
        case newField.textField: confirmField.textField.becomeFirstResponder()
        default:
            textField.resignFirstResponder()
            if canSave { saveTapped() }
        }
        return true
    }
}
