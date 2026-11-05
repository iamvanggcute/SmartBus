//
//  APIError.swift
//  SmartBus
//

import Foundation

/// Lỗi chi tiết theo trường trong `error.details` của backend.
/// Có thể là `{ field, message }` (lỗi nhập liệu) hoặc `{ reason }` (lỗi nghiệp vụ).
struct ErrorDetail: Decodable, Equatable {
    let field: String?
    let message: String?
    let reason: String?
}

/// Lỗi nghiệp vụ backend trả về: `{ success: false, error: { code, message, details } }`.
/// Hiển thị `message` (tiếng Việt), rẽ nhánh theo `code` (04 §1.4, §15).
struct ServerError: Error, Equatable {
    let status: Int
    let code: String
    let message: String
    let details: [ErrorDetail]
    /// Giá trị header `Retry-After` (giây) khi `status == 429`.
    let retryAfterSeconds: Int?

    /// Thông báo lỗi của một trường nhập liệu (khi `code == "VALIDATION_ERROR"`).
    func message(forField field: String) -> String? {
        details.first { $0.field == field }?.message
    }
}

enum APIError: Error {
    case invalidURL
    case invalidResponse
    case noData
    case decodingError
    /// Không kết nối được máy chủ (mất mạng, timeout, sai địa chỉ…).
    case network(URLError)
    /// Máy chủ trả lỗi nghiệp vụ.
    case server(ServerError)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .server(let error):
            return error.message
        case .network:
            return "Không kết nối được máy chủ. Kiểm tra mạng rồi thử lại."
        case .invalidURL, .invalidResponse, .noData, .decodingError:
            return "Có lỗi khi xử lý phản hồi từ máy chủ."
        }
    }

    /// Mã lỗi nghiệp vụ, `nil` nếu không phải lỗi từ máy chủ.
    var serverCode: String? {
        if case .server(let error) = self { return error.code }
        return nil
    }
}
