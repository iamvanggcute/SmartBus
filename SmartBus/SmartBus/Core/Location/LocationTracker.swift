//
//  LocationTracker.swift
//  SmartBus
//
//  Vị trí điện thoại của phụ xe (05 §8.1). Chỉ bật khi có chuyến đang chạy.
//  Vị trí mới nhất được gắn vào điểm danh, SOS, kiểm tra ghế cuối và gửi GPS lên server.
//

import CoreLocation
import UIKit

extension Notification.Name {
    static let locationDidUpdate = Notification.Name("SmartBus.locationDidUpdate")
    static let locationAuthorizationDidChange = Notification.Name("SmartBus.locationAuthorizationDidChange")
}

@MainActor
final class LocationTracker: NSObject {
    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private(set) var lastLocation: CLLocation?
    private(set) var isRunning = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Vị trí còn mới (trong 2 phút) để gắn vào thao tác; cũ hơn thì gửi `nil`.
    var recentLocation: CLLocation? {
        guard let lastLocation, Date().timeIntervalSince(lastLocation.timestamp) < 120,
              lastLocation.horizontalAccuracy >= 0, lastLocation.horizontalAccuracy < 200 else { return nil }
        return lastLocation
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }

    private func beginUpdates() {
        // Cần bật Background Modes → Location updates; nếu chưa bật thì chỉ chạy khi app đang mở.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    /// Điểm dừng gần nhất trong 300 m, gửi kèm điểm danh (`nearest_stop_id`).
    func nearestStopId(in stops: [RouteStop]) -> String? {
        guard let location = recentLocation else { return nil }
        let nearest = stops
            .map { ($0, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= 300 else { return nil }
        return nearest.0.id
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if isRunning, authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
                beginUpdates()
            }
            NotificationCenter.default.post(name: .locationAuthorizationDidChange, object: self)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            lastLocation = location
            NotificationCenter.default.post(name: .locationDidUpdate, object: self)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Mất tín hiệu tạm thời: giữ vị trí cũ, CoreLocation tự thử lại.
    }
}
