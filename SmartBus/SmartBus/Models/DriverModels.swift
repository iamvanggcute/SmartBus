//
//  DriverModels.swift
//  SmartBus
//
//  Model cho API phụ xe (04 §10). Server dùng snake_case, APIClient tự đổi sang camelCase.
//  Các model này cũng được lưu xuống SQLite (JSON camelCase) để dùng khi mất mạng.
//

import Foundation

enum TripDirection: String, Codable {
    case toSchool = "to_school"
    case fromSchool = "from_school"

    var title: String { self == .toSchool ? "Đến trường" : "Về nhà" }
}

enum TripStatus: String, Codable {
    case scheduled, active, completed, cancelled

    var title: String {
        switch self {
        case .scheduled: return "Chưa bắt đầu"
        case .active: return "Đang chạy"
        case .completed: return "Đã hoàn tất"
        case .cancelled: return "Đã hủy"
        }
    }
}

/// Trạng thái học sinh trong chuyến (`trip_manifest_items.status`).
enum ManifestStatus: String, Codable {
    case expected, boarded, alighted, absent

    var title: String {
        switch self {
        case .expected: return "Chưa lên"
        case .boarded: return "Trên xe"
        case .alighted: return "Đã xuống"
        case .absent: return "Vắng"
        }
    }
}

struct StudentCounts: Codable, Equatable {
    var total: Int
    var expected: Int
    var absent: Int
    var boarded: Int
    var alighted: Int
}

struct RouteSummary: Codable {
    let id: String
    let routeCode: String?
    let name: String
}

struct VehicleSummary: Codable {
    let id: String
    let licensePlate: String
    let model: String?
}

// MARK: - GET /driver/trips

struct DriverTrip: Codable {
    let id: String
    let scheduledDate: String
    let direction: TripDirection
    let scheduledStartTimeMs: Int64
    let scheduledEndTimeMs: Int64
    let status: TripStatus
    let route: RouteSummary
    let vehicle: VehicleSummary
    let studentCounts: StudentCounts
}

// MARK: - GET /driver/trips/:id/manifest

struct ManifestTrip: Codable {
    let id: String
    let direction: TripDirection
    var status: TripStatus
    let scheduledDate: String
    let scheduledStartTimeMs: Int64
    let scheduledEndTimeMs: Int64
    var actualStartTimeMs: Int64?
}

struct RouteStop: Codable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let stopOrder: Int
    let isSchool: Bool
    let arrivedAtMs: Int64?
    /// "done" | "next" | "upcoming"
    let progress: String?
}

struct ManifestRoute: Codable {
    let id: String
    let name: String
    let polyline: String?
    let stops: [RouteStop]
}

struct ManifestVehicle: Codable {
    let id: String
    let licensePlate: String
    let rearQrVersion: Int
    let rearQrHmacHash: String?
}

struct ManifestItem: Codable {
    let studentId: String
    let studentCode: String
    let fullName: String
    let className: String?
    let photoUrl: String?
    let stopId: String?
    var status: ManifestStatus
    let isUnexpected: Bool
    let qrVersion: Int
    let qrHmacHash: String
    /// Sự kiện hiệu lực gần nhất trên server, dùng để thu hồi (US08 AC5).
    var lastEffectiveEventId: String?
}

struct ManifestResponse: Codable {
    var trip: ManifestTrip
    let route: ManifestRoute
    let vehicle: ManifestVehicle
    var manifestItems: [ManifestItem]
    var summaryCounts: StudentCounts
    let downloadedAtMs: Int64
}

// MARK: - POST /driver/trips/:id/start

struct StartTripRequest: Codable {
    let startedAtMs: Int64
}

struct StartTripResponse: Decodable {
    let tripId: String?
    let status: TripStatus?
    let actualStartTimeMs: Int64?
    let alreadyStarted: Bool?
}

// MARK: - POST /driver/trips/:id/attendance/sync

enum AttendanceEventType: String, Codable {
    case boarded, alighted, revoked
}

enum ScanMethod: String, Codable {
    case qr, manual
}

/// Một thao tác điểm danh. Ghi vào outbox trước, gửi mạng sau (05 §9.1).
struct AttendanceEventPayload: Codable {
    let eventId: String
    let eventType: AttendanceEventType
    let scanMethod: ScanMethod
    let qrPayload: String?
    let studentId: String?
    let targetEventId: String?
    let recordedAtMs: Int64
    let latitude: Double?
    let longitude: Double?
    let nearestStopId: String?
}

struct AttendanceSyncRequest: Encodable {
    let events: [AttendanceEventPayload]
}

struct AttendanceSyncResult: Decodable {
    let eventId: String
    /// "accepted" | "already_synced" | "ignored" | "rejected"
    let result: String
    let studentId: String?
    let eventType: String?
    let manifestStatus: ManifestStatus?
    let warnings: [String]?
    let reason: String?
    let message: String?
}

struct AttendanceSyncResponse: Decodable {
    let results: [AttendanceSyncResult]
    let summaryCounts: StudentCounts?
    let syncedAtMs: Int64?
}

// MARK: - POST /driver/trips/:id/safety-check

struct SafetyCheckRequest: Encodable {
    let rearQrPayload: String
    let latitude: Double?
    let longitude: Double?
    let recordedAtMs: Int64
}

struct BoardedStudent: Decodable {
    let studentId: String
    let fullName: String
}

struct SafetyCheckResponse: Decodable {
    let checkpointId: String
    /// "passed" | "flagged"
    let status: String
    let flagReason: String?
    let boardedRemainingCount: Int?
    let boardedStudents: [BoardedStudent]?
    let alertId: String?
    let message: String

    var passed: Bool { status == "passed" }
}

// MARK: - POST /driver/trips/:id/complete

struct CompleteTripResponse: Decodable {
    let tripId: String
    let status: TripStatus
    let completionType: String?
    let actualEndTimeMs: Int64?
}

// MARK: - POST /driver/trips/:id/sos

enum SOSCategory: String, Encodable, CaseIterable {
    case accident, breakdown, studentHealth = "student_health", other

    var title: String {
        switch self {
        case .accident: return "Tai nạn"
        case .breakdown: return "Hỏng xe"
        case .studentHealth: return "Sức khỏe học sinh"
        case .other: return "Khác"
        }
    }

    var subtitle: String {
        switch self {
        case .accident: return "Va chạm giao thông"
        case .breakdown: return "Xe không chạy tiếp được"
        case .studentHealth: return "Học sinh cần trợ giúp"
        case .other: return "Sự cố khác"
        }
    }
}

struct SOSRequest: Encodable {
    let category: SOSCategory
    let note: String?
    let latitude: Double?
    let longitude: Double?
}

struct SOSResponse: Decodable {
    let alertId: String
    let createdAtMs: Int64?
}

// MARK: - Tiện ích thời gian

enum TimeFormat {
    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.dateFormat = "EEEE, dd/MM/yyyy"
        return formatter
    }()

    static func time(ms: Int64?) -> String {
        guard let ms else { return "--:--" }
        return hourMinute.string(from: Date(milliseconds: ms))
    }

    static func today() -> String {
        fullDate.string(from: Date()).capitalized(with: Locale(identifier: "vi_VN"))
    }
}

extension Date {
    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    var milliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
