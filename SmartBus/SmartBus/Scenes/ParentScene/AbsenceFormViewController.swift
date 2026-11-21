//
//  AbsenceFormViewController.swift
//  SmartBus
//
//  Xin nghỉ xe (US24, US25, thiết kế P-AbsenceAI):
//  - Gõ câu tự nhiên (≤ 500 ký tự) → "Điền bằng AI" → POST /parent/absence-requests/ai-parse.
//  - AI điền sẵn biểu mẫu; trường còn thiếu được tô cam để phụ huynh tự chọn.
//  - AI lỗi / chưa cấu hình / quá 20 lượt mỗi giờ → biểu mẫu thường, câu gốc đưa vào ô Lý do (05 §13.2).
//  - Gửi: POST /parent/absence-requests (`is_ai_extracted`, `raw_input_text`).
//

import UIKit

final class AbsenceFormViewController: UIViewController {
    private let service = ParentService()
    private var kids: [ParentChild] = []
    private var selectedChild: ParentChild?
    private var selectedSession: AbsenceSession?
    /// Biểu mẫu đang dùng kết quả AI thành công → gửi kèm `is_ai_extracted = true` và câu gốc.
    private var aiRawText: String?
    private var missingFields: Set<String> = []
    private var isWorking = false

    private let maxRawLength = 500
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let rawTextView = UITextView()
    private let rawPlaceholder = makeLabel("Ví dụ: Mai bé Phúc bị sốt nên nghỉ xe cả ngày nha cô", size: 15, color: Theme.muted)
    private let counterLabel = makeLabel("0/500 ký tự", size: 12, color: Theme.muted)
    private let aiButton = AppButton.make("Điền bằng AI", style: .dark, symbol: "sparkles")
    private let infoBanner = UIStackView()
    private let infoLabel = makeLabel(size: 14)
    private let childButton = UIButton(type: .system)
    private let datePicker = UIDatePicker()
    private let dateBox = UIView()
    private let sessionHint = makeLabel(size: 14, weight: .semibold, color: Theme.warningText)
    private var sessionButtons: [AbsenceSession: UIButton] = [:]
    private let reasonField = UITextField()
    private let submitButton = AppButton.make("Gửi đơn", style: .primary, symbol: "paperplane.fill")

    private let needBorder = UIColor(hex: 0xD97706)

    init(child: ParentChild? = nil) {
        selectedChild = child
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Xin nghỉ xe"
        view.backgroundColor = Theme.background
        setupLayout()
        render()
        Task { await loadChildren() }
    }

    // MARK: - Layout

