//
//  AppRouter.swift
//  SmartBus
//
//  Chọn màn gốc theo phiên đăng nhập và vai trò:
//  - chưa đăng nhập / token hết hạn → màn Đăng nhập
//  - driver_attendant → DriverTripsViewController (app phụ xe)
//  - parent → ParentHomeViewController (tab Các con · Thông báo · Tài khoản)
//  - supervisor_admin → không cho dùng app iOS (US01 AC5)
//

import UIKit

@MainActor
final class AppRouter {
    private let window: UIWindow
    private let session: SessionManager
    private let authService: AuthService
    private var expiryObserver: NSObjectProtocol?
    private var logoutObserver: NSObjectProtocol?

    init(window: UIWindow, session: SessionManager = .shared, authService: AuthService = AuthService()) {
        self.window = window
        self.session = session
        self.authService = authService

        expiryObserver = NotificationCenter.default.addObserver(
            forName: .sessionDidExpire, object: nil, queue: .main
        ) { [weak self] note in
            let message = (note.object as? ServerError)?.message
            MainActor.assumeIsolated {
                self?.handleSessionExpired(message: message)
            }
        }
        logoutObserver = NotificationCenter.default.addObserver(
            forName: .userDidLogout, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLogout() }
        }
        NetworkMonitor.shared.start()
    }

    deinit {
        if let expiryObserver {
            NotificationCenter.default.removeObserver(expiryObserver)
        }
        if let logoutObserver {
            NotificationCenter.default.removeObserver(logoutObserver)
        }
    }

    func start() {
        guard session.hasValidSession, let user = session.currentUser else {
            // Token hết hạn: về màn đăng nhập, không xóa hàng đợi offline (US01 AC4).
            let expired = session.accessToken != nil
            session.clear()
            showLogin(message: expired ? "Phiên đăng nhập đã hết hạn" : nil, animated: false)
            return
        }
        showHome(for: user, animated: false)
        refreshCurrentUser()
    }

    func showLogin(message: String? = nil, animated: Bool = true) {
        let login = LoginViewController()
        login.initialMessage = message
        login.onLoggedIn = { [weak self] user in
            self?.showHome(for: user, animated: true)
        }
        setRoot(login, animated: animated)
    }

    func showHome(for user: AppUser, animated: Bool = true) {
        switch user.role {
        case .driverAttendant:
            setRoot(UINavigationController(rootViewController: DriverTripsViewController()), animated: animated)
            DriverTracking.shared.activate()
        case .parent:
            setRoot(ParentHomeViewController(user: user), animated: animated)
            RealtimeClient.shared.connect()
        case .supervisorAdmin:
            session.clear()
            showLogin(message: "Tài khoản giám sát viên đăng nhập trên Web Admin.", animated: animated)
        }
    }

    /// Đăng xuất phía app (gọi sau khi `AuthService.logout` thành công).
    func didLogout() {
        DriverTracking.shared.deactivate()
        RealtimeClient.shared.disconnect()
        session.clear()
        showLogin()
    }

    // MARK: - Private

    /// Lấy thông tin mới nhất khi mở app. Mất mạng thì vẫn dùng phiên đã lưu
    /// (phụ xe cần làm việc offline); 401 đã được APIClient chuyển thành sự kiện hết phiên.
    private func refreshCurrentUser() {
        Task { [authService, session] in
            if let user = try? await authService.me() {
                session.update(user: user)
            }
        }
    }

    private func handleSessionExpired(message: String?) {
        guard !(window.rootViewController is LoginViewController) else { return }
        DriverTracking.shared.deactivate()
        RealtimeClient.shared.disconnect()
        session.clear()
        showLogin(message: message ?? "Phiên đăng nhập đã hết hạn")
    }

    private func setRoot(_ viewController: UIViewController, animated: Bool) {
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        guard animated else { return }
        UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve, animations: nil)
    }
}
