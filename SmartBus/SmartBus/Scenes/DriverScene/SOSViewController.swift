//
//  SOSViewController.swift
//  SmartBus
//
//  Báo khẩn cấp (US13): chọn loại sự cố, ghi chú tùy chọn, giữ nút 2 giây để gửi
//  (tránh bấm nhầm). Mất mạng thì hiện số điện thoại nhà trường để gọi.
//

import UIKit

enum AppConstants {
    /// TODO: thay bằng số đường dây nóng thật của nhà trường.
    static let schoolHotline = "0123 456 789"
}

final class SOSViewController: UIViewController {
    private let session: TripSession
    private var category: SOSCategory = .accident
    private var isSending = false

    private let stack = UIStackView()
    private var categoryButtons: [SOSCategory: UIButton] = [:]
    private let noteView = UITextView()
    private let holdButton = UIButton(type: .custom)
    private let progressLayer = CAShapeLayer()
    private let hotlineBox = UIStackView()
    private var holdStart: Date?
    private var holdTimer: Timer?

    init(session: TripSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Báo khẩn cấp"
        view.backgroundColor = Theme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        setupLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(updateNetwork), name: .networkStatusDidChange, object: nil)
        updateNetwork()
        selectCategory(.accident)
    }

    private func setupLayout() {
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
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

        // Hộp số điện thoại khi offline.
        hotlineBox.axis = .vertical
        hotlineBox.spacing = 8
        hotlineBox.isLayoutMarginsRelativeArrangement = true
        hotlineBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        hotlineBox.backgroundColor = Theme.warningSoft
        hotlineBox.layer.cornerRadius = 14
        hotlineBox.addArrangedSubview(makeLabel("Không có mạng – không gửi được SOS", size: 15, weight: .bold, color: Theme.warningText))
        hotlineBox.addArrangedSubview(makeLabel("Gọi ngay đường dây nóng nhà trường:", size: 14, color: Theme.ink))
        let call = AppButton.make("Gọi \(AppConstants.schoolHotline)", style: .danger, symbol: "phone.fill")
        call.addAction(UIAction { _ in
            let digits = AppConstants.schoolHotline.filter(\.isNumber)
            if let url = URL(string: "tel://\(digits)") { UIApplication.shared.open(url) }
        }, for: .touchUpInside)
        hotlineBox.addArrangedSubview(call)
        stack.addArrangedSubview(hotlineBox)

        stack.addArrangedSubview(makeLabel("Loại sự cố", size: 15, weight: .semibold))
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 10
        let all = SOSCategory.allCases
        for rowIndex in stride(from: 0, to: all.count, by: 2) {
            let row = UIStackView()
            row.spacing = 10
            row.distribution = .fillEqually
            for category in all[rowIndex..<min(rowIndex + 2, all.count)] {
                let button = categoryButton(category)
                categoryButtons[category] = button
                row.addArrangedSubview(button)
            }
            grid.addArrangedSubview(row)
        }
        stack.addArrangedSubview(grid)

        stack.addArrangedSubview(makeLabel("Ghi chú (không bắt buộc)", size: 15, weight: .semibold))
        noteView.font = .systemFont(ofSize: 15)
        noteView.layer.cornerRadius = 12
        noteView.layer.borderColor = Theme.line.cgColor
        noteView.layer.borderWidth = 1
        noteView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        noteView.heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.addArrangedSubview(noteView)

        // Nút giữ 2 giây.
        holdButton.backgroundColor = Theme.danger
        holdButton.layer.cornerRadius = 70
        holdButton.setTitle("GIỮ 2 GIÂY\nĐỂ GỬI SOS", for: .normal)
        holdButton.titleLabel?.numberOfLines = 2
        holdButton.titleLabel?.textAlignment = .center
        holdButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .heavy)
        holdButton.accessibilityHint = "Giữ hai giây để gửi báo động"
        holdButton.translatesAutoresizingMaskIntoConstraints = false
        holdButton.widthAnchor.constraint(equalToConstant: 140).isActive = true
        holdButton.heightAnchor.constraint(equalToConstant: 140).isActive = true
        holdButton.addTarget(self, action: #selector(holdBegan), for: .touchDown)
        holdButton.addTarget(self, action: #selector(holdEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        progressLayer.path = UIBezierPath(arcCenter: CGPoint(x: 70, y: 70), radius: 76,
                                          startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        progressLayer.strokeColor = Theme.danger.withAlphaComponent(0.5).cgColor
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = 6
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        holdButton.layer.addSublayer(progressLayer)

        let wrap = UIView()
        wrap.addSubview(holdButton)
        NSLayoutConstraint.activate([
            holdButton.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            holdButton.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 16),
            holdButton.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8)
        ])
        stack.addArrangedSubview(wrap)
        let caption = makeLabel("Giám sát viên nhận báo động ngay kèm vị trí chuyến.", size: 13, color: Theme.muted)
        caption.textAlignment = .center
        stack.addArrangedSubview(caption)
    }

    private func categoryButton(_ category: SOSCategory) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = category.title
        config.subtitle = category.subtitle
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        config.background.cornerRadius = 14
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { [weak self] _ in self?.selectCategory(category) }, for: .touchUpInside)
        return button
    }

    private func selectCategory(_ selected: SOSCategory) {
        category = selected
        for (category, button) in categoryButtons {
            guard var config = button.configuration else { continue }
            let isOn = category == selected
            config.background.backgroundColor = isOn ? Theme.dangerSoft : .white
            config.background.strokeColor = isOn ? Theme.danger : Theme.line
            config.background.strokeWidth = isOn ? 2 : 1
            config.baseForegroundColor = isOn ? Theme.dangerText : Theme.ink
            button.configuration = config
            button.accessibilityTraits = isOn ? [.button, .selected] : .button
        }
    }

    @objc private func updateNetwork() {
        let online = NetworkMonitor.shared.isOnline
        hotlineBox.isHidden = online
        holdButton.isEnabled = online && !isSending
        holdButton.alpha = holdButton.isEnabled ? 1 : 0.45
    }

    // MARK: - Hold to send

    @objc private func holdBegan() {
        guard !isSending else { return }
        holdStart = Date()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let holdStart else { return }
        let progress = min(Date().timeIntervalSince(holdStart) / 2, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = progress
        CATransaction.commit()
        if progress >= 1 {
            stopHold()
            send()
        }
    }

    @objc private func holdEnded() {
        stopHold()
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        progressLayer.strokeEnd = 0
    }

    private func send() {
        isSending = true
        updateNetwork()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let note = noteView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await session.sendSOS(category: category, note: note.isEmpty ? nil : note)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showAlert(title: "Đã gửi SOS",
                          message: "Giám sát viên đã nhận báo động \"\(category.title)\". Giữ máy, chờ liên hệ.") { [weak self] in
                    self?.dismiss(animated: true)
                }
            } catch {
                showAlert(title: "Không gửi được SOS",
                          message: "\(error.localizedDescription)\nGọi ngay \(AppConstants.schoolHotline).")
            }
            isSending = false
            updateNetwork()
        }
    }
}
