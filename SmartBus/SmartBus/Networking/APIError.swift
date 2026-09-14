import Foundation

enum APIError: Error {
    case invalidURL
    case invalidResponse
    case noData
    case decodingError
}

