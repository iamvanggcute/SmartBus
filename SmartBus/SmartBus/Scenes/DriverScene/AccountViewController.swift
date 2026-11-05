//
//  AccountViewController.swift
//  SmartBus
//
//  Tài khoản phụ xe và đăng xuất (US16).
//  Không cho đăng xuất khi còn chuyến đang chạy hoặc còn điểm danh chưa đồng bộ.
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
            ("Vai trò", "Phụ xe"),
            ("Điện thoại", user.phone ?? "—"),
            ("Email", user.email ?? "—")
        ]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? infoRows.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "Cần hoàn tất chuyến và đồng bộ hết điểm danh trước khi đăng xuất." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 0 {
            var content = UIListContentConfiguration.valueCell()
            let row = infoRows[indexPath.row]
            content.text = row.0
            content.secondaryText = row.1
            cell.contentConfiguration = content
            cell.selectionStyle = .none
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
        guard indexPath.section == 1, !isLoggingOut else { return }

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

        let confirm = UIAlertController(title: "Đăng xuất?", message: "Dữ liệu chuyến lưu trên máy sẽ bị xóa.", preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Đăng xuất", style: .destructive) { [weak self] _ in
            self?.logout()
        })
        present(confirm, animated: true)
    }

    private func logout() {
        isLoggingOut = true
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
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
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
                showAlert(title: "Chưa đăng xuất được", message: error.localizedDescription)
            } catch {
                isLoggingOut = false
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
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
