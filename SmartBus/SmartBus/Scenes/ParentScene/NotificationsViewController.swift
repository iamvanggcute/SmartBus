//
//  NotificationsViewController.swift
//  SmartBus
//
//  Thông báo (US21–US23, thiết kế P-Notifications): GET /notifications, PATCH /notifications/read.
//  Tab Tất cả / Chưa đọc, "Đọc tất cả (n)", tải thêm khi cuộn, nhận ngay `notification:new`.
//  Bấm thông báo của chuyến → mở Theo dõi xe.
//

import UIKit

final class NotificationsViewController: UITableViewController {
    private let service = ParentService()
    private var items: [AppNotification] = []
    private var unreadCount = 0
    private var total = 0
    private var page = 1
    private var isLoading = false
    private var unreadOnly = false
    private var observers: [NSObjectProtocol] = []
    private let pageSize = 20

    private let filter = UISegmentedControl(items: ["Tất cả", "Chưa đọc"])
    private let emptyView = UIStackView()

    init() { super.init(style: .plain) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Thông báo"
        tableView.backgroundColor = Theme.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        tableView.register(NotificationCell.self, forCellReuseIdentifier: NotificationCell.reuseId)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)

        filter.selectedSegmentIndex = 0
        filter.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 52))
        filter.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(filter)
        NSLayoutConstraint.activate([
            filter.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            filter.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            filter.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        tableView.tableHeaderView = header

        setupEmptyView()
        updateReadAllButton()

        observers.append(NotificationCenter.default.addObserver(forName: .appNotificationReceived, object: nil, queue: .main) { [weak self] note in
            guard let notification = note.object as? AppNotification else { return }
            MainActor.assumeIsolated { self?.insert(notification) }
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await reload() }
    }

    private func setupEmptyView() {
        let icon = UIImageView(image: UIImage(systemName: "bell.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 36)))
        icon.tintColor = Theme.slate
        let title = makeLabel("Chưa có thông báo", size: 17, weight: .bold)
        let body = makeLabel("Khi con lên xe, xuống xe hoặc xe sắp đến, thông báo sẽ hiện ở đây.", size: 14, color: Theme.muted)
        title.textAlignment = .center
        body.textAlignment = .center
        for view in [icon, title, body] { emptyView.addArrangedSubview(view) }
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 8
        emptyView.isLayoutMarginsRelativeArrangement = true
        emptyView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 40, bottom: 80, trailing: 40)
        emptyView.isHidden = true
        let container = UIView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        tableView.backgroundView = container
    }

    // MARK: - Data

    @objc private func pullToRefresh() {
        Task {
            await reload()
            refreshControl?.endRefreshing()
        }
    }

    @objc private func filterChanged() {
        unreadOnly = filter.selectedSegmentIndex == 1
        Task { await reload() }
    }

    private func reload() async {
        page = 1
        await loadPage(replace: true)
    }

    private func loadMoreIfNeeded() {
        guard !isLoading, items.count < total else { return }
        page += 1
        Task { await loadPage(replace: false) }
    }

    private func loadPage(replace: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.notifications(unreadOnly: unreadOnly, page: page, limit: pageSize)
            items = replace ? result.items : items + result.items.filter { new in !items.contains { $0.id == new.id } }
            total = result.total
            setUnread(result.unreadCount)
            tableView.reloadData()
            emptyView.isHidden = !items.isEmpty
        } catch let error as APIError {
            if case .server(let serverError) = error, serverError.status == 401 { return }
            if !replace { page -= 1 }
            if items.isEmpty { showAlert(title: "Không tải được thông báo", message: error.localizedDescription) }
        } catch {
            if !replace { page -= 1 }
        }
    }

    /// `notification:new`: chèn lên đầu ngay, không cần gọi lại API.
    private func insert(_ notification: AppNotification) {
        guard !items.contains(where: { $0.id == notification.id }) else { return }
        items.insert(notification, at: 0)
        total += 1
        setUnread(unreadCount + 1)
        emptyView.isHidden = true
        if isViewLoaded, view.window != nil {
            tableView.insertRows(at: [IndexPath(row: 0, section: 0)], with: .top)
        } else {
            tableView.reloadData()
        }
    }

    private func setUnread(_ count: Int) {
        unreadCount = max(0, count)
        updateReadAllButton()
        (tabBarController as? ParentHomeViewController)?.setUnreadCount(unreadCount)
    }

    private func updateReadAllButton() {
        if unreadCount > 0 {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Đọc tất cả (\(unreadCount))", style: .plain,
                                                                target: self, action: #selector(markAllRead))
        } else {
            navigationItem.rightBarButtonItem = nil
        }
    }

    @objc private func markAllRead() {
        Task {
            do {
                try await service.markAllRead()
                if unreadOnly {
                    items.removeAll()
                    total = 0
                } else {
                    for index in items.indices { items[index].isRead = true }
                }
                setUnread(0)
                tableView.reloadData()
                emptyView.isHidden = !items.isEmpty
            } catch {
                showAlert(title: "Chưa đánh dấu được", message: error.localizedDescription)
            }
        }
    }

    private func markRead(at indexPath: IndexPath) {
        let notification = items[indexPath.row]
        guard !notification.isRead else { return }
        items[indexPath.row].isRead = true
        setUnread(unreadCount - 1)
        tableView.reloadRows(at: [indexPath], with: .none)
        Task {
            // Lỗi mạng: lần mở sau server vẫn trả "chưa đọc", không mất gì.
            _ = try? await service.markRead(ids: [notification.id])
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: NotificationCell.reuseId, for: indexPath) as! NotificationCell
        cell.configure(items[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= items.count - 3 { loadMoreIfNeeded() }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let notification = items[indexPath.row]
        markRead(at: indexPath)
        // Thông báo chuyến đang chạy (lên xe, xe sắp đến…) → mở Theo dõi xe.
        guard let tripId = notification.tripId, let studentId = notification.studentId,
              ["attendance", "attendance_correction", "proximity", "trip_completed"].contains(notification.type) else { return }
        let live = LiveTripViewController(tripId: tripId, studentId: studentId, childName: "con")
        navigationController?.pushViewController(live, animated: true)
    }
}

// MARK: - Cell

final class NotificationCell: UITableViewCell {
    static let reuseId = "NotificationCell"

    private let glyph = UILabel()
    private let titleLabel = makeLabel(size: 15, weight: .semibold)
    private let timeLabel = makeLabel(size: 12, color: Theme.muted)
    private let bodyLabel = makeLabel(size: 14, color: Theme.slate)
    private let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        glyph.font = .systemFont(ofSize: 16, weight: .bold)
        glyph.textAlignment = .center
        glyph.layer.cornerRadius = 18
        glyph.layer.masksToBounds = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 36).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 36).isActive = true

        unreadDot.backgroundColor = Theme.primary
        unreadDot.layer.cornerRadius = 4
        unreadDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        unreadDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, timeLabel, unreadDot])
        titleRow.spacing = 8
        titleRow.alignment = .center
        let texts = UIStackView(arrangedSubviews: [titleRow, bodyLabel])
        texts.axis = .vertical
        texts.spacing = 4
        let row = UIStackView(arrangedSubviews: [glyph, texts])
        row.spacing = 12
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ notification: AppNotification) {
        let style = Self.style(for: notification.type)
        glyph.text = style.glyph
        glyph.backgroundColor = style.background
        glyph.textColor = style.foreground
        titleLabel.text = notification.title
        timeLabel.text = ParentFormat.relative(ms: notification.createdAtMs)
        bodyLabel.text = notification.body
        unreadDot.isHidden = notification.isRead
        backgroundColor = notification.isRead ? .white : Theme.primarySoft.withAlphaComponent(0.45)
        titleLabel.font = .systemFont(ofSize: 15, weight: notification.isRead ? .medium : .bold)
        accessibilityLabel = "\(notification.isRead ? "" : "Chưa đọc. ")\(notification.title). \(notification.body). \(timeLabel.text ?? "")"
    }

    /// Ký hiệu và màu theo loại (thiết kế P-Notifications).
    static func style(for type: String) -> (glyph: String, background: UIColor, foreground: UIColor) {
        switch type {
        case "attendance", "trip_completed": return ("✓", Theme.successSoft, Theme.successText)
        case "proximity": return ("➜", Theme.primarySoft, Theme.primary)
        case "attendance_correction": return ("↺", Theme.warningSoft, Theme.warningText)
        case "absence_update", "safety_alert": return ("!", Theme.dangerSoft, Theme.dangerText)
        default: return ("•", Theme.background, Theme.slate)
        }
    }
}
