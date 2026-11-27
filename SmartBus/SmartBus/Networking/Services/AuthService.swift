//
//  AuthService.swift
//  SmartBus
//
//  API xác thực (04 §2): đăng nhập, lấy thông tin tài khoản, đăng xuất, đổi mật khẩu.
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

    /// PATCH /auth/password (US43) — trả token mới cho máy này; mọi phiên khác bị thu hồi.
    /// Lỗi: WRONG_CURRENT_PASSWORD, WEAK_PASSWORD (yếu hoặc trùng mật khẩu cũ), VALIDATION_ERROR (> 72 byte).
    func changePassword(current: String, new: String) async throws -> ChangePasswordResponse {
        let body = ChangePasswordRequest(currentPassword: current, newPassword: new)
        return try await client.send(Endpoint(path: "auth/password", method: .patch, body: body))
    }

    /// POST /auth/logout — với phụ xe, server chặn khi còn chuyến đang chạy
    /// (LOGOUT_BLOCKED_ACTIVE_TRIP) hoặc còn thao tác chưa đồng bộ (LOGOUT_BLOCKED_PENDING_EVENTS).
    func logout(hasPendingOfflineEvents: Bool = false) async throws {
        let body = LogoutRequest(hasPendingOfflineEvents: hasPendingOfflineEvents)
        _ = try await client.send(Endpoint(path: "auth/logout", method: .post, body: body), as: LogoutResponse.self)
    }
}
