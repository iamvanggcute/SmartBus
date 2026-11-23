//
//  ParentService.swift
//  SmartBus
//
//  API của app phụ huynh:
//  GET /parent/children, GET /trips/:id/live, GET /notifications, PATCH /notifications/read.
//

import Foundation

struct ParentService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    /// Danh sách con (đã sắp theo tên). Phụ huynh thường có ít con nên lấy một trang 100.
    func children() async throws -> [ParentChild] {
        try await client.send(Endpoint(
            path: "parent/children",
            query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: "100")]
        ))
    }

    /// Theo dõi trực tiếp. `studentId` là con muốn xem ETA; không phải con mình → 403 FORBIDDEN_RESOURCE.
    func live(tripId: String, studentId: String?) async throws -> LiveTripResponse {
        var query: [URLQueryItem] = []
        if let studentId { query.append(URLQueryItem(name: "student_id", value: studentId)) }
        return try await client.send(Endpoint(path: "trips/\(tripId)/live", query: query))
    }

    func notifications(unreadOnly: Bool, page: Int, limit: Int = 20) async throws -> NotificationPage {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if unreadOnly { query.append(URLQueryItem(name: "unread_only", value: "true")) }
        let (items, meta) = try await client.sendWithMeta(Endpoint(path: "notifications", query: query), as: [AppNotification].self)
        return NotificationPage(items: items,
                                total: meta?.pagination?.total ?? items.count,
                                unreadCount: meta?.unreadCount ?? 0)
    }

    /// Chỉ cần số chưa đọc (badge tab Thông báo).
    func unreadCount() async throws -> Int {
        try await notifications(unreadOnly: true, page: 1, limit: 1).unreadCount
    }

    // MARK: - Đơn xin nghỉ (04 §11.3–§11.6)

    /// Không ghi DB. Lỗi AI → `ai_success: false`; quá 20 lượt / giờ → 429 TOO_MANY_REQUESTS.
    func parseAbsence(rawText: String) async throws -> AbsenceAIParseResponse {
        try await client.send(Endpoint(
            path: "parent/absence-requests/ai-parse", method: .post,
            body: AbsenceAIParseRequest(rawText: String(rawText.prefix(500)))
        ))
    }

    /// Lỗi: DATE_IN_PAST, DUPLICATE_ABSENCE_REQUEST, SESSION_ALREADY_COMPLETED, STUDENT_ALREADY_ON_TRIP.
    func createAbsence(_ request: CreateAbsenceRequest) async throws -> CreateAbsenceResponse {
        try await client.send(Endpoint(path: "parent/absence-requests", method: .post, body: request))
    }

    func absenceRequests(page: Int, limit: Int = 20) async throws -> (items: [AbsenceRequestItem], total: Int) {
        let (items, meta) = try await client.sendWithMeta(Endpoint(
            path: "parent/absence-requests",
            query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
        ), as: [AbsenceRequestItem].self)
        return (items, meta?.pagination?.total ?? items.count)
    }

    /// Lỗi: ABSENCE_NOT_CANCELLABLE (`details.reason`: NOT_ACTIVE | TRIP_ALREADY_STARTED).
    func cancelAbsence(id: String) async throws -> CancelAbsenceResponse {
        try await client.send(Endpoint(path: "parent/absence-requests/\(id)/cancel", method: .patch, body: EmptyBody()))
    }

    @discardableResult
    func markRead(ids: [String]) async throws -> Int {
        let response: MarkNotificationsReadResponse = try await client.send(Endpoint(
            path: "notifications/read", method: .patch,
            body: MarkNotificationsReadRequest(ids: Array(ids.prefix(100)), all: nil)
        ))
        return response.updatedCount
    }

    @discardableResult
    func markAllRead() async throws -> Int {
        let response: MarkNotificationsReadResponse = try await client.send(Endpoint(
            path: "notifications/read", method: .patch,
            body: MarkNotificationsReadRequest(ids: nil, all: true)
        ))
        return response.updatedCount
    }
}
