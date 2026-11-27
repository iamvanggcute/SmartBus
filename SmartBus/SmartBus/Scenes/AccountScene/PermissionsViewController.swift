//
//  PermissionsViewController.swift
//  SmartBus
//
//  Xin quyền Vị trí và Camera cho phụ xe (thiết kế A-Permissions).
//  - Vị trí "Luôn luôn": gửi GPS cả khi khoá màn hình (US12).
//  - Camera: quét thẻ QR học sinh và QR ghế cuối (US05, US14).
//  Hiện trước khi bắt đầu chuyến nếu còn thiếu quyền, và mở được từ màn Tài khoản.
//

import UIKit
import AVFoundation
import CoreLocation

final class PermissionsViewController: UIViewController {
    enum PermissionState {
        case granted, needed, insufficient
    }

    /// Còn thiếu quyền nào cần hỏi trước khi bắt đầu chuyến.
    static var needsAttention: Bool {
        locationState != .granted || cameraState != .granted
    }

    static var locationState: PermissionState {
        switch LocationTracker.shared.authorization {
        case .authorizedAlways: return .granted
        case .notDetermined: return .needed
        default: return .insufficient // Khi dùng app, bị từ chối, bị giới hạn
        }
    }

    static var cameraState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .needed
        default: return .insufficient
        }
    }

    /// Gọi khi đóng màn hình (Tiếp tục hoặc Để sau).
    private let onFinish: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var didAskAlways = false

    private let cardsStack = UIStackView()
    private let warningBox = UIStackView()
    private let primaryButton = AppButton.make("Cho phép", style: .primary)
    private let laterButton = AppButton.make("Để sau", style: .secondary)

    init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Quyền ứng dụng"
        view.backgroundColor = Theme.background
        setupLayout()

        // Quay lại từ Cài đặt hoặc vừa trả lời hộp thoại xin quyền.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .locationAuthorizationDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locationChanged() }
        })
        render()
    }

    // MARK: - Layout

    private func setupLayout() {
        let eyebrow = makeLabel("TRƯỚC KHI BẮT ĐẦU CHUYẾN", size: 12, weight: .bold, color: Theme.primary)
        let title = makeLabel("Cho phép SafeBus dùng Vị trí và Camera", size: 22, weight: .bold)
        let subtitle = makeLabel("Cần cả hai quyền để điểm danh và để phụ huynh theo dõi xe.", size: 15, color: Theme.muted)

        cardsStack.axis = .vertical
        cardsStack.spacing = 12

        warningBox.axis = .vertical
        warningBox.spacing = 4
        warningBox.isLayoutMarginsRelativeArrangement = true
        warningBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        warningBox.backgroundColor = Theme.warningSoft
        warningBox.layer.cornerRadius = 12
        warningBox.addArrangedSubview(makeLabel("Vị trí đang ở chế độ \"Khi dùng ứng dụng\"", size: 14, weight: .bold, color: Theme.warningText))
        warningBox.addArrangedSubview(makeLabel("Khi khoá màn hình, xe sẽ ngừng gửi vị trí. Mở Cài đặt → SafeBus → Vị trí → chọn \"Luôn luôn\".",
                                                size: 13, color: Theme.warningText))

        let footnote = makeLabel("Vị trí chỉ được gửi khi chuyến đang chạy và dừng ngay khi hoàn tất.", size: 13, color: Theme.muted)
        footnote.textAlignment = .center

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        laterButton.addTarget(self, action: #selector(laterTapped), for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [eyebrow, title, subtitle, cardsStack, warningBox])
        content.axis = .vertical
        content.spacing = 8
        content.setCustomSpacing(20, after: subtitle)
        content.setCustomSpacing(16, after: cardsStack)

        let buttons = UIStackView(arrangedSubviews: [primaryButton, laterButton, footnote])
        buttons.axis = .vertical
        buttons.spacing = 10

        let scroll = UIScrollView()
        for item in [scroll, content, buttons] as [UIView] { item.translatesAutoresizingMaskIntoConstraints = false }
        scroll.addSubview(content)
        view.addSubview(scroll)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Render

    private enum Action { case request, openSettings, done }

    private var nextAction: Action {
        let location = Self.locationState, camera = Self.cameraState
        if location == .granted && camera == .granted { return .done }
        if camera == .needed || LocationTracker.shared.authorization == .notDetermined { return .request }
        // "Khi dùng ứng dụng": iOS cho hỏi nâng lên "Luôn luôn" một lần.
        if LocationTracker.shared.authorization == .authorizedWhenInUse && !didAskAlways { return .request }
        return .openSettings
    }

    private func render() {
        cardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cardsStack.addArrangedSubview(card(symbol: "location.fill", title: "Vị trí · Luôn luôn",
                                           detail: "Gửi vị trí xe mỗi 5–10 giây, kể cả khi khoá màn hình hoặc app chạy nền.",
                                           state: Self.locationState))
        cardsStack.addArrangedSubview(card(symbol: "camera.fill", title: "Camera",
                                           detail: "Quét liên tục thẻ QR học sinh và mã QR ghế cuối.",
                                           state: Self.cameraState))
        warningBox.isHidden = LocationTracker.shared.authorization != .authorizedWhenInUse

        let title: String
        switch nextAction {
        case .request: title = "Cho phép"
        case .openSettings: title = "Mở Cài đặt"
        case .done: title = onFinish == nil ? "Xong" : "Tiếp tục"
        }
        if var config = primaryButton.configuration {
            config.title = title
            primaryButton.configuration = config
        }
        laterButton.isHidden = nextAction == .done
    }

    private func card(symbol: String, title: String, detail: String, state: PermissionState) -> UIView {
        let style: (status: String, statusBg: UIColor, statusFg: UIColor, iconBg: UIColor, iconFg: UIColor) = {
            switch state {
            case .granted: return ("Đã cấp", Theme.successSoft, Theme.successText, Theme.successSoft, Theme.successText)
            case .needed: return ("Cần cấp", Theme.warningSoft, Theme.warningText, Theme.primarySoft, Theme.primary)
            case .insufficient: return ("Chưa đủ", Theme.dangerSoft, Theme.dangerText, Theme.dangerSoft, Theme.danger)
            }
        }()
        let (status, statusBg, statusFg, iconBg, iconFg) = style

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = iconFg
        icon.contentMode = .center
        icon.backgroundColor = iconBg
        icon.layer.cornerRadius = 12
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let pill = PillLabel()
        pill.configure(status, background: statusBg, foreground: statusFg)
        let titleRow = UIStackView(arrangedSubviews: [makeLabel(title, size: 16, weight: .bold), UIView(), pill])
        titleRow.alignment = .center
        let texts = UIStackView(arrangedSubviews: [titleRow, makeLabel(detail, size: 14, color: Theme.slate)])
        texts.axis = .vertical
        texts.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 12
        row.alignment = .top

        let card = makeCard(row, padding: 14)
        if state == .insufficient {
            card.layer.borderWidth = 1.5
            card.layer.borderColor = UIColor(hex: 0xFCA5A5).cgColor
        }
        card.isAccessibilityElement = true
        card.accessibilityLabel = "\(title). \(status). \(detail)"
        return card
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch nextAction {
        case .done:
            finish()
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .request:
            requestNext()
        }
    }

    /// Hỏi lần lượt: Vị trí (Khi dùng app) → Camera → nâng Vị trí lên Luôn luôn.
    private func requestNext() {
        let tracker = LocationTracker.shared
        if tracker.authorization == .notDetermined {
            tracker.requestWhenInUse()
            return // locationChanged() hỏi tiếp
        }
        if Self.cameraState == .needed {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { [weak self] in
                    self?.render()
                    self?.requestAlwaysIfNeeded()
                }
            }
            return
        }
        requestAlwaysIfNeeded()
    }

    private func requestAlwaysIfNeeded() {
        guard LocationTracker.shared.authorization == .authorizedWhenInUse, !didAskAlways else { return }
        didAskAlways = true
        LocationTracker.shared.requestAlways()
        render()
    }

    private func locationChanged() {
        render()
        // Vừa đồng ý "Khi dùng app" → hỏi tiếp Camera.
        if LocationTracker.shared.authorization != .notDetermined, Self.cameraState == .needed {
            requestNext()
        }
    }

    @objc private func laterTapped() {
        finish()
    }

    private func finish() {
        if let onFinish {
            dismiss(animated: true, completion: onFinish)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}
