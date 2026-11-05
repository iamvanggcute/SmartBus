//
//  LoginViewController.swift
//  SmartBus
//
//  Màn đăng nhập chung cho phụ xe và phụ huynh (US01, US17).
//  POST /auth/login với client = "ios". Thông báo lỗi lấy từ `error.message` của server.
//

import UIKit

final class LoginViewController: UIViewController {
    /// Gọi khi đăng nhập thành công; AppRouter dùng để mở đúng app theo vai trò.
    var onLoggedIn: ((AppUser) -> Void)?
    /// Thông báo hiện sẵn khi mở màn (ví dụ "Phiên đăng nhập đã hết hạn").
    var initialMessage: String?

    private let authService: AuthService
    private let session: SessionManager

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let banner = MessageBannerView()
    private let identifierField = FormFieldView(title: "Tên đăng nhập hoặc số điện thoại")
    private let passwordField = FormFieldView(title: "Mật khẩu", isSecure: true)
    private let loginButton = UIButton(type: .system)

    private var isLoading = false {
        didSet { updateLoginButton() }
    }
    private var lockedUntil: Date?
    private var countdownTimer: Timer?
    private var loginTask: Task<Void, Never>?

    init(authService: AuthService = AuthService(), session: SessionManager = .shared) {
        self.authService = authService
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        countdownTimer?.invalidate()
        loginTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupLayout()
        setupFields()
        updateLoginButton()

        if let initialMessage {
            banner.show(title: "Cần đăng nhập lại", message: initialMessage, style: .info)
        }
        let tap = UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 40),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            // Màn hình thấp hơn nội dung thì cuộn; cao hơn thì khung vai trò nằm sát đáy.
            contentStack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor, constant: -64)
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)

        contentStack.addArrangedSubview(makeBrandView())
        contentStack.addArrangedSubview(banner)
        contentStack.addArrangedSubview(makeFormView())
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(makeRolesView())
    }

    private func makeBrandView() -> UIView {
        let iconContainer = UIView()
        iconContainer.backgroundColor = Theme.schoolBus
        iconContainer.layer.cornerRadius = 22
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "bus.fill"))
        icon.tintColor = Theme.navy
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 76),
            iconContainer.heightAnchor.constraint(equalToConstant: 76),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38)
        ])
        iconContainer.isAccessibilityElement = false

        let title = UILabel()
        title.text = "SafeBus"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = Theme.navy
        title.accessibilityTraits = .header

        let subtitle = UILabel()
        subtitle.text = "Dành cho phụ xe và phụ huynh"
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = Theme.muted

        let stack = UIStackView(arrangedSubviews: [iconContainer, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }

    private func makeFormView() -> UIView {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = 14
        config.baseBackgroundColor = Theme.primary
        config.baseForegroundColor = .white
        config.imagePadding = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = .systemFont(ofSize: 16, weight: .semibold)
            return updated
        }
        loginButton.configuration = config
        loginButton.configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            updated.baseBackgroundColor = button.isEnabled ? Theme.primary : Theme.disabled
            updated.baseForegroundColor = button.isEnabled ? .white : Theme.slate
            button.configuration = updated
        }
        loginButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [identifierField, passwordField, loginButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(20, after: passwordField)
        return stack
    }

    private func makeRolesView() -> UIView {
        let title = UILabel()
        title.text = "App tự mở đúng giao diện theo vai trò"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.ink
        title.numberOfLines = 0

        let tiles = UIStackView(arrangedSubviews: [
            makeRoleTile(symbol: "bus", text: "Phụ xe"),
            makeRoleTile(symbol: "person.2", text: "Phụ huynh")
        ])
        tiles.axis = .horizontal
        tiles.spacing = 8
        tiles.distribution = .fillEqually

        let note = UILabel()
        note.text = "Giám sát viên đăng nhập trên Web Admin."
        note.font = .systemFont(ofSize: 12)
        note.textColor = Theme.muted
        note.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, tiles, note])
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        stack.backgroundColor = Theme.background
        stack.layer.cornerRadius = 18
        return stack
    }

    private func makeRoleTile(symbol: String, text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = Theme.primary
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.ink
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 6
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        stack.backgroundColor = .white
        stack.layer.cornerRadius = 12
        return stack
    }

    private func setupFields() {
        identifierField.textField.textContentType = .username
        identifierField.textField.keyboardType = .asciiCapable
        identifierField.textField.returnKeyType = .next
        identifierField.textField.delegate = self
        identifierField.textField.addTarget(self, action: #selector(fieldChanged(_:)), for: .editingChanged)

        passwordField.textField.textContentType = .password
        passwordField.textField.returnKeyType = .go
        passwordField.textField.delegate = self
        passwordField.textField.addTarget(self, action: #selector(fieldChanged(_:)), for: .editingChanged)
    }

    // MARK: - Actions

    @objc private func fieldChanged(_ sender: UITextField) {
        if sender === identifierField.textField { identifierField.setError(nil) }
        if sender === passwordField.textField { passwordField.setError(nil) }
    }

    @objc private func loginTapped() {
        guard !isLoading, !isLocked else { return }
        view.endEditing(true)

        let identifier = identifierField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.text

        // Cùng nội dung với kiểm tra phía server (VALIDATION_ERROR) để không phải gọi mạng.
        identifierField.setError(identifier.isEmpty ? "Bắt buộc nhập tên đăng nhập hoặc số điện thoại" : nil)
        passwordField.setError(password.isEmpty ? "Bắt buộc nhập mật khẩu" : nil)
        guard !identifier.isEmpty, !password.isEmpty else { return }

        banner.hide()
        isLoading = true
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.authService.login(identifier: identifier, password: password)
                self.session.save(response)
                self.isLoading = false
                self.passwordField.text = ""
                self.onLoggedIn?(response.user)
            } catch {
                self.isLoading = false
                self.handle(error)
            }
        }
    }

    // MARK: - Errors

    private func handle(_ error: Error) {
        guard let apiError = error as? APIError else {
            banner.show(title: "Không đăng nhập được", message: error.localizedDescription, style: .error)
            return
        }

        switch apiError {
        case .server(let serverError):
            handle(serverError)
        case .network:
            banner.show(title: "Không kết nối được máy chủ", message: "Kiểm tra mạng hoặc địa chỉ máy chủ rồi thử lại.", style: .error)
        default:
            banner.show(title: "Không đăng nhập được", message: apiError.localizedDescription, style: .error)
        }
    }

    private func handle(_ error: ServerError) {
        switch error.code {
        case "VALIDATION_ERROR":
            identifierField.setError(error.message(forField: "identifier"))
            passwordField.setError(error.message(forField: "password"))
            if error.message(forField: "identifier") == nil, error.message(forField: "password") == nil {
                banner.show(title: "Không đăng nhập được", message: error.message, style: .error)
            }
        case "TOO_MANY_REQUESTS":
            banner.show(title: "Tạm khóa đăng nhập", message: error.message, style: .error)
            startLockout(seconds: error.retryAfterSeconds ?? 60)
        case "CLIENT_ROLE_MISMATCH":
            banner.show(
                title: "Không đăng nhập được",
                message: "\(error.message). Giám sát viên vui lòng đăng nhập trên Web Admin.",
                style: .warning
            )
        default:
            // INVALID_CREDENTIALS, ACCOUNT_SUSPENDED, ACCOUNT_INACTIVE, lỗi 5xx…
            banner.show(title: "Không đăng nhập được", message: error.message, style: .error)
        }
    }

    // MARK: - Rate limit (429 + Retry-After)

    private var isLocked: Bool {
        guard let lockedUntil else { return false }
        return lockedUntil > Date()
    }

    private func startLockout(seconds: Int) {
        lockedUntil = Date().addingTimeInterval(TimeInterval(seconds))
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickLockout()
            }
        }
        updateLoginButton()
    }

    private func tickLockout() {
        if !isLocked {
            countdownTimer?.invalidate()
            countdownTimer = nil
            lockedUntil = nil
            banner.hide()
        }
        updateLoginButton()
    }

    private func updateLoginButton() {
        guard var config = loginButton.configuration else { return }
        if let lockedUntil, isLocked {
            let remaining = max(0, Int(ceil(lockedUntil.timeIntervalSinceNow)))
            config.title = String(format: "Thử lại sau %02d:%02d", remaining / 60, remaining % 60)
            config.showsActivityIndicator = false
            loginButton.isEnabled = false
        } else if isLoading {
            config.title = "Đang đăng nhập…"
            config.showsActivityIndicator = true
            loginButton.isEnabled = false
        } else {
            config.title = "Đăng nhập"
            config.showsActivityIndicator = false
            loginButton.isEnabled = true
        }
        loginButton.configuration = config
    }
}

// MARK: - UITextFieldDelegate

extension LoginViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === identifierField.textField {
            passwordField.textField.becomeFirstResponder()
        } else {
            loginTapped()
        }
        return true
    }
}
