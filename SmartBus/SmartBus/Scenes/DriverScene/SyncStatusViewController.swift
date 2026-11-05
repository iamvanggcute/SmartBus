//
//  SyncStatusViewController.swift
//  SmartBus
//
//  Trạng thái đồng bộ của chuyến (05 §9.1): số thao tác chờ gửi, thao tác bị từ chối.
//

import UIKit

final class SyncStatusViewController: UITableViewController {
    private let session: TripSession
    private var rejected: [RejectedEvent] = []
    private var observer: NSObjectProtocol?

    init(session: TripSession) {
        self.session = session
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Đồng bộ"
        tableView.backgroundColor = Theme.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        observer = NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private func reload() {
        rejected = session.rejectedEvents
        tableView.reloadData()
    }

    private var stateText: String {
        switch session.syncState {
        case .idle: return session.pendingCount == 0 ? "Đã đồng bộ" : "Chờ gửi"
        case .syncing: return "Đang gửi…"
        case .offline: return "Mất kết nối mạng"
        case .retrying(let seconds): return "Thử lại sau \(seconds) giây"
        case .blocked(let message): return message
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : max(rejected.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Trạng thái" : "Thao tác bị máy chủ từ chối"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0
            ? "Thao tác được lưu trên máy trước, có mạng sẽ tự gửi. Không xóa app khi còn thao tác chờ gửi."
            : (rejected.isEmpty ? nil : "Vuốt sang trái để ẩn sau khi đã kiểm tra lại với học sinh.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        cell.accessoryType = .none

        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                content.text = "Tình trạng"
                content.secondaryText = stateText
            case 1:
                content.text = "Chờ gửi"
                content.secondaryText = "\(session.pendingCount) thao tác"
            default:
                content = UIListContentConfiguration.cell()
                content.text = "Thử gửi ngay"
                content.textProperties.color = Theme.primary
                content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
                cell.selectionStyle = .default
            }
        } else if rejected.isEmpty {
            content = UIListContentConfiguration.cell()
            content.text = "Không có"
            content.textProperties.color = Theme.muted
        } else {
            let event = rejected[indexPath.row]
            content = UIListContentConfiguration.subtitleCell()
            content.text = "\(event.title) · \(TimeFormat.time(ms: event.recordedAtMs))"
            content.secondaryText = event.message
            content.secondaryTextProperties.color = Theme.dangerText
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = Theme.danger
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath == IndexPath(row: 2, section: 0) else { return }
        if !NetworkMonitor.shared.isOnline {
            showAlert(title: "Đang mất mạng", message: "Thao tác vẫn được lưu trên máy và tự gửi khi có mạng.")
            return
        }
        session.flush()
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, !rejected.isEmpty else { return nil }
        let event = rejected[indexPath.row]
        let hide = UIContextualAction(style: .destructive, title: "Ẩn") { [weak self] _, _, done in
            self?.session.dismissRejected(event)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [hide])
    }
}
