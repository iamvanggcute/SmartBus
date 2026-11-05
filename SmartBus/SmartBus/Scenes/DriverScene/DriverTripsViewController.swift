//
//  DriverTripsViewController.swift
//  SmartBus
//
//  Chuyến hôm nay của phụ xe (US02): GET /driver/trips.
//  Kéo để làm mới; mất mạng thì hiện danh sách tải gần nhất.
//

import UIKit

final class DriverTripsViewController: UIViewController {
    private let service = DriverService()
    private let store = DriverLocalStore.shared
    private var trips: [DriverTrip] = []
    private var isOfflineList = false
    private var cachedAtMs: Int64?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let refreshControl = UIRefreshControl()
    private let statusLabel = PillLabel()
    private let emptyLabel = makeLabel("Hôm nay bạn không có chuyến nào.", size: 15, color: Theme.muted)
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chuyến hôm nay"
        view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "person.crop.circle"), style: .plain,
            target: self, action: #selector(openAccount)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Tài khoản"
        setupTable()

        observers.append(NotificationCenter.default.addObserver(forName: .networkStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHeader() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHeader() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .tripWasReassigned, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.loadTrips() }
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        TripSessionManager.shared.resumePendingSyncs()
        Task { await loadTrips() }
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Theme.background
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(TripCell.self, forCellReuseIdentifier: TripCell.reuseId)
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let user = SessionManager.shared.currentUser
        let greeting = makeLabel(user.map { "Phụ xe · \($0.fullName)" }, size: 14, color: Theme.muted)
        let date = makeLabel(TimeFormat.today(), size: 13, color: Theme.muted)
        statusLabel.numberOfLines = 0
        let header = UIStackView(arrangedSubviews: [greeting, date, statusLabel])
        header.axis = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20)
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 80)
        tableView.tableHeaderView = header

        emptyLabel.textAlignment = .center
        tableView.backgroundView = emptyLabel
        emptyLabel.isHidden = true
        updateHeader()
    }

    @objc private func pullToRefresh() {
        Task {
            await loadTrips()
            refreshControl.endRefreshing()
        }
    }

    private func loadTrips() async {
        let dateKey = OperatingDate.today()
        do {
            trips = try await service.trips()
            isOfflineList = false
            store.saveTripList(trips, dateKey: dateKey)
        } catch let error as APIError {
            if case .network = error, let cached = store.cachedTripList(dateKey: dateKey) {
                trips = cached.trips
                cachedAtMs = cached.savedAtMs
                isOfflineList = true
            } else if case .server(let serverError) = error, serverError.status == 401 {
                return // AppRouter đưa về màn đăng nhập.
            } else {
                showAlert(title: "Không tải được danh sách chuyến", message: error.localizedDescription)
            }
        } catch {
            showAlert(title: "Không tải được danh sách chuyến", message: error.localizedDescription)
        }
        emptyLabel.isHidden = !trips.isEmpty
        tableView.reloadData()
        updateHeader()
        resumeActiveTrip()
    }

    /// Mở lại app khi chuyến đang chạy: mở phiên chuyến để tiếp tục gửi GPS và đồng bộ.
    private func resumeActiveTrip() {
        guard TripSessionManager.shared.activeSession == nil,
              let active = trips.first(where: { $0.status == .active }) else { return }
        Task { _ = try? await TripSessionManager.shared.open(tripId: active.id) }
    }

    private func updateHeader() {
        let pending = store.totalPendingCount()
        if isOfflineList || !NetworkMonitor.shared.isOnline {
            let time = TimeFormat.time(ms: cachedAtMs)
            statusLabel.configure(isOfflineList ? "Đang offline · danh sách tải lúc \(time)" : "Đang offline",
                                  background: Theme.warningSoft, foreground: Theme.warningText)
        } else if pending > 0 {
            statusLabel.configure("Đang đồng bộ · \(pending) thao tác chờ gửi", background: Theme.warningSoft, foreground: Theme.warningText)
        } else {
            statusLabel.configure("Trực tuyến · Không có thao tác chờ gửi", background: Theme.successSoft, foreground: Theme.successText)
        }
    }

    @objc private func openAccount() {
        navigationController?.pushViewController(AccountViewController(), animated: true)
    }

    private func open(_ trip: DriverTrip) {
        guard trip.status == .scheduled || trip.status == .active else {
            showAlert(title: "Chuyến \(trip.status.title.lowercased())", message: "Chỉ mở được chuyến chưa bắt đầu hoặc đang chạy.")
            return
        }
        let loading = UIAlertController(title: "Đang tải danh sách học sinh…", message: nil, preferredStyle: .alert)
        present(loading, animated: true)
        Task {
            do {
                let session = try await TripSessionManager.shared.open(tripId: trip.id)
                loading.dismiss(animated: true) {
                    self.navigationController?.pushViewController(ManifestViewController(session: session), animated: true)
                }
            } catch {
                loading.dismiss(animated: true) {
                    self.showAlert(title: "Chưa tải được danh sách chuyến",
                                   message: "\(error.localizedDescription)\nCần có danh sách trên máy trước khi bắt đầu chuyến.")
                }
            }
        }
    }
}

extension DriverTripsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { trips.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TripCell.reuseId, for: indexPath) as! TripCell
        cell.configure(trips[indexPath.section])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(trips[indexPath.section])
    }
}

// MARK: - Cell

final class TripCell: UITableViewCell {
    static let reuseId = "TripCell"

    private let directionPill = PillLabel()
    private let statusPill = PillLabel()
    private let timeLabel = makeLabel(size: 15, weight: .bold)
    private let routeLabel = makeLabel(size: 17, weight: .bold)
    private let detailLabel = makeLabel(size: 13, color: Theme.muted)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        let topRow = UIStackView(arrangedSubviews: [directionPill, statusPill, UIView(), timeLabel])
        topRow.spacing = 8
        topRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [topRow, routeLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ trip: DriverTrip) {
        let toSchool = trip.direction == .toSchool
        directionPill.configure(trip.direction.title.uppercased(),
                                background: toSchool ? Theme.schoolBus : Theme.primarySoft,
                                foreground: toSchool ? Theme.navy : Theme.primary)
        switch trip.status {
        case .active: statusPill.configure(trip.status.title, background: Theme.successSoft, foreground: Theme.successText)
        case .cancelled: statusPill.configure(trip.status.title, background: Theme.dangerSoft, foreground: Theme.dangerText)
        default: statusPill.configure(trip.status.title, background: Theme.background, foreground: Theme.slate)
        }
        timeLabel.text = "\(TimeFormat.time(ms: trip.scheduledStartTimeMs)) – \(TimeFormat.time(ms: trip.scheduledEndTimeMs))"
        routeLabel.text = trip.route.name
        let counts = trip.studentCounts
        detailLabel.text = "Xe \(trip.vehicle.licensePlate) · \(counts.total) học sinh · \(counts.absent) nghỉ"
        // Chuyến đã hoàn tất / đã hủy hiển thị mờ (US02 AC3).
        contentView.alpha = (trip.status == .completed || trip.status == .cancelled) ? 0.5 : 1
    }
}
