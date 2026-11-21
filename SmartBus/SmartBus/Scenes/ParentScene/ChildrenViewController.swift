//
//  ChildrenViewController.swift
//  SmartBus
//
//  Các con (US18, thiết kế P-Children): GET /parent/children.
//  Mỗi thẻ: lớp, tuyến, điểm đón/trả, chuyến hôm nay, trạng thái của con, nút "Theo dõi xe".
//  Tự tải lại khi có thông báo mới hoặc chuyến đổi trạng thái.
//

import UIKit

final class ChildrenViewController: UIViewController {
    private let user: AppUser
    private let service = ParentService()
    private var kids: [ParentChild] = []
    private var observers: [NSObjectProtocol] = []
    private var isLoading = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let emptyLabel = makeLabel("Chưa có học sinh nào được liên kết với tài khoản này.\nVui lòng liên hệ nhà trường.",
                                       size: 15, color: Theme.muted)

    init(user: AppUser) {
        self.user = user
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Các con"
        view.backgroundColor = Theme.background
        setupTable()

        for name in [Notification.Name.appNotificationReceived, .tripStatusDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.load() }
                }
            })
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await load() }
    }

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = Theme.background
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.register(ChildCell.self, forCellReuseIdentifier: ChildCell.reuseId)
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let hello = makeLabel("Xin chào, phụ huynh", size: 14, color: Theme.muted)
        let name = makeLabel(user.fullName, size: 22, weight: .bold)
        let header = UIStackView(arrangedSubviews: [hello, name])
        header.axis = .vertical
        header.spacing = 2
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 72)
        tableView.tableHeaderView = header

        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        tableView.backgroundView = emptyLabel
    }

    @objc private func pullToRefresh() {
        Task {
            await load()
            refreshControl.endRefreshing()
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            kids = try await service.children()
            emptyLabel.isHidden = !kids.isEmpty
            tableView.reloadData()
        } catch let error as APIError {
            if case .server(let serverError) = error, serverError.status == 401 { return }
            if kids.isEmpty {
                showAlert(title: "Không tải được danh sách", message: error.localizedDescription)
            }
        } catch {
            showAlert(title: "Không tải được danh sách", message: error.localizedDescription)
        }
    }

    fileprivate func openLive(for child: ParentChild) {
        let live = LiveTripViewController(child: child)
        navigationController?.pushViewController(live, animated: true)
    }
}

extension ChildrenViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { kids.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChildCell.reuseId, for: indexPath) as! ChildCell
        let child = kids[indexPath.row]
        cell.configure(child)
        cell.onTrack = { [weak self] in self?.openLive(for: child) }
        return cell
    }
}

// MARK: - Thẻ học sinh

final class ChildCell: UITableViewCell {
    static let reuseId = "ChildCell"
    var onTrack: (() -> Void)?

    private let avatar = AvatarView(size: 48)
    private let nameLabel = makeLabel(size: 17, weight: .bold)
    private let metaLabel = makeLabel(size: 13, color: Theme.muted)
    private let tripLabel = makeLabel(size: 11, weight: .bold, color: Theme.slate)
    private let statusPill = PillLabel()
    private let detailLabel = makeLabel(size: 14, color: Theme.ink)
    private let trackButton = AppButton.make("Theo dõi xe", style: .primary, symbol: "location.fill")

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        let names = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        names.axis = .vertical
        names.spacing = 2
        let top = UIStackView(arrangedSubviews: [avatar, names])
        top.spacing = 12
        top.alignment = .center

        let tripBox = UIStackView(arrangedSubviews: [tripLabel, UIStackView(arrangedSubviews: [statusPill, UIView()]), detailLabel])
        tripBox.axis = .vertical
        tripBox.spacing = 6
        tripBox.isLayoutMarginsRelativeArrangement = true
        tripBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        tripBox.backgroundColor = Theme.background
        tripBox.layer.cornerRadius = 12

