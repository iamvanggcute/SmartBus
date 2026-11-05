//
//  AuthService.swift
//  SmartBus
//
//  API xác thực (04 §2): đăng nhập, lấy thông tin tài khoản, đăng xuất.
//

import Foundation

struct AuthService {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    /// POST /auth/login — `identifier` là tên đăng nhập hoặc số điện thoại.
    /// Lỗi có thể gặp: VALIDATION_ERROR, INVALID_CREDENTIALS, ACCOUNT_SUSPENDED,
    /// ACCOUNT_INACTIVE, CLIENT_ROLE_MISMATCH, TOO_MANY_REQUESTS (kèm Retry-After).
    func login(identifier: String, password: String) async throws -> LoginResponse {
        let body = LoginRequest(identifier: identifier, password: password, client: APIConfig.clientType)
        return try await client.send(Endpoint(path: "auth/login", method: .post, body: body, requiresAuth: false))
    }

    /// GET /auth/me — kiểm tra token còn dùng được và lấy thông tin mới nhất.
    func me() async throws -> AppUser {
        try await client.send(Endpoint(path: "auth/me"), as: MeResponse.self).user
    }

    /// POST /auth/logout — với phụ xe, server chặn khi còn chuyến đang chạy
    /// (LOGOUT_BLOCKED_ACTIVE_TRIP) hoặc còn thao tác chưa đồng bộ (LOGOUT_BLOCKED_PENDING_EVENTS).
    func logout(hasPendingOfflineEvents: Bool = false) async throws {
        let body = LogoutRequest(hasPendingOfflineEvents: hasPendingOfflineEvents)
        _ = try await client.send(Endpoint(path: "auth/logout", method: .post, body: body), as: LogoutResponse.self)
    }
}
