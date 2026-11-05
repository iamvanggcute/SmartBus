//
//  SafetyCheckViewController.swift
//  SmartBus
//
//  Kiểm tra ghế cuối và hoàn tất chuyến (US14, US15).
//  Điều kiện: có mạng, đã đồng bộ hết, không còn em trên xe. Quét QR dán ở ghế cuối,
//  server xác nhận "passed" thì mới cho hoàn tất.
//

import UIKit

final class SafetyCheckViewController: UIViewController {
    private let session: TripSession
    private var result: SafetyCheckResponse?
    private var observer: NSObjectProtocol?
    private var isWorking = false

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let completeButton = AppButton.make("Hoàn tất chuyến", style: .primary, symbol: "checkmark.seal.fill")

    init(session: TripSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Kiểm tra ghế cuối"
        view.backgroundColor = Theme.background
        setupLayout()
        observer = NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(networkChanged), name: .networkStatusDidChange, object: nil)
        render()
    }

    @objc private func networkChanged() { render() }

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let bottom = UIView()
        bottom.backgroundColor = .white
        bottom.translatesAutoresizingMaskIntoConstraints = false
        completeButton.translatesAutoresizingMaskIntoConstraints = false
        completeButton.addTarget(self, action: #selector(completeTapped), for: .touchUpInside)
        bottom.addSubview(completeButton)
        view.addSubview(bottom)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            completeButton.topAnchor.constraint(equalTo: bottom.topAnchor, constant: 12),
            completeButton.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 20),
            completeButton.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -20),
            completeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Render

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let intro = makeLabel("Đi xuống cuối xe, kiểm tra không còn em nào ở lại, rồi quét mã QR dán ở ghế cuối.",
                              size: 15, color: Theme.muted)
        stack.addArrangedSubview(intro)

        if let result {
            stack.addArrangedSubview(resultCard(result))
        }

        if result?.passed != true {
            stack.addArrangedSubview(preconditionCard())
        }
        completeButton.isEnabled = result?.passed == true && !isWorking
    }

    private func preconditionCard() -> UIView {
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12

        switch session.safetyPrecondition {
        case .offline:
            content.addArrangedSubview(statusRow(symbol: "wifi.slash", color: Theme.warningText,
                                                 title: "Cần có mạng",
                                                 message: "Kiểm tra ghế cuối phải gửi lên máy chủ ngay. Chờ có mạng rồi thử lại."))
        case .needsSync(let pending):
            content.addArrangedSubview(statusRow(symbol: "icloud.and.arrow.up", color: Theme.warningText,
                                                 title: "Còn \(pending) thao tác chưa đồng bộ",
                                                 message: "Đồng bộ hết điểm danh trước khi kiểm tra ghế cuối."))
            let syncButton = AppButton.make("Đồng bộ ngay", style: .secondary, symbol: "arrow.triangle.2.circlepath")
            syncButton.addAction(UIAction { [weak self] _ in self?.session.flush() }, for: .touchUpInside)
            if session.syncState == .syncing { syncButton.isEnabled = false }
            content.addArrangedSubview(syncButton)
        case .studentsOnBoard(let items):
            content.addArrangedSubview(statusRow(symbol: "person.2.fill", color: Theme.dangerText,
                                                 title: "Còn \(items.count) em trên xe",
                                                 message: "Ghi xuống xe cho các em trước khi kiểm tra ghế cuối."))
            for item in items {
                let label = makeLabel("• \(item.fullName)\(item.className.map { " · \($0)" } ?? "")", size: 14)
                content.addArrangedSubview(label)
            }
        case .ready:
            content.addArrangedSubview(statusRow(symbol: "checkmark.circle.fill", color: Theme.successText,
                                                 title: "Sẵn sàng kiểm tra",
                                                 message: "Đã đồng bộ hết và không còn em nào trên xe."))
            let scanButton = AppButton.make(isWorking ? "Đang gửi…" : "Quét QR ghế cuối", style: .dark, symbol: "qrcode.viewfinder")
            scanButton.isEnabled = !isWorking
            scanButton.addTarget(self, action: #selector(scanRear), for: .touchUpInside)
            content.addArrangedSubview(scanButton)
        }
        return makeCard(content)
    }

    private func resultCard(_ response: SafetyCheckResponse) -> UIView {
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 10
        if response.passed {
            content.addArrangedSubview(statusRow(symbol: "checkmark.seal.fill", color: Theme.successText,
                                                 title: "Đã kiểm tra ghế cuối", message: response.message))
        } else {
            content.addArrangedSubview(statusRow(symbol: "exclamationmark.octagon.fill", color: Theme.dangerText,
                                                 title: "Chưa đạt", message: response.message))
            for student in response.boardedStudents ?? [] {
                content.addArrangedSubview(makeLabel("• \(student.fullName)", size: 14))
            }
        }
        return makeCard(content)
    }

    private func statusRow(symbol: String, color: UIColor, title: String, message: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = color
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.contentMode = .scaleAspectFit
        let texts = UIStackView(arrangedSubviews: [
            makeLabel(title, size: 16, weight: .bold, color: color),
            makeLabel(message, size: 14, color: Theme.ink)
        ])
        texts.axis = .vertical
        texts.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 12
        row.alignment = .top
        return row
    }

    // MARK: - Actions

    @objc private func scanRear() {
        let capture = RearQRCaptureViewController { [weak self] payload in
            self?.submit(payload)
        }
        capture.modalPresentationStyle = .fullScreen
        present(capture, animated: true)
    }

    private func submit(_ payload: String) {
        isWorking = true
        render()
        Task {
            do {
                result = try await session.safetyCheck(rearQrPayload: payload)
                UINotificationFeedbackGenerator().notificationOccurred(result?.passed == true ? .success : .error)
            } catch {
                showAlert(title: "Chưa kiểm tra được ghế cuối", message: error.localizedDescription)
            }
            isWorking = false
            render()
        }
    }

    @objc private func completeTapped() {
        isWorking = true
        render()
        Task {
            do {
                let response = try await session.complete()
                let done = TripDoneViewController(session: session, response: response, checkedAtMs: Date().milliseconds)
                navigationController?.pushViewController(done, animated: true)
            } catch {
                // TRIP_COMPLETION_LOCKED: chưa có kiểm tra ghế cuối đạt (server trả câu thông báo).
                showAlert(title: "Chưa hoàn tất được chuyến", message: error.localizedDescription)
            }
            isWorking = false
            render()
        }
    }
}

