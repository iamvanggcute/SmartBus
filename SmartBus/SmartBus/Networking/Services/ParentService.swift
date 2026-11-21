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
