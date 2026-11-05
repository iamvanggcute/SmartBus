//
//  AuthModels.swift
//  SmartBus
//
//  Model cho các API xác thực (04 §2). JSON dùng snake_case,
//  APIClient tự đổi sang camelCase khi encode/decode.
//

import Foundation

enum UserRole: String, Codable {
    case driverAttendant = "driver_attendant"
    case parent = "parent"
    case supervisorAdmin = "supervisor_admin"
}

struct AppUser: Codable, Equatable {
    let id: String
    let username: String
    let fullName: String
    let phone: String?
    let email: String?
    let role: UserRole
    let status: String
}

// MARK: - POST /auth/login

struct LoginRequest: Encodable {
    let identifier: String
    let password: String
    let client: String
}

struct LoginResponse: Decodable {
    let accessToken: String
    let tokenType: String
    /// Thời hạn token (giây), hiện là 43200 = 12 giờ.
    let expiresIn: Int
    let user: AppUser
}

// MARK: - GET /auth/me

struct MeResponse: Decodable {
    let user: AppUser
}

// MARK: - POST /auth/logout

struct LogoutRequest: Encodable {
    /// Chỉ app phụ xe gửi `true` khi còn thao tác offline chưa đồng bộ.
    let hasPendingOfflineEvents: Bool
}

struct LogoutResponse: Decodable {
    let message: String?
}
