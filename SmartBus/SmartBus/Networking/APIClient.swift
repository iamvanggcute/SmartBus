//
//  APIClient.swift
//  SmartBus
//
//  Gọi REST backend SafeBus: gắn Bearer token, encode/decode snake_case,
//  bóc envelope `data`, đổi lỗi server thành `APIError.server(ServerError)`.
//

import Foundation

extension Notification.Name {
    /// Phát khi API có xác thực trả 401 (TOKEN_EXPIRED / TOKEN_REVOKED / UNAUTHORIZED).
    /// `object` là `ServerError`. AppRouter nghe để đưa người dùng về màn đăng nhập.
    static let sessionDidExpire = Notification.Name("SmartBus.sessionDidExpire")
}

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// Lấy access token hiện tại. Mặc định đọc từ SessionManager.
    var tokenProvider: () -> String? = { SessionManager.shared.accessToken }

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    /// Gửi request và trả về phần `data` của envelope.
    func send<Response: Decodable>(_ endpoint: Endpoint, as type: Response.Type = Response.self) async throws -> Response {
        let request = try makeRequest(for: endpoint)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try decoder.decode(APIEnvelope<Response>.self, from: data).data
            } catch {
                #if DEBUG
                print("[APIClient] Decode lỗi \(endpoint.path): \(error)")
                #endif
                throw APIError.decodingError
            }
        }

        let serverError = makeServerError(from: data, response: http)
        if http.statusCode == 401 && endpoint.requiresAuth {
            NotificationCenter.default.post(name: .sessionDidExpire, object: serverError)
        }
        throw APIError.server(serverError)
    }

    // MARK: - Private

    private func makeRequest(for endpoint: Endpoint) throws -> URLRequest {
        let url = APIConfig.baseURL.appendingPathComponent(endpoint.path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let finalURL = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: finalURL, timeoutInterval: APIConfig.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = endpoint.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        if endpoint.requiresAuth, let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeServerError(from data: Data, response: HTTPURLResponse) -> ServerError {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        return ServerError(
            status: response.statusCode,
            code: envelope?.error.code ?? "HTTP_\(response.statusCode)",
            message: envelope?.error.message ?? "Máy chủ trả lỗi (\(response.statusCode)). Vui lòng thử lại.",
            details: envelope?.error.details ?? [],
            retryAfterSeconds: retryAfter
        )
    }
}
