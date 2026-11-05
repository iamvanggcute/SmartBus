//
//  RealtimeClient.swift
//  SmartBus
//
//  Kết nối Socket.IO với backend (04 §14). Handshake `auth: { token }`.
//  Phụ xe: gửi `gps:update`, nhận `manifest:updated`, `trip:stop_arrived`, `session:revoked`.
//
//  Cần package SocketIO: https://github.com/socketio/socket.io-client-swift (16.x).
//

import Foundation
import SocketIO

extension Notification.Name {
    /// object: `ManifestRemoteChange`
    static let manifestDidChangeRemotely = Notification.Name("SmartBus.manifestDidChangeRemotely")
    static let realtimeStatusDidChange = Notification.Name("SmartBus.realtimeStatusDidChange")
}

/// `manifest:updated` { trip_id, reason, student_ids, summary_counts }
struct ManifestRemoteChange {
    let tripId: String
    let reason: String
    let studentIds: [String]

    /// Câu hiển thị cho phụ xe; `nil` khi không cần báo (ví dụ chính máy này vừa điểm danh).
    var message: String? {
        switch reason {
        case "absence_created": return "Phụ huynh vừa báo nghỉ cho \(studentIds.count) em. Danh sách đã cập nhật."
        case "absence_cancelled": return "Phụ huynh đã hủy đơn nghỉ của \(studentIds.count) em. Em sẽ đi xe như bình thường."
        case "absence_rejected": return "Đơn nghỉ của \(studentIds.count) em bị từ chối. Em sẽ đi xe như bình thường."
        case "assignment_changed": return "Giám sát viên vừa đổi danh sách học sinh của chuyến."
        case "trip_reassigned": return "Chuyến vừa được giao lại."
        default: return nil
        }
    }
}

@MainActor
final class RealtimeClient {
    static let shared = RealtimeClient()

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var subscribedTripIds = Set<String>()
    private var lastGpsSentAt = Date.distantPast
    /// App chuẩn gửi 5–10 giây/lần (05 §8.1).
    private let gpsInterval: TimeInterval = 5

    var isConnected: Bool { socket?.status == .connected }

