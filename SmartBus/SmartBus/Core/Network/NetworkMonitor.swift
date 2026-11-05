//
//  NetworkMonitor.swift
//  SmartBus
//
//  Theo dõi có mạng hay không để tự đồng bộ outbox khi có mạng lại (US11 AC1).
//

import Foundation
import Network

extension Notification.Name {
    static let networkStatusDidChange = Notification.Name("SmartBus.networkStatusDidChange")
}

@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                NotificationCenter.default.post(name: .networkStatusDidChange, object: nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "SmartBus.NetworkMonitor"))
    }

    /// Gọi sớm (khi mở app) để bắt đầu theo dõi.
    func start() {}
}
