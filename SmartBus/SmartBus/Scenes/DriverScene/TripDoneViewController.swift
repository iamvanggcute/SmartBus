//
//  TripDoneViewController.swift
//  SmartBus
//
//  Màn hình sau khi hoàn tất chuyến (US15).
//

import UIKit

final class TripDoneViewController: UIViewController {
    private let session: TripSession
    private let response: CompleteTripResponse
    private let checkedAtMs: Int64

    init(session: TripSession, response: CompleteTripResponse, checkedAtMs: Int64) {
        self.session = session
        self.response = response
        self.checkedAtMs = checkedAtMs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.hidesBackButton = true

        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .bold)))
        icon.tintColor = Theme.success
        icon.contentMode = .scaleAspectFit

        let title = makeLabel("Chuyến đã hoàn tất", size: 24, weight: .bold)
        title.textAlignment = .center
        let subtitle = makeLabel("\(session.trip.direction.title) · \(session.manifest.route.name)", size: 15, color: Theme.muted)
        subtitle.textAlignment = .center

        let counts = session.counts
        let rows: [(String, String)] = [
            ("Xe", session.manifest.vehicle.licensePlate),
            ("Bắt đầu", TimeFormat.time(ms: session.trip.actualStartTimeMs)),
            ("Kết thúc", TimeFormat.time(ms: response.actualEndTimeMs ?? checkedAtMs)),
            ("Đã đón", "\(counts.boarded + counts.alighted) em"),
            ("Vắng", "\(counts.absent) em"),
            ("Ghế cuối", "Đã kiểm tra")
        ]
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 12
        for (key, value) in rows {
            let keyLabel = makeLabel(key, size: 15, color: Theme.muted)
            let valueLabel = makeLabel(value, size: 15, weight: .semibold)
            valueLabel.textAlignment = .right
            let row = UIStackView(arrangedSubviews: [keyLabel, valueLabel])
            list.addArrangedSubview(row)
        }

        let back = AppButton.make("Về danh sách chuyến", style: .primary)
        back.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popToRootViewController(animated: true)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle, makeCard(list), back])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(24, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }
}
