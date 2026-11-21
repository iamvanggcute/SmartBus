//
//  AbsenceModels.swift
//  SmartBus
//
//  Đơn xin nghỉ của phụ huynh (04 §11.3–§11.6, 05 §13).
//

import Foundation

enum AbsenceSession: String, Codable, CaseIterable {
    case morning
    case afternoon
    case fullDay = "full_day"

    var title: String {
        switch self {
        case .morning: return "Buổi sáng"
        case .afternoon: return "Buổi chiều"
        case .fullDay: return "Cả ngày"
        }
    }

    /// Chuyến bị ảnh hưởng (05 §13.5).
    var subtitle: String {
        switch self {
        case .morning: return "chuyến đến trường"
        case .afternoon: return "chuyến về nhà"
        case .fullDay: return "cả 2 chuyến"
        }
    }
}

enum AbsenceStatus: String, Decodable {
    case active, cancelled, rejected

    var title: String {
        switch self {
        case .active: return "Có hiệu lực"
        case .cancelled: return "Đã hủy"
        case .rejected: return "Bị từ chối"
        }
    }
}

// MARK: - POST /parent/absence-requests/ai-parse

struct AbsenceAIParseRequest: Encodable {
    let rawText: String
}

struct AbsenceAIExtracted: Decodable {
    let studentId: String?
    let absenceDate: String?
    let session: AbsenceSession?
    let reason: String?

    private enum CodingKeys: String, CodingKey { case studentId, absenceDate, session, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        studentId = try container.decodeIfPresent(String.self, forKey: .studentId)
        absenceDate = try container.decodeIfPresent(String.self, forKey: .absenceDate)
        // Giá trị lạ thì coi như AI chưa rõ, không làm hỏng cả phản hồi.
        let rawSession: String? = (try? container.decodeIfPresent(String.self, forKey: .session)) ?? nil
        session = rawSession.flatMap { AbsenceSession(rawValue: $0) }
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

struct AbsenceAIParseResponse: Decodable {
    let aiSuccess: Bool
    let rawInputText: String
    let extracted: AbsenceAIExtracted?
    /// student_id | absence_date | session | reason
    let missingFields: [String]
}

// MARK: - POST /parent/absence-requests

struct CreateAbsenceRequest: Encodable {
    let studentId: String
    let absenceDate: String
    let session: AbsenceSession
    let reason: String
    let isAiExtracted: Bool
    let rawInputText: String?
}

struct AffectedTrip: Decodable {
    let tripId: String
    let direction: TripDirection
}

struct CreateAbsenceResponse: Decodable {
    let id: String
    let status: AbsenceStatus
    let affectedTrips: [AffectedTrip]
}

// MARK: - GET /parent/absence-requests

struct AbsenceRequestItem: Decodable {
    let id: String
    let studentId: String
    let studentFullName: String
    let absenceDate: String
    let session: AbsenceSession
    let reason: String
    let status: AbsenceStatus
    let reviewNote: String?
    let isAiExtracted: Bool
    let canCancel: Bool
    let createdAtMs: Int64
}

struct CancelAbsenceResponse: Decodable {
    let id: String
    let status: AbsenceStatus
}

// MARK: - Ngày

enum AbsenceDate {
    private static let apiFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "EEEE, dd/MM/yyyy"
        return formatter
    }()

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter
    }()

    /// "2026-11-20" (giờ VN), dạng server nhận.
    static func api(_ date: Date) -> String { apiFormatter.string(from: date) }

    static func date(from api: String) -> Date? { apiFormatter.date(from: api) }

    /// "Thứ Sáu, 20/11/2026"
    static func display(_ api: String) -> String {
        guard let date = date(from: api) else { return api }
        let text = displayFormatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "20/11/2026"
    static func short(_ api: String) -> String {
        guard let date = date(from: api) else { return api }
        return shortFormatter.string(from: date)
    }
}