// MARK: - Quét QR ghế cuối

final class RearQRCaptureViewController: UIViewController {
    private let onCode: (String) -> Void
    private let scanner = QRScannerView()

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0x0B1220)
        scanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner)

        let title = makeLabel("Quét mã QR ở ghế cuối xe", size: 17, weight: .bold, color: .white)
        title.textAlignment = .center
        let frame = UIView()
        frame.layer.borderColor = Theme.schoolBus.cgColor
        frame.layer.borderWidth = 3
        frame.layer.cornerRadius = 24
        frame.isUserInteractionEnabled = false

        let cancel = AppButton.make("Hủy", style: .secondary)
        cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        for item in [title, frame, cancel] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        var constraints: [NSLayoutConstraint] = [
            scanner.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            frame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frame.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            frame.heightAnchor.constraint(equalTo: frame.widthAnchor),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ]

        #if DEBUG
        let manual = UIButton(type: .system)
        manual.setTitle("Nhập mã (DEBUG)", for: .normal)
        manual.tintColor = Theme.schoolBus
        manual.addAction(UIAction { [weak self] _ in self?.manualEntry() }, for: .touchUpInside)
        manual.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manual)
        constraints += [
            manual.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),
            manual.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ]
        #endif
        NSLayoutConstraint.activate(constraints)

        scanner.onCode = { [weak self] code in self?.finish(code) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scanner.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stop()
    }

    private func finish(_ code: String) {
        scanner.isPaused = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss(animated: true) { [onCode] in onCode(code) }
    }

    #if DEBUG
    private func manualEntry() {
        let alert = UIAlertController(title: "Nhập rear_qr_payload", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Gửi", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            self?.finish(text)
        })
        present(alert, animated: true)
    }
    #endif
}
