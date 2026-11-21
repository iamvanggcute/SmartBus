//
//  AbsenceResultViewController.swift
//  SmartBus
//
//  Kết quả gửi đơn nghỉ (thiết kế P-AbsenceResult):
//  thành công → các chuyến bị đánh dấu vắng; lỗi nghiệp vụ → lý do và nút "Sửa đơn".
//

import UIKit

final class AbsenceResultViewController: UIViewController {
    struct Summary {
        let childName: String
        let date: String
        let session: AbsenceSession
        let reason: String
    }

    enum Outcome {
        case success([AffectedTrip])
        case failure(String)
    }

    private let summary: Summary
    private let outcome: Outcome

    init(summary: Summary, outcome: Outcome) {
        self.summary = summary
        self.outcome = outcome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.hidesBackButton = true

        let isSuccess: Bool
        let title: String
        let message: String
        switch outcome {
        case .success:
            isSuccess = true
            title = "Đã gửi đơn xin nghỉ"
            message = "Đơn có hiệu lực ngay. Phụ xe thấy em được đánh dấu vắng."
        case .failure(let reason):
            isSuccess = false
            title = "Chưa gửi được đơn"
            message = reason
        }

        let icon = UIImageView(image: UIImage(systemName: isSuccess ? "checkmark" : "xmark",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)))
        icon.tintColor = isSuccess ? Theme.success : Theme.danger
        icon.contentMode = .center
        icon.backgroundColor = isSuccess ? Theme.successSoft : Theme.dangerSoft
        icon.layer.cornerRadius = 36
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let iconRow = UIStackView(arrangedSubviews: [UIView(), icon, UIView()])
        iconRow.distribution = .equalCentering

        let titleLabel = makeLabel(title, size: 22, weight: .bold)
        let messageLabel = makeLabel(message, size: 15, color: isSuccess ? Theme.muted : Theme.dangerText)
        titleLabel.textAlignment = .center
        messageLabel.textAlignment = .center

        // Thông tin đơn
        let details = UIStackView()
        details.axis = .vertical
        details.spacing = 10
        for (key, value) in [("Con", summary.childName),
                             ("Ngày nghỉ", AbsenceDate.display(summary.date)),
                             ("Buổi", summary.session.title),
                             ("Lý do", summary.reason)] {
            let keyLabel = makeLabel(key, size: 14, color: Theme.muted)
            keyLabel.setContentHuggingPriority(.required, for: .horizontal)
            keyLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
            let row = UIStackView(arrangedSubviews: [keyLabel, makeLabel(value, size: 15, weight: .semibold)])
            row.spacing = 12
            row.alignment = .firstBaseline
            details.addArrangedSubview(row)
        }

        let content = UIStackView(arrangedSubviews: [iconRow, titleLabel, messageLabel, makeCard(details)])
        content.axis = .vertical
        content.spacing = 12
        content.setCustomSpacing(20, after: messageLabel)

        if case .success(let trips) = outcome, !trips.isEmpty {
            let tripsBox = UIStackView(arrangedSubviews: [makeLabel("Đã đánh dấu vắng trên các chuyến", size: 14, weight: .semibold, color: Theme.successText)])
            tripsBox.axis = .vertical
            tripsBox.spacing = 4
            for trip in trips {
                tripsBox.addArrangedSubview(makeLabel("· \(trip.direction.title), \(AbsenceDate.short(summary.date))", size: 14, color: Theme.ink))
            }
            tripsBox.isLayoutMarginsRelativeArrangement = true
            tripsBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            tripsBox.backgroundColor = Theme.successSoft
            tripsBox.layer.cornerRadius = 12
            content.addArrangedSubview(tripsBox)
        } else if case .success = outcome {
            // Chưa có chuyến nào được tạo cho ngày đó: đơn vẫn áp dụng khi nhà trường tạo chuyến.
            content.addArrangedSubview(makeLabel("Chưa có chuyến nào trong ngày này. Đơn sẽ tự áp dụng khi có chuyến.", size: 14, color: Theme.muted))
        }

        let primary = AppButton.make(isSuccess ? "Xem lịch sử đơn nghỉ" : "Sửa đơn", style: .primary)
        let secondary = AppButton.make(isSuccess ? "Về trang chính" : "Xem lịch sử đơn nghỉ", style: .secondary)
        primary.addAction(UIAction { [weak self] _ in
            isSuccess ? self?.openHistory() : self?.editForm()
        }, for: .touchUpInside)
        secondary.addAction(UIAction { [weak self] _ in
            isSuccess ? self?.goHome() : self?.openHistory()
        }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [primary, secondary])
        buttons.axis = .vertical
        buttons.spacing = 10

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        view.addSubview(scroll)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(message)")
    }

    /// Lịch sử là màn gốc của tab Đơn nghỉ.
    private func openHistory() {
        navigationController?.popToRootViewController(animated: true)
    }

    private func editForm() {
        navigationController?.popViewController(animated: true)
    }

    private func goHome() {
        navigationController?.popToRootViewController(animated: false)
        tabBarController?.selectedIndex = 0
    }
}
