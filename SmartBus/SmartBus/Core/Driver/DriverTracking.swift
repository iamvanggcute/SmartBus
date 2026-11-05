//
//  DriverTracking.swift
//  SmartBus
//
//  Nối chuyến đang chạy với GPS và Socket.IO:
//  có chuyến active → bật vị trí, kết nối socket, vào room chuyến, gửi `gps:update` 5 giây/lần.
//  Hết chuyến active → tắt vị trí (giữ pin).
//

import Foundation
import CoreLocation

@MainActor
final class DriverTracking {
    static let shared = DriverTracking()

    private var observers: [NSObjectProtocol] = []
    private var trackedTripId: String?

    /// Gọi khi phụ xe vào app (sau đăng nhập).
    func activate() {
        guard observers.isEmpty else { return }
        RealtimeClient.shared.connect()
        observers.append(NotificationCenter.default.addObserver(forName: .tripSessionDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .locationDidUpdate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendLocation() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .networkStatusDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if NetworkMonitor.shared.isOnline { RealtimeClient.shared.connect() }
            }
        })
        update()
    }

    /// Gọi khi đăng xuất / hết phiên.
    func deactivate() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        trackedTripId = nil
        LocationTracker.shared.stop()
        RealtimeClient.shared.disconnect()
    }

    private func update() {
        let active = TripSessionManager.shared.activeSession
        guard active?.tripId != trackedTripId else { return }
        if let old = trackedTripId { RealtimeClient.shared.unsubscribe(tripId: old) }
        trackedTripId = active?.tripId
        if let tripId = trackedTripId {
            LocationTracker.shared.start()
            RealtimeClient.shared.connect()
            RealtimeClient.shared.subscribe(tripId: tripId)
            sendLocation()
        } else {
            LocationTracker.shared.stop()
        }
    }

    private func sendLocation() {
        guard let tripId = trackedTripId, let location = LocationTracker.shared.recentLocation else { return }
        RealtimeClient.shared.sendGPS(
            tripId: tripId,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speedKmh: location.speed >= 0 ? location.speed * 3.6 : nil,
            heading: location.course >= 0 ? location.course : nil,
            recordedAtMs: Int64(location.timestamp.timeIntervalSince1970 * 1000)
        )
    }
}