    /// `http://host:port` lấy từ `APIConfig.baseURL` (bỏ `/api/v1`).
    private var serverURL: URL? {
        guard var components = URLComponents(url: APIConfig.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        return components.url
    }

    func connect() {
        guard socket == nil, let token = SessionManager.shared.accessToken, let url = serverURL else { return }
        let manager = SocketManager(socketURL: url, config: [
            .log(false),
            .path("/socket.io/"),
            .compress,
            .reconnects(true),
            .reconnectWait(2),
            .reconnectWaitMax(30),
            .forceWebsockets(true)
        ])
        let socket = manager.defaultSocket
        self.manager = manager
        self.socket = socket
        registerHandlers(socket)
        socket.connect(withPayload: ["token": token])
    }

    func disconnect() {
        socket?.removeAllHandlers()
        socket?.disconnect()
        manager?.disconnect()
        socket = nil
        manager = nil
        subscribedTripIds.removeAll()
        NotificationCenter.default.post(name: .realtimeStatusDidChange, object: self)
    }

    /// Vào room trip:<id>. Server chỉ tự cho vào room các chuyến đang chạy lúc kết nối,
    /// nên chuyến vừa bắt đầu phải gọi `trip:subscribe`.
    func subscribe(tripId: String) {
        subscribedTripIds.insert(tripId)
        guard isConnected else { return }
        socket?.emitWithAck("trip:subscribe", ["trip_id": tripId]).timingOut(after: 10) { _ in }
    }

    func unsubscribe(tripId: String) {
        subscribedTripIds.remove(tripId)
        guard isConnected else { return }
        socket?.emit("trip:unsubscribe", ["trip_id": tripId])
    }

    /// Gửi vị trí; mất kết nối thì bỏ qua (GPS không xếp hàng, server chỉ giữ điểm mới nhất).
    func sendGPS(tripId: String, latitude: Double, longitude: Double, speedKmh: Double?, heading: Double?, recordedAtMs: Int64) {
        guard isConnected, Date().timeIntervalSince(lastGpsSentAt) >= gpsInterval else { return }
        lastGpsSentAt = Date()
        var payload: [String: Any] = [
            "trip_id": tripId,
            "latitude": latitude,
            "longitude": longitude,
            "recorded_at_ms": recordedAtMs
        ]
        if let speedKmh { payload["speed_kmh"] = min(max(speedKmh, 0), 400) }
        if let heading { payload["heading"] = min(max(heading, 0), 360) }
        socket?.emitWithAck("gps:update", payload).timingOut(after: 10) { data in
            guard let ack = data.first as? [String: Any], ack["ok"] as? Bool == false else { return }
            #if DEBUG
            print("gps:update bị từ chối:", ack["code"] ?? "")
            #endif
        }
    }

    // MARK: - Handlers

    private func registerHandlers(_ socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for tripId in self.subscribedTripIds { self.subscribe(tripId: tripId) }
                NotificationCenter.default.post(name: .realtimeStatusDidChange, object: self)
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .realtimeStatusDidChange, object: self)
            }
        }
        // connect_error: message là mã lỗi (UNAUTHORIZED, TOKEN_EXPIRED, TOKEN_REVOKED, ACCOUNT_SUSPENDED, ACCOUNT_INACTIVE).
        socket.on(clientEvent: .error) { [weak self] data, _ in
            let text = data.compactMap { "\($0)" }.joined(separator: " ")
            MainActor.assumeIsolated {
                let authCodes = ["TOKEN_EXPIRED", "TOKEN_REVOKED", "ACCOUNT_SUSPENDED", "ACCOUNT_INACTIVE", "UNAUTHORIZED"]
                guard let code = authCodes.first(where: { text.contains($0) }) else { return }
                self?.disconnect()
                let message = code == "TOKEN_EXPIRED" ? "Phiên đăng nhập đã hết hạn" : "Phiên đăng nhập không còn hiệu lực"
                NotificationCenter.default.post(name: .sessionDidExpire,
                                                object: ServerError(status: 401, code: code, message: message, details: [], retryAfterSeconds: nil))
            }
        }

        socket.on("manifest:updated") { data, _ in
            guard let body = data.first as? [String: Any], let tripId = body["trip_id"] as? String else { return }
            let change = ManifestRemoteChange(tripId: tripId,
                                              reason: body["reason"] as? String ?? "",
                                              studentIds: body["student_ids"] as? [String] ?? [])
            MainActor.assumeIsolated {
                TripSessionManager.shared.handleRemoteChange(change)
            }
        }

        socket.on("trip:stop_arrived") { data, _ in
            guard let body = data.first as? [String: Any], let tripId = body["trip_id"] as? String else { return }
            MainActor.assumeIsolated {
                TripSessionManager.shared.handleStopArrived(tripId: tripId)
            }
        }

        // password_changed | account_disabled: server ngắt socket → về đăng nhập.
        // trip_reassigned: chuyến không còn của phụ xe này, tải lại danh sách chuyến.
        socket.on("session:revoked") { [weak self] data, _ in
            let reason = (data.first as? [String: Any])?["reason"] as? String
            MainActor.assumeIsolated {
                if reason == "trip_reassigned" {
                    TripSessionManager.shared.handleTripReassigned()
                    return
                }
                self?.disconnect()
                let message = reason == "password_changed"
                    ? "Mật khẩu vừa được đổi, vui lòng đăng nhập lại"
                    : "Tài khoản đã bị khóa, vui lòng liên hệ nhà trường"
                NotificationCenter.default.post(name: .sessionDidExpire,
                                                object: ServerError(status: 401, code: "SESSION_REVOKED", message: message, details: [], retryAfterSeconds: nil))
            }
        }
    }
}
