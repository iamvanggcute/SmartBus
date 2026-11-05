//
//  ManifestViewController.swift
//  SmartBus
//
//  Danh sách học sinh của chuyến (US03, US04, US08, US09):
//  bắt đầu chuyến, đếm Chưa lên / Trên xe / Đã xuống / Vắng, tìm theo tên hoặc mã,
//  điểm danh tay, thu hồi thao tác gần nhất, mở quét QR, SOS, kết thúc chuyến.
//

import UIKit

final class ManifestViewController: UIViewController {
    private let session: TripSession
    private var filtered: [ManifestItem] = []
    private var query = ""
    private var observer: NSObjectProtocol?
    private var remoteObservers: [NSObjectProtocol] = []

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = PillLabel()
    private let countsStack = UIStackView()
    private let nextStopLabel = makeLabel(size: 14, weight: .semibold, color: Theme.infoText)
    private let bottomStack = UIStackView()
    private let primaryButton = AppButton.make("Bắt đầu chuyến", style: .accent)
    private let finishButton = AppButton.make("Kết thúc chuyến", style: .secondary)

    init(session: TripSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        for remote in remoteObservers { NotificationCenter.default.removeObserver(remote) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        title = "\(session.trip.direction.title) · \(session.manifest.vehicle.licensePlate)"
        setupSearch()
        setupLayout()
        // Báo nghỉ / đổi danh sách khi đang chạy (manifest:updated).
        remoteObservers.append(NotificationCenter.default.addObserver(forName: .manifestDidChangeRemotely, object: session, queue: .main) { [weak self] note in
            let message = note.userInfo?["message"] as? String
            MainActor.assumeIsolated {
                guard let self, let message, self.presentedViewController == nil else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                self.showAlert(title: "Danh sách vừa thay đổi", message: message)
            }
        })
        remoteObservers.append(NotificationCenter.default.addObserver(forName: .tripWasReassigned, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presentedViewController?.dismiss(animated: false)
                self.showAlert(title: "Chuyến đã được giao lại",
                               message: "Giám sát viên đã giao chuyến này cho phụ xe khác.") { [weak self] in
                    self?.navigationController?.popToRootViewController(animated: true)
                }
            }
        })
        observer = NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    // MARK: - Layout

    private func setupSearch() {
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Tìm theo tên hoặc mã học sinh"
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func setupLayout() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Theme.background
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(StudentCell.self, forCellReuseIdentifier: StudentCell.reuseId)
        view.addSubview(tableView)

        bottomStack.axis = .vertical
        bottomStack.spacing = 10
        bottomStack.isLayoutMarginsRelativeArrangement = true
        bottomStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        bottomStack.backgroundColor = .white
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.addArrangedSubview(primaryButton)
        bottomStack.addArrangedSubview(finishButton)
        view.addSubview(bottomStack)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        finishButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        countsStack.axis = .horizontal
        countsStack.spacing = 6
        countsStack.distribution = .fillEqually

        statusLabel.numberOfLines = 0
        let statusRow = UIStackView(arrangedSubviews: [statusLabel, UIView()])
        let nextIcon = UIImageView(image: UIImage(systemName: "mappin.and.ellipse"))
        nextIcon.tintColor = Theme.infoText
        let nextRow = UIStackView(arrangedSubviews: [nextIcon, nextStopLabel])
        nextRow.spacing = 8
        nextRow.isLayoutMarginsRelativeArrangement = true
        nextRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        nextRow.backgroundColor = Theme.infoSoft
        nextRow.layer.cornerRadius = 12

        let header = UIStackView(arrangedSubviews: [
            makeLabel(session.manifest.route.name, size: 15, weight: .semibold),
            statusRow, countsStack, nextRow
        ])
        header.axis = .vertical
        header.spacing = 10
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        let size = header.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 0),
                                                  withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame = CGRect(origin: .zero, size: CGSize(width: view.bounds.width, height: max(size.height, 190)))
        tableView.tableHeaderView = header
    }

    // MARK: - Render

    private func render() {
        let trip = session.trip
        updateNavigationItems()
        renderStatus()
        renderCounts()

        if let next = session.nextStop, session.isActive {
            nextStopLabel.text = "Điểm tiếp theo: \(next.name)"
            nextStopLabel.superview?.isHidden = false
        } else {
            nextStopLabel.superview?.isHidden = true
        }

        switch trip.status {
        case .scheduled:
            setPrimary("Bắt đầu chuyến", style: .accent, symbol: "play.fill")
            primaryButton.isEnabled = true
            finishButton.isHidden = true
        case .active:
            setPrimary("Quét QR học sinh", style: .dark, symbol: "qrcode.viewfinder")
            primaryButton.isEnabled = true
            finishButton.isHidden = false
        case .completed, .cancelled:
            setPrimary(trip.status == .completed ? "Chuyến đã hoàn tất" : "Chuyến đã hủy", style: .dark, symbol: nil)
            primaryButton.isEnabled = false
            finishButton.isHidden = true
        }
        applyFilter()
    }

