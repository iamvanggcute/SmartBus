//
//  AbsenceHistoryViewController.swift
//  SmartBus
//
//  Lịch sử đơn nghỉ (US26, thiết kế P-AbsenceHistory): GET /parent/absence-requests.
//  Trạng thái Có hiệu lực / Đã hủy / Bị từ chối (kèm ghi chú nhà trường), nguồn AI hay nhập tay,
//  hủy đơn khi `can_cancel` (PATCH …/cancel). Nút "Tạo đơn" mở màn xin nghỉ.
//

import UIKit

final class AbsenceHistoryViewController: UITableViewController {
    private let service = ParentService()
    private var items: [AbsenceRequestItem] = []
    private var total = 0
    private var page = 1
    private var isLoading = false
    private var observers: [NSObjectProtocol] = []
    private let pageSize = 20
    private let emptyView = UIStackView()

    init() { super.init(style: .plain) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Đơn nghỉ"
        tableView.backgroundColor = Theme.background
        tableView.separatorStyle = .none
        tableView.register(AbsenceCell.self, forCellReuseIdentifier: AbsenceCell.reuseId)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)

        let create = UIBarButtonItem(title: "Tạo đơn", style: .prominent, target: self, action: #selector(createTapped))
        create.accessibilityLabel = "Tạo đơn xin nghỉ"
        navigationItem.rightBarButtonItem = create

        let footer = makeLabel("Chỉ hủy được khi chuyến của buổi đó chưa bắt đầu.", size: 13, color: Theme.muted)
        footer.textAlignment = .center
        footer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
        tableView.tableFooterView = footer
        setupEmptyView()

        observers.append(NotificationCenter.default.addObserver(forName: .absenceRequestsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.reload() }
            }
        })
        // Nhà trường từ chối đơn → thông báo absence_update.
        observers.append(NotificationCenter.default.addObserver(forName: .appNotificationReceived, object: nil, queue: .main) { [weak self] note in
            let type = (note.object as? AppNotification)?.type
            MainActor.assumeIsolated {
                guard let self, type == "absence_update" else { return }
                Task { await self.reload() }
            }
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await reload() }
    }

    private func setupEmptyView() {
        let icon = UIImageView(image: UIImage(systemName: "calendar.badge.checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 36)))
        icon.tintColor = Theme.slate
        let title = makeLabel("Chưa có đơn xin nghỉ", size: 17, weight: .bold)
        let body = makeLabel("Bấm “Tạo đơn” để xin nghỉ xe cho con.", size: 14, color: Theme.muted)
        title.textAlignment = .center
        body.textAlignment = .center
        for view in [icon, title, body] { emptyView.addArrangedSubview(view) }
        emptyView.axis = .vertical
        emptyView.alignment = .center
        emptyView.spacing = 8
        emptyView.isHidden = true
        let container = UIView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
            emptyView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            emptyView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40)
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

    private func reload() async {
        page = 1
        await loadPage(replace: true)
    }

    private func loadPage(replace: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.absenceRequests(page: page, limit: pageSize)
            items = replace ? result.items : items + result.items.filter { new in !items.contains { $0.id == new.id } }
            total = result.total
            tableView.reloadData()
            emptyView.isHidden = !items.isEmpty
            tableView.tableFooterView?.isHidden = items.isEmpty
        } catch let error as APIError {
            if !replace { page -= 1 }
            if case .server(let serverError) = error, serverError.status == 401 { return }
            if items.isEmpty { showAlert(title: "Không tải được đơn nghỉ", message: error.localizedDescription) }
        } catch {
            if !replace { page -= 1 }
        }
    }

    @objc private func createTapped() {
        navigationController?.pushViewController(AbsenceFormViewController(), animated: true)
    }

    // MARK: - Hủy đơn

    private func confirmCancel(_ item: AbsenceRequestItem) {
        let alert = UIAlertController(
            title: "Hủy đơn xin nghỉ?",
            message: "Đơn nghỉ \(item.session.title.lowercased()) \(AbsenceDate.short(item.absenceDate)) của \(item.studentFullName) sẽ bị hủy. Em sẽ được đưa lại danh sách đón.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Hủy đơn", style: .destructive) { [weak self] _ in
            self?.cancel(item)
        })
        present(alert, animated: true)
    }

    private func cancel(_ item: AbsenceRequestItem) {
        Task {
            do {
                _ = try await service.cancelAbsence(id: item.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await reload()
            } catch let error as APIError {
                if case .server(let serverError) = error, serverError.code == "ABSENCE_NOT_CANCELLABLE" {
                    let reason = serverError.details.first?.reason
                    let message = reason == "TRIP_ALREADY_STARTED"
                        ? "Chuyến của buổi này đã bắt đầu"
                        : "Đơn không còn hiệu lực nên không hủy được"
                    showAlert(title: "Không hủy được đơn", message: message)
                    await reload()
                } else {
                    showAlert(title: "Không hủy được đơn", message: error.localizedDescription)
                }
            } catch {
                showAlert(title: "Không hủy được đơn", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AbsenceCell.reuseId, for: indexPath) as! AbsenceCell
        let item = items[indexPath.row]
        cell.configure(item)
        cell.onCancel = { [weak self] in self?.confirmCancel(item) }
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row >= items.count - 3, !isLoading, items.count < total else { return }
        page += 1
        Task { await loadPage(replace: false) }
    }
}

// MARK: - Cell

final class AbsenceCell: UITableViewCell {
    static let reuseId = "AbsenceCell"
    var onCancel: (() -> Void)?

    private let titleLabel = makeLabel(size: 16, weight: .bold)
    private let statusPill = PillLabel()
    private let detailLabel = makeLabel(size: 14, color: Theme.slate)
    private let noteLabel = makeLabel(size: 13, color: Theme.dangerText)
    private let sourceLabel = makeLabel(size: 12, color: Theme.muted)
    private let cancelButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        let top = UIStackView(arrangedSubviews: [titleLabel, UIView(), statusPill])
        top.alignment = .center
        top.spacing = 8

        noteLabel.backgroundColor = Theme.dangerSoft
        noteLabel.layer.cornerRadius = 8
        noteLabel.layer.masksToBounds = true

        var config = UIButton.Configuration.plain()
        config.title = "Hủy đơn"
        config.baseForegroundColor = Theme.danger
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 0)
        cancelButton.configuration = config
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let bottom = UIStackView(arrangedSubviews: [sourceLabel, UIView(), cancelButton])
        bottom.alignment = .center

        let content = UIStackView(arrangedSubviews: [top, detailLabel, noteLabel, bottom])
        content.axis = .vertical
        content.spacing = 6
        let card = makeCard(content, padding: 14)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: AbsenceRequestItem) {
        titleLabel.text = "\(AbsenceDate.short(item.absenceDate)) · \(item.session.title)"
        switch item.status {
        case .active: statusPill.configure(item.status.title, background: Theme.successSoft, foreground: Theme.successText)
        case .cancelled: statusPill.configure(item.status.title, background: Theme.background, foreground: Theme.slate)
        case .rejected: statusPill.configure(item.status.title, background: Theme.dangerSoft, foreground: Theme.dangerText)
        }
        detailLabel.text = "\(item.studentFullName) · \(item.reason)"
        if let note = item.reviewNote, item.status == .rejected {
            noteLabel.text = "  Nhà trường: \(note)  "
            noteLabel.isHidden = false
        } else {
            noteLabel.isHidden = true
        }
        sourceLabel.text = item.isAiExtracted ? "✨ Tạo bằng AI" : "Nhập tay"
        cancelButton.isHidden = !item.canCancel
        contentView.alpha = item.status == .cancelled ? 0.6 : 1
        accessibilityLabel = "\(titleLabel.text ?? ""). \(item.status.title). \(detailLabel.text ?? "")"
    }
}
