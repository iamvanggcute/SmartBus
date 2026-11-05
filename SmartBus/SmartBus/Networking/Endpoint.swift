//
//  Endpoint.swift
//  SmartBus
//

import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

/// Mô tả một request tới backend SafeBus.
struct Endpoint {
    /// Đường dẫn sau `/api/v1`, không có dấu `/` ở đầu. Ví dụ: "auth/login".
    let path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: (any Encodable)? = nil
    /// `false` cho các API public (đăng nhập). Mặc định gửi kèm Bearer token.
    var requiresAuth: Bool = true
}
