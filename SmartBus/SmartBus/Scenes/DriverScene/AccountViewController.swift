//
//  AccountViewController.swift
//  SmartBus
//
//  Tài khoản (thiết kế A-Account), dùng chung cho phụ xe và phụ huynh:
//  thông tin, đổi mật khẩu (US43), quyền Camera/Vị trí (phụ xe), đăng xuất (US16, US27).
//  Phụ xe: không cho đăng xuất khi còn chuyến đang chạy hoặc còn điểm danh chưa đồng bộ.
//

import UIKit

extension Notification.Name {
    static let userDidLogout = Notification.Name("SmartBus.userDidLogout")
}

final class AccountViewController: UITableViewController {
    private let authService = AuthService()
    private var isLoggingOut = false

    init() { super.init(style: .insetGrouped) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tài khoản"
        tableView.backgroundColor = Theme.background
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    private var infoRows: [(String, String)] {
        guard let user = SessionManager.shared.currentUser else { return [] }
        return [
            ("Họ tên", user.fullName),
            ("Tên đăng nhập", user.username),
            ("Vai trò", user.role == .parent ? "Phụ huynh" : "Phụ xe"),
            ("Điện thoại", user.phone ?? "—"),
            ("Email", user.email ?? "—")
        ]
    }

    private enum Section: Int, CaseIterable { case info, actions, logout }

    private var isDriver: Bool { SessionManager.shared.currentUser?.role == .driverAttendant }

    /// Đổi mật khẩu; phụ xe có thêm Quyền Camera & Vị trí.
    private var actionRows: [(title: String, symbol: String)] {
        var rows: [(title: String, symbol: String)] = [("Đổi mật khẩu", "key.fill")]
        if isDriver { rows.append(("Quyền Camera & Vị trí", "location.viewfinder")) }
        return rows
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData() // trạng thái quyền có thể vừa đổi
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .info: return infoRows.count
        case .actions: return actionRows.count
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == Section.logout.rawValue, isDriver else { return nil }
        return "Cần hoàn tất chuyến và đồng bộ hết điểm danh trước khi đăng xuất."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        if indexPath.section == Section.info.rawValue {
            var content = UIListContentConfiguration.valueCell()
            let row = infoRows[indexPath.row]
            content.text = row.0
            content.secondaryText = row.1
            cell.contentConfiguration = content
            cell.selectionStyle = .none
        } else if indexPath.section == Section.actions.rawValue {
            let row = actionRows[indexPath.row]
            var content = UIListContentConfiguration.valueCell()
            content.text = row.title
            content.image = UIImage(systemName: row.symbol)
            content.imageProperties.tintColor = Theme.primary
            if indexPath.row == 1 {
                content.secondaryText = PermissionsViewController.needsAttention ? "Chưa đủ" : "Đã cấp"
                content.secondaryTextProperties.color = PermissionsViewController.needsAttention ? Theme.dangerText : Theme.successText
            }
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        } else {
            var content = UIListContentConfiguration.cell()
            content.text = isLoggingOut ? "Đang đăng xuất…" : "Đăng xuất"
            content.textProperties.color = Theme.danger
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == Section.actions.rawValue {
            let next: UIViewController = indexPath.row == 0 ? ChangePasswordViewController() : PermissionsViewController()
            navigationController?.pushViewController(next, animated: true)
            return
        }
        guard indexPath.section == Section.logout.rawValue, !isLoggingOut else { return }

        let manager = TripSessionManager.shared
        // Chuyến có thể đã được hoàn tất ở nơi khác: hỏi lại server rồi mới kiểm tra.
        if manager.hasActiveTrip, NetworkMonitor.shared.isOnline {
            Task {
                await manager.refreshActiveSessions()
                self.checkAndConfirmLogout()
            }
            return
        }
        checkAndConfirmLogout()
    }

    private func checkAndConfirmLogout() {
        let manager = TripSessionManager.shared
        // Kiểm tra trên máy trước, dùng đúng câu của server (US16 AC2, AC3).
        if manager.hasActiveTrip {
            showAlert(title: "Chưa đăng xuất được", message: "Không thể đăng xuất khi đang có chuyến xe chưa hoàn tất")
            return
        }
        if manager.hasPendingOutbox {
            showAlert(title: "Chưa đăng xuất được", message: "Còn dữ liệu điểm danh chưa đồng bộ, vui lòng đồng bộ trước khi đăng xuất")
            return
        }

        let confirm = UIAlertController(title: "Đăng xuất?", message: isDriver ? "Dữ liệu chuyến lưu trên máy sẽ bị xóa." : nil, preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Đăng xuất", style: .destructive) { [weak self] _ in
            self?.logout()
        })
        present(confirm, animated: true)
    }

    private func logout() {
        isLoggingOut = true
        tableView.reloadSections(IndexSet(integer: Section.logout.rawValue), with: .none)
        Task {
            do {
                _ = try await authService.logout(hasPendingOfflineEvents: TripSessionManager.shared.hasPendingOutbox)
                finishLogout()
            } catch let error as APIError {
                if case .server(let serverError) = error, serverError.status == 401 {
                    finishLogout() // Phiên đã hết hạn: coi như đã đăng xuất.
                    return
                }
                isLoggingOut = false
                tableView.reloadSections(IndexSet(integer: Section.logout.rawValue), with: .none)
                showAlert(title: "Chưa đăng xuất được", message: error.localizedDescription)
            } catch {
                isLoggingOut = false
                tableView.reloadSections(IndexSet(integer: Section.logout.rawValue), with: .none)
                showAlert(title: "Chưa đăng xuất được", message: error.localizedDescription)
            }
        }
    }

    private func finishLogout() {
        DriverLocalStore.shared.clearAllTripData()
        TripSessionManager.shared.reset()
        NotificationCenter.default.post(name: .userDidLogout, object: nil)
    }
}
