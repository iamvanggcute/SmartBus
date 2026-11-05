//
//  StudentScanViewController.swift
//  SmartBus
//
//  Quét QR thẻ học sinh (US05, US06): camera liên tục, chọn Đón / Trả,
//  kết quả hiện ngay từ dữ liệu trên máy, không cần mạng.
//

import UIKit

final class StudentScanViewController: UIViewController {
    private let session: TripSession
    private var mode: ScanMode
    private var torchOn = false
    private var hideTask: Task<Void, Never>?

    private let scanner = QRScannerView()
    private let modeControl = UISegmentedControl(items: [ScanMode.board.title, ScanMode.alight.title])
    private let hintLabel = makeLabel(size: 13, weight: .medium, color: UIColor(hex: 0xCBD5E1))
    private let countLabel = makeLabel(size: 13, weight: .semibold, color: .white)
    private let frameView = UIView()
    private let resultContainer = UIView()

    init(session: TripSession) {
        self.session = session
        // Mặc định Đón; nếu mọi em đã lên và còn em trên xe thì mặc định Trả.
        let counts = session.counts
        mode = (counts.boarded > 0 && counts.expected == 0) ? .alight : .board
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x0B1220)
        setupLayout()
        scanner.onCode = { [weak self] code in self?.handle(code) }
        updateMode()
        updateCount()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scanner.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.setTorch(false)
        scanner.stop()
    }

    // MARK: - Layout

    private func setupLayout() {
        scanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        close.layer.cornerRadius = 22
        close.accessibilityLabel = "Đóng"
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let torch = UIButton(type: .system)
        torch.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        torch.tintColor = .white
        torch.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        torch.layer.cornerRadius = 22
        torch.accessibilityLabel = "Đèn pin"
        torch.addTarget(self, action: #selector(torchTapped(_:)), for: .touchUpInside)

        modeControl.selectedSegmentTintColor = Theme.schoolBus
        modeControl.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 15, weight: .semibold)], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: Theme.navy, .font: UIFont.systemFont(ofSize: 15, weight: .bold)], for: .selected)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        let topBar = UIStackView(arrangedSubviews: [close, modeControl, torch])
        topBar.spacing = 12
        topBar.alignment = .center
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        frameView.layer.borderColor = Theme.schoolBus.cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 24
        frameView.isUserInteractionEnabled = false
        frameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameView)

        hintLabel.textAlignment = .center
        countLabel.textAlignment = .center
        let info = UIStackView(arrangedSubviews: [hintLabel, countLabel])
        info.axis = .vertical
        info.spacing = 4
        info.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(info)

        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultContainer)

        var constraints: [NSLayoutConstraint] = [
            scanner.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            torch.widthAnchor.constraint(equalToConstant: 44),
            torch.heightAnchor.constraint(equalToConstant: 44),
            modeControl.heightAnchor.constraint(equalToConstant: 40),

            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -60),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor),

            info.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 16),
            info.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            info.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            resultContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            resultContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            resultContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ]

        #if DEBUG
        // Simulator không có camera: dán chuỗi qr_payload để thử.
        let manual = UIButton(type: .system)
        manual.setTitle("Nhập mã (DEBUG)", for: .normal)
        manual.tintColor = Theme.schoolBus
        manual.addTarget(self, action: #selector(manualEntry), for: .touchUpInside)
        manual.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manual)
        constraints += [
            manual.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 12),
            manual.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ]
        #endif

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - State

    private func updateMode() {
        modeControl.selectedSegmentIndex = mode == .board ? 0 : 1
        hintLabel.text = "\(mode.hint) · Đưa thẻ QR vào khung"
    }

    private func updateCount() {
        let counts = session.counts
        countLabel.text = "Trên xe \(counts.boarded) · Chưa lên \(counts.expected) · Đã xuống \(counts.alighted)"
    }

    @objc private func modeChanged() {
        mode = modeControl.selectedSegmentIndex == 0 ? .board : .alight
        updateMode()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func torchTapped(_ sender: UIButton) {
        guard scanner.hasTorch else { return }
        torchOn.toggle()
        scanner.setTorch(torchOn)
        sender.setImage(UIImage(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill"), for: .normal)
        sender.tintColor = torchOn ? Theme.schoolBus : .white
    }

    #if DEBUG
    @objc private func manualEntry() {
        let alert = UIAlertController(title: "Nhập qr_payload", message: "SB_STU|<mã HS>|<phiên bản>|<chữ ký>", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "SB_STU|…|1|…"; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Quét", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            self?.handle(text)
        })
        present(alert, animated: true)
    }
    #endif

    // MARK: - Scan handling

    private func handle(_ payload: String) {
        show(session.handleScan(payload: payload, mode: mode))
    }

    private func show(_ outcome: ScanOutcome) {
        updateCount()
        switch outcome {
        case .accepted(let item, let type):
            haptic(.success)
            let title = type == .boarded ? "Đã lên xe" : "Đã xuống xe"
            showCard(tone: .success, title: title, message: "\(item.fullName) · \(item.className ?? "")", item: item, autoHide: true)

        case .duplicate(let item):
            haptic(.warning)
            showCard(tone: .warning, title: "Vừa quét em này", message: "\(item.fullName) đã được ghi trong 15 giây trước. Không ghi lại.", item: item, autoHide: true)

        case .needsAbsentConfirmation(let item, let payload):
            haptic(.warning)
            scanner.isPaused = true
            showCard(tone: .warning, title: "Em đã được báo nghỉ",
                     message: "\(item.fullName) có đơn nghỉ hôm nay. Vẫn cho em lên xe?",
                     item: item, autoHide: false,
                     actions: [
                        ("Không", .secondary, { [weak self] in self?.resume() }),
                        ("Vẫn cho lên xe", .accent, { [weak self] in
                            guard let self else { return }
                            self.scanner.isPaused = false
                            self.show(self.session.confirmAbsentBoarding(item: item, payload: payload))
                        })
                     ])

        case .needsUnexpectedConfirmation(let code, let payload):
            haptic(.warning)
            scanner.isPaused = true
            showCard(tone: .warning, title: "Không có trong danh sách chuyến",
                     message: "Mã \(code) không thuộc chuyến này. Cho em lên xe thì giám sát viên sẽ được báo.",
                     item: nil, autoHide: false,
                     actions: [
                        ("Không", .secondary, { [weak self] in self?.resume() }),
                        ("Vẫn cho lên xe", .accent, { [weak self] in
                            guard let self else { return }
                            do {
                                try self.session.confirmUnexpectedBoarding(payload: payload)
                                self.scanner.isPaused = false
                                self.haptic(.success)
                                self.updateCount()
                                self.showCard(tone: .success, title: "Đã ghi lên xe", message: "Mã \(code) · ngoài danh sách", item: nil, autoHide: true)
                            } catch {
                                self.resume()
                                self.showCard(tone: .danger, title: "Không ghi được", message: error.localizedDescription, item: nil, autoHide: true)
                            }
                        })
                     ])

        case .wrongState(let item, let title, let message):
            haptic(.warning)
            showCard(tone: .warning, title: title, message: "\(item.fullName). \(message)", item: item, autoHide: true)

        case .notInManifest(let code):
            haptic(.error)
            showCard(tone: .danger, title: "Không có trong danh sách", message: "Mã \(code) không thuộc chuyến này.", item: nil, autoHide: true)

        case .invalidFormat:
            haptic(.error)
            showCard(tone: .danger, title: "Mã QR không hợp lệ", message: "Đây không phải thẻ học sinh SafeBus.", item: nil, autoHide: true)

        case .outdatedCard(let item):
            haptic(.error)
            showCard(tone: .danger, title: "Thẻ đã cũ", message: "Thẻ của \(item.fullName) đã được cấp lại. Dùng thẻ mới hoặc điểm danh tay.", item: item, autoHide: true)

        case .invalidSignature(let item):
            haptic(.error)
            showCard(tone: .danger, title: "Thẻ không hợp lệ", message: "Chữ ký thẻ của \(item.fullName) không khớp. Điểm danh tay nếu đúng em.", item: item, autoHide: true)

        case .tripNotActive:
            haptic(.error)
            showCard(tone: .danger, title: "Chuyến chưa bắt đầu", message: "Bắt đầu chuyến trước khi quét.", item: nil, autoHide: true)
        }
    }

    private func resume() {
        scanner.isPaused = false
        clearCard()
    }

    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: - Result card

    private enum Tone {
        case success, warning, danger

        var colors: (background: UIColor, foreground: UIColor, symbol: String) {
            switch self {
            case .success: return (Theme.successSoft, Theme.successText, "checkmark.circle.fill")
            case .warning: return (Theme.warningSoft, Theme.warningText, "exclamationmark.triangle.fill")
            case .danger: return (Theme.dangerSoft, Theme.dangerText, "xmark.octagon.fill")
            }
        }
    }

    private typealias CardAction = (String, AppButtonStyle, () -> Void)

    private func clearCard() {
        hideTask?.cancel()
        resultContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func showCard(tone: Tone, title: String, message: String, item: ManifestItem?, autoHide: Bool, actions: [CardAction] = []) {
        clearCard()
        let colors = tone.colors

        let icon = UIImageView(image: UIImage(systemName: colors.symbol))
        icon.tintColor = colors.foreground
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let titleLabel = makeLabel(title, size: 18, weight: .bold, color: colors.foreground)
        let messageLabel = makeLabel(message, size: 14, color: Theme.ink)

        let texts = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        texts.axis = .vertical
        texts.spacing = 4

        var leading: UIView = icon
        if let item {
            let avatar = AvatarView(size: 56)
            avatar.configure(name: item.fullName, photoPath: item.photoUrl)
            leading = avatar
        }
        let row = UIStackView(arrangedSubviews: [leading, texts])
        row.spacing = 12
        row.alignment = .center

        let content = UIStackView(arrangedSubviews: [row])
        content.axis = .vertical
        content.spacing = 14
        if !actions.isEmpty {
            let buttons = UIStackView()
            buttons.spacing = 10
            buttons.distribution = .fillEqually
            for (label, style, handler) in actions {
                let button = AppButton.make(label, style: style)
                button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
                buttons.addArrangedSubview(button)
            }
            content.addArrangedSubview(buttons)
        }

        let card = makeCard(content)
        card.layer.borderColor = colors.foreground.withAlphaComponent(0.35).cgColor
        card.layer.borderWidth = 1.5
        card.backgroundColor = colors.background
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isAccessibilityElement = actions.isEmpty
        card.accessibilityLabel = "\(title). \(message)"
        resultContainer.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: resultContainer.topAnchor),
            card.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor)
        ])
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")

        card.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: 24)
        UIView.animate(withDuration: 0.2) {
            card.alpha = 1
            card.transform = .identity
        }

        if autoHide {
            hideTask = Task { [weak card] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let card else { return }
                UIView.animate(withDuration: 0.2, animations: { card.alpha = 0 }) { _ in
                    card.removeFromSuperview()
                }
            }
        }
    }
}
