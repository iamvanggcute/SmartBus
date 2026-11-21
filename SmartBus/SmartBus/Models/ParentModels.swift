//
//  ParentModels.swift
//  SmartBus
//
//  Dữ liệu app phụ huynh (04 §9.7, §11.1, §12, §14.3).
//  Dùng lại TripDirection / TripStatus / ManifestStatus của DriverModels.
//

import Foundation

// MARK: - GET /parent/children

struct ChildStop: Decodable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

struct ChildRoute: Decodable {
    let id: String
    let routeCode: String?
    let name: String
}

/// Chuyến hôm nay theo thứ tự ưu tiên: đang chạy → chưa bắt đầu sớm nhất → hoàn tất gần nhất.
struct ChildCurrentTrip: Decodable {
    let tripId: String
    let direction: TripDirection
    let tripStatus: TripStatus
    let studentStatus: ManifestStatus
    let scheduledStartTimeMs: Int64?
}

struct ParentChild: Decodable {
    let id: String
    let studentCode: String
    let fullName: String
    let className: String?
    let photoUrl: String?
    let relationship: String?
    let route: ChildRoute?
    let pickupStop: ChildStop?
    let dropoffStop: ChildStop?
    let currentTrip: ChildCurrentTrip?

    /// Điểm của con trong chuyến: đi học → điểm đón, về nhà → điểm trả.
    func stop(for direction: TripDirection) -> ChildStop? {
        direction == .toSchool ? pickupStop : dropoffStop
    }
}

// MARK: - GET /trips/:id/live

struct LiveTripInfo: Decodable {
    let id: String
    let status: TripStatus
    let direction: TripDirection
    let actualStartTimeMs: Int64?
}

struct LiveVehicle: Decodable {
    let licensePlate: String
    let model: String?
}

struct LiveRoute: Decodable {
    let id: String
    let name: String
    let polyline: String?
}

struct LiveStop: Decodable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let stopOrder: Int
    let isSchool: Bool
    let isStudentStop: Bool
    let arrivedAtMs: Int64?
    /// done | next | upcoming
    let progress: String?
}

struct LiveLocation: Decodable {
    var latitude: Double
    var longitude: Double
    var speedKmh: Double?
    var heading: Double?
    var recordedAtMs: Int64
    var isStale: Bool
}

struct LiveStudent: Decodable {
    let id: String
    let fullName: String
    let status: ManifestStatus
}

struct LiveETA: Decodable {
    let targetStopId: String
    let targetStopName: String
    let etaMinutes: Int
    let distanceMeters: Int?
    /// true: ước tính đường chim bay (Goong và OSRM đều lỗi); khi đó `polyline` là null.
    let isEstimate: Bool
    let calculatedAtMs: Int64
    let polyline: String?
}

struct LiveTripResponse: Decodable {
    let trip: LiveTripInfo
    let vehicle: LiveVehicle
    let route: LiveRoute
    let stops: [LiveStop]
    var currentLocation: LiveLocation?
    let student: LiveStudent?
    let eta: LiveETA?

    /// Thứ tự xe đi, giống server (orderStopsForDirection): về nhà thì trường trước, các điểm nhà ngược lại.
    var orderedStops: [LiveStop] {
        let sorted = stops.sorted { $0.stopOrder < $1.stopOrder }
        guard trip.direction == .fromSchool else { return sorted }
        return sorted.filter(\.isSchool) + sorted.filter { !$0.isSchool }.reversed()
    }
}

// MARK: - Thông báo (04 §12)

/// attendance | attendance_correction | proximity | trip_completed | safety_alert | absence_update
struct AppNotification: Decodable {
    let id: String
    let type: String
    let title: String
    let body: String
    let tripId: String?
    let studentId: String?
    var isRead: Bool
    let createdAtMs: Int64

    init(id: String, type: String, title: String, body: String, tripId: String?, studentId: String?, isRead: Bool, createdAtMs: Int64) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.tripId = tripId
        self.studentId = studentId
        self.isRead = isRead
        self.createdAtMs = createdAtMs
    }
}

/// Gửi đúng một trong hai: `ids` (1..100) hoặc `all: true`. Trường nil không được encode.
struct MarkNotificationsReadRequest: Encodable {
    let ids: [String]?
    let all: Bool?
}

struct MarkNotificationsReadResponse: Decodable {
    let updatedCount: Int
}

struct NotificationPage {
    let items: [AppNotification]
    let total: Int
    let unreadCount: Int
}

// MARK: - Hiển thị

enum ParentFormat {
    /// "06:24" hôm nay, "Hôm qua", hoặc "04/11".
    static func relative(ms: Int64) -> String {
        let date = Date(milliseconds: ms)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return TimeFormat.time(ms: ms) }
        if calendar.isDateInYesterday(date) { return "Hôm qua" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }

    static func ago(ms: Int64) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(Date(milliseconds: ms))))
        if seconds < 60 { return "\(seconds) giây trước" }
        if seconds < 3600 { return "\(seconds / 60) phút trước" }
        return "lúc \(TimeFormat.time(ms: ms))"
    }
}