    private func setupLayout() {
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20)
        ])

        stack.addArrangedSubview(aiCard())

        infoBanner.addArrangedSubview(infoLabel)
        infoBanner.isLayoutMarginsRelativeArrangement = true
        infoBanner.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        infoBanner.layer.cornerRadius = 12
        infoBanner.isHidden = true
        stack.addArrangedSubview(infoBanner)

        stack.addArrangedSubview(formCard())

        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        stack.addArrangedSubview(submitButton)
        let note = makeLabel("Đơn có hiệu lực ngay, phụ xe thấy em được đánh dấu nghỉ.", size: 13, color: Theme.muted)
        note.textAlignment = .center
        stack.addArrangedSubview(note)
    }

    private func aiCard() -> UIView {
        let title = makeLabel("Nhắn như bình thường, AI điền giúp", size: 15, weight: .semibold)

        rawTextView.font = .systemFont(ofSize: 15)
        rawTextView.backgroundColor = Theme.background
        rawTextView.layer.cornerRadius = 12
        rawTextView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        rawTextView.delegate = self
        rawTextView.accessibilityLabel = "Nội dung xin nghỉ"
        rawTextView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        rawPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        rawTextView.addSubview(rawPlaceholder)
        NSLayoutConstraint.activate([
            rawPlaceholder.topAnchor.constraint(equalTo: rawTextView.topAnchor, constant: 10),
            rawPlaceholder.leadingAnchor.constraint(equalTo: rawTextView.leadingAnchor, constant: 13),
            rawPlaceholder.widthAnchor.constraint(equalTo: rawTextView.widthAnchor, constant: -26)
        ])

        counterLabel.textAlignment = .right
        aiButton.addTarget(self, action: #selector(aiTapped), for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [title, rawTextView, counterLabel, aiButton])
        content.axis = .vertical
        content.spacing = 8
        content.setCustomSpacing(12, after: counterLabel)
        return makeCard(content)
    }

    private func formCard() -> UIView {
        // Con
        var childConfig = UIButton.Configuration.plain()
        childConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        childConfig.image = UIImage(systemName: "chevron.up.chevron.down")
        childConfig.imagePlacement = .trailing
        childConfig.imagePadding = 8
        childButton.configuration = childConfig
        childButton.contentHorizontalAlignment = .fill
        childButton.showsMenuAsPrimaryAction = true
        childButton.layer.cornerRadius = 12
        childButton.accessibilityLabel = "Chọn con"

        // Ngày nghỉ: từ hôm nay trở đi (05 §13.1).
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.locale = Locale(identifier: "vi_VN")
        datePicker.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        datePicker.minimumDate = Date()
        datePicker.date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        datePicker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
        let dateRow = UIStackView(arrangedSubviews: [makeLabel("Chọn ngày", size: 15, color: Theme.slate), UIView(), datePicker])
        dateRow.alignment = .center
        dateRow.translatesAutoresizingMaskIntoConstraints = false
        dateBox.layer.cornerRadius = 12
        dateBox.addSubview(dateRow)
        NSLayoutConstraint.activate([
            dateRow.topAnchor.constraint(equalTo: dateBox.topAnchor, constant: 6),
            dateRow.bottomAnchor.constraint(equalTo: dateBox.bottomAnchor, constant: -6),
            dateRow.leadingAnchor.constraint(equalTo: dateBox.leadingAnchor, constant: 12),
            dateRow.trailingAnchor.constraint(equalTo: dateBox.trailingAnchor, constant: -8)
        ])

        // Buổi nghỉ
        let sessionTitle = UIStackView(arrangedSubviews: [makeLabel("Buổi nghỉ", size: 14, weight: .semibold, color: Theme.slate), sessionHint, UIView()])
        sessionTitle.spacing = 6
        let sessions = UIStackView()
        sessions.axis = .vertical
        sessions.spacing = 8
        for session in AbsenceSession.allCases {
            var config = UIButton.Configuration.plain()
            config.title = session.title
            config.subtitle = session.subtitle
            config.titleAlignment = .leading
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            config.background.cornerRadius = 12
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                self?.selectedSession = session
                self?.missingFields.remove("session")
                self?.render()
            }, for: .touchUpInside)
            sessionButtons[session] = button
            sessions.addArrangedSubview(button)
        }

        // Lý do
        reasonField.placeholder = "Ví dụ: Bị sốt"
        reasonField.font = .systemFont(ofSize: 15)
        reasonField.borderStyle = .none
        reasonField.layer.cornerRadius = 12
        reasonField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        reasonField.leftViewMode = .always
        reasonField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        reasonField.returnKeyType = .done
        reasonField.delegate = self
        reasonField.addTarget(self, action: #selector(reasonChanged), for: .editingChanged)

        let content = UIStackView(arrangedSubviews: [
            makeLabel("Con", size: 14, weight: .semibold, color: Theme.slate), childButton,
            makeLabel("Ngày nghỉ", size: 14, weight: .semibold, color: Theme.slate), dateBox,
            sessionTitle, sessions,
            makeLabel("Lý do", size: 14, weight: .semibold, color: Theme.slate), reasonField
        ])
        content.axis = .vertical
        content.spacing = 8
        for view in [childButton, dateBox, sessions] { content.setCustomSpacing(16, after: view) }
        return makeCard(content)
    }

    // MARK: - Data

    private func loadChildren() async {
        do {
            kids = try await service.children()
            if selectedChild == nil, kids.count == 1 { selectedChild = kids.first }
            render()
        } catch {
            showAlert(title: "Không tải được danh sách con", message: error.localizedDescription)
        }
    }

    // MARK: - Render

    private func render() {
        // Con
        let childMenu = kids.map { child in
            UIAction(title: child.fullName, subtitle: child.className,
                     state: child.id == selectedChild?.id ? .on : .off) { [weak self] _ in
                self?.selectedChild = child
                self?.missingFields.remove("student_id")
                self?.render()
            }
        }
        childButton.menu = UIMenu(children: childMenu)
        if var config = childButton.configuration {
            if let child = selectedChild {
                config.title = [child.fullName, child.className].compactMap { $0 }.joined(separator: " · ")
                config.baseForegroundColor = Theme.ink
            } else {
                config.title = kids.isEmpty ? "Đang tải…" : "Chọn con"
                config.baseForegroundColor = Theme.muted
            }
            childButton.configuration = config
        }
        style(childButton, missing: missingFields.contains("student_id") || (selectedChild == nil && !missingFields.isEmpty))
        style(dateBox, missing: missingFields.contains("absence_date"))

        // Buổi
        let sessionMissing = missingFields.contains("session") && selectedSession == nil
        sessionHint.text = sessionMissing ? "· cần chọn" : nil
        for (session, button) in sessionButtons {
            guard var config = button.configuration else { continue }
            let isOn = session == selectedSession
            config.background.backgroundColor = isOn ? Theme.primarySoft : .white
            config.background.strokeColor = isOn ? Theme.primary : (sessionMissing ? needBorder : Theme.line)
            config.background.strokeWidth = isOn || sessionMissing ? 2 : 1
            config.baseForegroundColor = isOn ? Theme.primary : Theme.ink
            button.configuration = config
            button.accessibilityTraits = isOn ? [.button, .selected] : .button
        }

        style(reasonField, missing: missingFields.contains("reason") && (reasonField.text ?? "").isEmpty)

        // AI
        let raw = rawTextView.text ?? ""
        rawPlaceholder.isHidden = !raw.isEmpty
        counterLabel.text = "\(raw.count)/\(maxRawLength) ký tự"
        counterLabel.textColor = raw.count > maxRawLength ? Theme.danger : Theme.muted
        aiButton.isEnabled = !isWorking && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && raw.count <= maxRawLength
        submitButton.isEnabled = !isWorking
    }

    private func style(_ view: UIView, missing: Bool) {
        view.backgroundColor = missing ? Theme.warningSoft : Theme.background
        view.layer.borderWidth = missing ? 2 : 0
        view.layer.borderColor = needBorder.cgColor
    }

    private func showInfo(_ text: String, ai: Bool) {
        infoLabel.text = text
        infoLabel.textColor = ai ? UIColor(hex: 0x5B21B6) : Theme.warningText
        infoBanner.backgroundColor = ai ? UIColor(hex: 0xEDE9FE) : Theme.warningSoft
        infoBanner.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - AI

    @objc private func aiTapped() {
        view.endEditing(true)
        let raw = rawTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isWorking = true
        setAIButtonTitle("Đang đọc…")
        render()
        Task {
            do {
                let result = try await service.parseAbsence(rawText: raw)
                apply(result, raw: raw)
            } catch let error as APIError {
                if case .server(let serverError) = error, serverError.code == "TOO_MANY_REQUESTS" {
                    fallbackToManual(raw: raw, message: "Bạn đã dùng hết lượt điền bằng AI trong giờ này. Vui lòng tự điền biểu mẫu, câu bạn gõ được giữ ở ô Lý do.")
                } else if case .server(let serverError) = error, serverError.status == 401 {
                    // AppRouter đưa về màn đăng nhập.
                } else {
                    fallbackToManual(raw: raw, message: "Chưa dùng được AI (\(error.localizedDescription)). Vui lòng tự điền biểu mẫu.")
                }
            } catch {
                fallbackToManual(raw: raw, message: "Chưa dùng được AI. Vui lòng tự điền biểu mẫu.")
            }
            isWorking = false
            setAIButtonTitle("Điền bằng AI")
            render()
        }
    }

    private func setAIButtonTitle(_ title: String) {
        guard var config = aiButton.configuration else { return }
        config.title = title
        aiButton.configuration = config
    }

    private func apply(_ result: AbsenceAIParseResponse, raw: String) {
        guard result.aiSuccess, let extracted = result.extracted else {
            fallbackToManual(raw: raw, message: "AI chưa đọc được nội dung. Vui lòng tự điền biểu mẫu, câu bạn gõ được giữ ở ô Lý do.")
            return
        }
        aiRawText = result.rawInputText
        missingFields = Set(result.missingFields)
        if let id = extracted.studentId, let child = kids.first(where: { $0.id == id }) { selectedChild = child }
        if let api = extracted.absenceDate, let date = AbsenceDate.date(from: api) { datePicker.date = date }
        if let session = extracted.session { selectedSession = session }
        if let reason = extracted.reason { reasonField.text = reason }

        if missingFields.isEmpty {
            showInfo("AI đã điền đủ thông tin. Kiểm tra lại trước khi gửi.", ai: true)
        } else {
            let names = missingFields.compactMap { Self.fieldName[$0] }.sorted()
            showInfo("AI chưa rõ \(names.joined(separator: ", ")). Vui lòng chọn hoặc nhập thêm.", ai: true)
        }
    }

    /// 05 §13.2: AI lỗi → biểu mẫu trống, câu gốc vào ô Lý do, gửi với `is_ai_extracted = false`.
    private func fallbackToManual(raw: String, message: String) {
        aiRawText = nil
        missingFields = ["student_id", "absence_date", "session"]
        if (reasonField.text ?? "").isEmpty { reasonField.text = String(raw.prefix(1000)) }
        showInfo(message, ai: false)
    }

    private static let fieldName = [
        "student_id": "con nào nghỉ",
        "absence_date": "ngày nghỉ",
        "session": "buổi nghỉ",
        "reason": "lý do"
    ]

    @objc private func dateChanged() {
        missingFields.remove("absence_date")
        render()
    }

    @objc private func reasonChanged() {
        missingFields.remove("reason")
        render()
    }

    // MARK: - Gửi đơn

    @objc private func submitTapped() {
        view.endEditing(true)
        let reason = (reasonField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var missing: [String] = []
        if selectedChild == nil { missing.append("student_id") }
        if selectedSession == nil { missing.append("session") }
        if reason.isEmpty { missing.append("reason") }
        guard let child = selectedChild, let session = selectedSession, !reason.isEmpty else {
            missingFields.formUnion(missing)
            render()
            let names = missing.compactMap { Self.fieldName[$0] }
            showAlert(title: "Còn thiếu thông tin", message: "Vui lòng chọn hoặc nhập: \(names.joined(separator: ", ")).")
            return
        }

        let date = AbsenceDate.api(datePicker.date)
        let request = CreateAbsenceRequest(
            studentId: child.id,
            absenceDate: date,
            session: session,
            reason: String(reason.prefix(1000)),
            isAiExtracted: aiRawText != nil,
            rawInputText: aiRawText
        )
        isWorking = true
        render()
        Task {
            let summary = AbsenceResultViewController.Summary(
                childName: [child.fullName, child.className].compactMap { $0 }.joined(separator: " · "),
                date: date, session: session, reason: request.reason)
            do {
                let response = try await service.createAbsence(request)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .absenceRequestsDidChange, object: nil)
                navigationController?.pushViewController(
                    AbsenceResultViewController(summary: summary, outcome: .success(response.affectedTrips)), animated: true)
            } catch let error as APIError {
                if case .server(let serverError) = error, serverError.status == 401 { return }
                if case .server(let serverError) = error, let message = Self.errorMessage(serverError) {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    navigationController?.pushViewController(
                        AbsenceResultViewController(summary: summary, outcome: .failure(message)), animated: true)
                } else {
                    showAlert(title: "Chưa gửi được đơn", message: error.localizedDescription)
                }
            } catch {
                showAlert(title: "Chưa gửi được đơn", message: error.localizedDescription)
            }
            isWorking = false
            render()
        }
    }

    /// Lỗi nghiệp vụ hiện màn kết quả (P-AbsenceResult); lỗi khác hiện hộp thoại.
    static func errorMessage(_ error: ServerError) -> String? {
        switch error.code {
        case "DATE_IN_PAST": return "Không chọn được ngày đã qua"
        case "DUPLICATE_ABSENCE_REQUEST": return "Đã có đơn xin nghỉ trùng ngày và buổi"
        case "SESSION_ALREADY_COMPLETED": return "Chuyến của buổi này đã hoàn tất"
        case "STUDENT_ALREADY_ON_TRIP": return "Học sinh đã lên xe chuyến của buổi này"
        case "FORBIDDEN_RESOURCE": return error.message
        default: return nil
        }
    }
}

extension Notification.Name {
    /// Vừa tạo / hủy đơn nghỉ → màn lịch sử tải lại.
    static let absenceRequestsDidChange = Notification.Name("SmartBus.absenceRequestsDidChange")
}

extension AbsenceFormViewController: UITextViewDelegate, UITextFieldDelegate {
    func textViewDidChange(_ textView: UITextView) {
        render()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
