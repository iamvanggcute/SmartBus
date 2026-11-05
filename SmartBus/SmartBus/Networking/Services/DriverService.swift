//
//  DriverService.swift
//  SmartBus
//
//  API của app phụ xe (04 §10). Mọi lỗi nghiệp vụ trả về `APIError.server(ServerError)`.
//

import Foundation

struct DriverService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    /// GET /driver/trips — mặc định hôm nay (giờ VN).
    func trips(date: String? = nil) async throws -> [DriverTrip] {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let date { query.append(URLQueryItem(name: "date", value: date)) }
        return try await client.send(Endpoint(path: "driver/trips", query: query))
    }

    /// GET /driver/trips/:id/manifest — chỉ chuyến scheduled/active (khác → 409 INVALID_TRIP_STATUS).
    func manifest(tripId: String) async throws -> ManifestResponse {
        try await client.send(Endpoint(path: "driver/trips/\(tripId)/manifest"))
    }

    /// POST /driver/trips/:id/start — lỗi: INVALID_TRIP_STATUS, ANOTHER_TRIP_ALREADY_ACTIVE,
    /// VEHICLE_NOT_ACTIVE, TOO_EARLY_TO_START.
    func startTrip(tripId: String, startedAtMs: Int64) async throws -> StartTripResponse {
        try await client.send(Endpoint(
            path: "driver/trips/\(tripId)/start", method: .post,
            body: StartTripRequest(startedAtMs: startedAtMs)
        ))
    }

    /// POST /driver/trips/:id/attendance/sync — tối đa 100 sự kiện mỗi lô.
    func syncAttendance(tripId: String, events: [AttendanceEventPayload]) async throws -> AttendanceSyncResponse {
        try await client.send(Endpoint(
            path: "driver/trips/\(tripId)/attendance/sync", method: .post,
            body: AttendanceSyncRequest(events: events)
        ))
    }

    /// POST /driver/trips/:id/safety-check — luôn 200, xem `status` passed/flagged.
    func safetyCheck(tripId: String, rearQrPayload: String, latitude: Double?, longitude: Double?) async throws -> SafetyCheckResponse {
        try await client.send(Endpoint(
            path: "driver/trips/\(tripId)/safety-check", method: .post,
            body: SafetyCheckRequest(rearQrPayload: rearQrPayload, latitude: latitude, longitude: longitude, recordedAtMs: Date().milliseconds)
        ))
    }

    /// POST /driver/trips/:id/complete — bị khóa → 409 TRIP_COMPLETION_LOCKED.
    func completeTrip(tripId: String) async throws -> CompleteTripResponse {
        try await client.send(Endpoint(
            path: "driver/trips/\(tripId)/complete", method: .post, body: EmptyBody()
        ))
    }

    /// POST /driver/trips/:id/sos — chuyến phải đang chạy.
    func sos(tripId: String, category: SOSCategory, note: String?, latitude: Double?, longitude: Double?) async throws -> SOSResponse {
        try await client.send(Endpoint(
            path: "driver/trips/\(tripId)/sos", method: .post,
            body: SOSRequest(category: category, note: note, latitude: latitude, longitude: longitude)
        ))
    }

    /// GET /driver/trips/:id/directions — chuyến phải đang chạy; 120 lượt / giờ.
    /// Lỗi: NO_REMAINING_STOP, ROUTING_SERVICE_UNAVAILABLE (502), TOO_MANY_REQUESTS.
    func directions(tripId: String, latitude: Double, longitude: Double, stopId: String?) async throws -> DirectionsResponse {
        var query = [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", longitude))
        ]
        if let stopId { query.append(URLQueryItem(name: "stop_id", value: stopId)) }
        return try await client.send(Endpoint(path: "driver/trips/\(tripId)/directions", query: query))
    }
}

/// Body rỗng `{}`.
struct EmptyBody: Encodable {}
