//
//  ParentHomeViewController.swift
//  SmartBus
//
//  Khung app phụ huynh: tab Các con · Thông báo · Đơn nghỉ · Tài khoản (theo thiết kế P-Children).
//  Giữ số thông báo chưa đọc trên badge, cập nhật khi có `notification:new`.
//

import UIKit

final class ParentHomeViewController: UITabBarController {
    private let user: AppUser
    private let service = ParentService()
    private var observers: [NSObjectProtocol] = []
    private var notificationsNav: UINavigationController?

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
        tabBar.tintColor = Theme.primary

        let childrenNav = UINavigationController(rootViewController: ChildrenViewController(user: user))
        childrenNav.tabBarItem = UITabBarItem(title: "Các con", image: UIImage(systemName: "person.2"), selectedImage: UIImage(systemName: "person.2.fill"))

        let notifications = UINavigationController(rootViewController: NotificationsViewController())
        notifications.tabBarItem = UITabBarItem(title: "Thông báo", image: UIImage(systemName: "bell"), selectedImage: UIImage(systemName: "bell.fill"))
        notificationsNav = notifications

        let absences = UINavigationController(rootViewController: AbsenceHistoryViewController())
        absences.tabBarItem = UITabBarItem(title: "Đơn nghỉ", image: UIImage(systemName: "calendar"), selectedImage: UIImage(systemName: "calendar.circle.fill"))

        let account = UINavigationController(rootViewController: AccountViewController())
        account.tabBarItem = UITabBarItem(title: "Tài khoản", image: UIImage(systemName: "person.crop.circle"), selectedImage: UIImage(systemName: "person.crop.circle.fill"))

        viewControllers = [childrenNav, notifications, absences, account]

        observers.append(NotificationCenter.default.addObserver(forName: .appNotificationReceived, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUnreadCount() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .realtimeStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            // Kết nối lại sau khi mất mạng: có thể đã lỡ thông báo, lấy lại số chưa đọc.
            MainActor.assumeIsolated {
                if RealtimeClient.shared.isConnected { self?.refreshUnreadCount() }
            }
        })
        refreshUnreadCount()
    }

    func setUnreadCount(_ count: Int) {
        notificationsNav?.tabBarItem.badgeValue = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
    }

    func refreshUnreadCount() {
        Task {
            if let count = try? await service.unreadCount() { setUnreadCount(count) }
        }
    }
}