        trackButton.addAction(UIAction { [weak self] _ in self?.onTrack?() }, for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [top, tripBox, trackButton])
        content.axis = .vertical
        content.spacing = 12
        let card = makeCard(content)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ child: ParentChild) {
        avatar.configure(name: child.fullName, photoPath: child.photoUrl)
        nameLabel.text = child.fullName

        var meta: [String] = []
        if let className = child.className { meta.append(className) }
        if let route = child.route { meta.append(route.name) }
        if let pickup = child.pickupStop { meta.append("Đón: \(pickup.name)") }
        if let dropoff = child.dropoffStop { meta.append("Trả: \(dropoff.name)") }
        metaLabel.text = meta.isEmpty ? "Chưa được xếp tuyến" : meta.joined(separator: " · ")

        let state = Self.state(for: child)
        tripLabel.text = state.trip
        statusPill.configure(state.status, background: state.colors.background, foreground: state.colors.foreground)
        detailLabel.text = state.detail

        let isLive = child.currentTrip?.tripStatus == .active
        setTrackButton(live: isLive)
        trackButton.isEnabled = child.currentTrip != nil
        accessibilityLabel = "\(child.fullName). \(state.trip). \(state.status). \(state.detail)"
    }

    private func setTrackButton(live: Bool) {
        guard var config = trackButton.configuration else { return }
        config.title = live ? "Theo dõi xe" : "Không có xe đang chạy"
        config.image = live ? UIImage(systemName: "location.fill") : nil
        let background = live ? Theme.primary : Theme.line
        let foreground = live ? UIColor.white : Theme.slate
        config.baseBackgroundColor = background
        config.baseForegroundColor = foreground
        trackButton.configuration = config
        trackButton.configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            updated.baseBackgroundColor = button.isEnabled ? background : Theme.disabled
            updated.baseForegroundColor = button.isEnabled ? foreground : Theme.slate
            button.configuration = updated
        }
    }

    struct DisplayState {
        let trip: String
        let status: String
        let colors: (background: UIColor, foreground: UIColor)
        let detail: String
    }

    static func state(for child: ParentChild) -> DisplayState {
        guard let trip = child.currentTrip else {
            return DisplayState(trip: "HÔM NAY", status: "Không có chuyến",
                                colors: (Theme.background, Theme.slate),
                                detail: "Em không có chuyến xe nào hôm nay")
        }
        let tripText = "\(trip.direction.title.uppercased()) · \(trip.tripStatus.title.uppercased())"
        let stopName = child.stop(for: trip.direction)?.name
        let start = TimeFormat.time(ms: trip.scheduledStartTimeMs)

        switch trip.studentStatus {
        case .absent:
            return DisplayState(trip: tripText, status: "Vắng", colors: trip.studentStatus.colors,
                                detail: "Đã có đơn xin nghỉ cho chuyến này")
        case .boarded:
            let detail = trip.direction == .toSchool ? "Em đang trên xe tới trường" : "Em đang trên xe về \(stopName ?? "nhà")"
            return DisplayState(trip: tripText, status: "Trên xe", colors: trip.studentStatus.colors, detail: detail)
        case .alighted:
            let detail = trip.direction == .toSchool ? "Em đã xuống xe tại trường" : "Em đã xuống xe tại \(stopName ?? "điểm trả")"
            return DisplayState(trip: tripText, status: "Đã xuống xe", colors: trip.studentStatus.colors, detail: detail)
        case .expected:
            let detail: String
            switch trip.tripStatus {
            case .scheduled:
                detail = "Xe dự kiến khởi hành \(start)" + (stopName.map { " · đón tại \($0)" } ?? "")
            case .active:
                detail = trip.direction == .toSchool
                    ? "Xe đang chạy · chờ đón tại \(stopName ?? "điểm đón")"
                    : "Xe đang chạy · chờ em lên xe tại trường"
            case .completed:
                detail = "Chuyến đã kết thúc"
            case .cancelled:
                detail = "Chuyến đã bị hủy"
            }
            return DisplayState(trip: tripText, status: "Chưa lên xe", colors: (Theme.warningSoft, Theme.warningText), detail: detail)
        }
    }
}