    private func setPrimary(_ title: String, style: AppButtonStyle, symbol: String?) {
        guard var config = primaryButton.configuration else { return }
        config.title = title
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        config.baseBackgroundColor = style.background
        config.baseForegroundColor = style.foreground
        primaryButton.configuration = config
        primaryButton.configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            updated.baseBackgroundColor = button.isEnabled ? style.background : Theme.disabled
            updated.baseForegroundColor = button.isEnabled ? style.foreground : Theme.slate
            button.configuration = updated
        }
    }

    private func updateNavigationItems() {
        var items: [UIBarButtonItem] = []
        if session.isActive {
            let sos = UIBarButtonItem(title: "SOS", style: .prominent, target: self, action: #selector(openSOS))
            sos.tintColor = Theme.danger
            sos.accessibilityLabel = "Báo khẩn cấp SOS"
            items.append(sos)
        }
        let pending = session.pendingCount
        let rejected = session.rejectedEvents.count
        let syncItem = UIBarButtonItem(
            image: UIImage(systemName: rejected > 0 ? "exclamationmark.icloud" : (pending > 0 ? "icloud.and.arrow.up" : "checkmark.icloud")),
            style: .plain, target: self, action: #selector(openSync)
        )
        syncItem.tintColor = rejected > 0 ? Theme.danger : (pending > 0 ? UIColor(hex: 0xB45309) : Theme.success)
        syncItem.accessibilityLabel = "Đồng bộ: \(pending) chờ gửi, \(rejected) bị từ chối"
        items.append(syncItem)
        let mapItem = UIBarButtonItem(image: UIImage(systemName: "map"), style: .plain, target: self, action: #selector(openMap))
        mapItem.accessibilityLabel = "Bản đồ và chỉ đường"
        items.append(mapItem)
        navigationItem.rightBarButtonItems = items
    }

    private func renderStatus() {
        let pending = session.pendingCount
        switch session.syncState {
        case .blocked(let message):
            statusLabel.configure(message, background: Theme.dangerSoft, foreground: Theme.dangerText)
        case .offline:
            statusLabel.configure("Mất kết nối mạng · \(pending) thao tác lưu trên máy", background: Theme.warningSoft, foreground: Theme.warningText)
        case .retrying(let seconds):
            statusLabel.configure("Chưa gửi được · thử lại sau \(seconds) giây · \(pending) chờ gửi", background: Theme.warningSoft, foreground: Theme.warningText)
        case .syncing:
            statusLabel.configure("Đang đồng bộ · \(pending) chờ gửi", background: Theme.infoSoft, foreground: Theme.infoText)
        case .idle:
            if session.trip.status == .scheduled {
                statusLabel.configure("Đã tải danh sách về máy lúc \(TimeFormat.time(ms: session.manifest.downloadedAtMs))",
                                      background: Theme.successSoft, foreground: Theme.successText)
            } else {
                statusLabel.configure("Đã đồng bộ · không có thao tác chờ gửi", background: Theme.successSoft, foreground: Theme.successText)
            }
        }
    }

    private func renderCounts() {
        countsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let counts = session.counts
        let cells: [(String, Int, UIColor)] = [
            ("Chưa lên", counts.expected, Theme.ink),
            ("Trên xe", counts.boarded, Theme.successText),
            ("Đã xuống", counts.alighted, Theme.infoText),
            ("Vắng", counts.absent, UIColor(hex: 0x6D28D9))
        ]
        for (title, value, color) in cells {
            let valueLabel = makeLabel("\(value)", size: 18, weight: .bold, color: color)
            let titleLabel = makeLabel(title, size: 11, color: Theme.slate)
            valueLabel.textAlignment = .center
            titleLabel.textAlignment = .center
            let box = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
            box.axis = .vertical
            box.spacing = 2
            box.isLayoutMarginsRelativeArrangement = true
            box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2)
            box.backgroundColor = .white
            box.layer.cornerRadius = 12
            box.isAccessibilityElement = true
            box.accessibilityLabel = "\(title): \(value)"
            countsStack.addArrangedSubview(box)
        }
    }

    private func applyFilter() {
        let all = session.items.sorted { lhs, rhs in
            let left = stopOrder(lhs), right = stopOrder(rhs)
            return left == right ? lhs.fullName < rhs.fullName : left < right
        }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = needle.isEmpty ? all : all.filter {
            $0.fullName.lowercased().contains(needle) || $0.studentCode.lowercased().contains(needle)
        }
        tableView.reloadData()
    }

    private func stopOrder(_ item: ManifestItem) -> Int {
        guard let stopId = item.stopId else { return Int.max }
        return session.manifest.route.stops.first { $0.id == stopId }?.stopOrder ?? Int.max
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch session.trip.status {
        case .scheduled: startTrip()
        case .active: openScanner()
        default: break
        }
    }

    private func startTrip() {
        primaryButton.isEnabled = false
        Task {
            do {
                try await session.startTrip()
            } catch {
                showAlert(title: "Chưa bắt đầu được chuyến", message: Self.startErrorMessage(error))
            }
            render()
        }
    }

    /// Câu thông báo lấy từ server; bổ sung hướng dẫn cho từng mã lỗi (04 §10.3).
    static func startErrorMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError, case .server(let serverError) = apiError else {
            return error.localizedDescription
        }
        switch serverError.code {
        case "TOO_EARLY_TO_START": return serverError.message
        case "ANOTHER_TRIP_ALREADY_ACTIVE": return "\(serverError.message). Hoàn tất chuyến đang chạy hoặc liên hệ giám sát viên."
        case "VEHICLE_NOT_ACTIVE": return "\(serverError.message)."
        default: return serverError.message
        }
    }

    private func openScanner() {
        let scanner = StudentScanViewController(session: session)
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    @objc private func finishTapped() {
        navigationController?.pushViewController(SafetyCheckViewController(session: session), animated: true)
    }

    @objc private func openSOS() {
        let sos = UINavigationController(rootViewController: SOSViewController(session: session))
        present(sos, animated: true)
    }

    @objc private func openMap() {
        navigationController?.pushViewController(TripMapViewController(session: session), animated: true)
    }

    @objc private func openSync() {
        navigationController?.pushViewController(SyncStatusViewController(session: session), animated: true)
    }

    private func showActions(for item: ManifestItem) {
        guard session.isActive else {
            showAlert(title: item.fullName, message: "Bắt đầu chuyến trước khi điểm danh.")
            return
        }
        let sheet = UIAlertController(title: item.fullName, message: "\(item.className ?? "") · \(item.status.title)", preferredStyle: .actionSheet)
        if let action = session.manualAction(for: item) {
            let title = action == .boarded ? "Điểm danh tay: lên xe" : "Điểm danh tay: xuống xe"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.recordManual(item, action)
            })
        }
        if session.canRevoke(item) {
            sheet.addAction(UIAlertAction(title: "Thu hồi lần ghi nhận gần nhất", style: .destructive) { [weak self] _ in
                self?.confirmRevoke(item)
            })
        }
        sheet.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(sheet, animated: true)
    }

    private func recordManual(_ item: ManifestItem, _ type: AttendanceEventType) {
        do {
            try session.recordManual(item: item, type: type)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            showAlert(title: "Không ghi được", message: error.localizedDescription)
        }
    }

    /// Hộp thoại xác nhận trước khi thu hồi (US08 AC5).
    private func confirmRevoke(_ item: ManifestItem) {
        let action = item.status == .alighted ? "xuống xe" : "lên xe"
        let alert = UIAlertController(
            title: "Thu hồi lần ghi nhận gần nhất?",
            message: "Lần \"\(action)\" của \(item.fullName) sẽ bị hủy. Phụ huynh nhận thông báo điều chỉnh. Lịch sử vẫn được lưu.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Thu hồi", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try self.session.revokeLatest(item: item) } catch {
                self.showAlert(title: "Không thu hồi được", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }
}

extension ManifestViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        applyFilter()
    }
}

extension ManifestViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: StudentCell.reuseId, for: indexPath) as! StudentCell
        let item = filtered[indexPath.row]
        cell.configure(item, stopName: session.stopName(for: item))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        showActions(for: filtered[indexPath.row])
    }
}

// MARK: - Cell

final class StudentCell: UITableViewCell {
    static let reuseId = "StudentCell"

    private let avatar = AvatarView(size: 40)
    private let nameLabel = makeLabel(size: 15, weight: .semibold)
    private let metaLabel = makeLabel(size: 12, color: Theme.muted)
    private let statusPill = PillLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        let texts = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [avatar, texts, statusPill])
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        row.backgroundColor = .white
        row.layer.cornerRadius = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ManifestItem, stopName: String?) {
        avatar.configure(name: item.fullName, photoPath: item.photoUrl)
        nameLabel.text = item.fullName
        let place = item.isUnexpected ? "ngoài danh sách" : (stopName ?? "chưa có điểm")
        metaLabel.text = [item.className, place].compactMap { $0 }.joined(separator: " · ")
        let colors = item.status.colors
        statusPill.configure(item.status.title, background: colors.background, foreground: colors.foreground)
        accessibilityLabel = "\(item.fullName), \(item.status.title)"
    }
}
