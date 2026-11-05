//
//  ImageLoader.swift
//  SmartBus
//
//  Tải ảnh chân dung học sinh (US07). `photo_url` là đường dẫn tương đối,
//  phải gửi kèm header Authorization. Ảnh được lưu trên máy để dùng khi mất mạng.
//

import UIKit
import CryptoKit

final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let folder: URL?

    init(session: URLSession = .shared) {
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        folder = caches?.appendingPathComponent("student-photos", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// `path` dạng "/api/v1/students/<id>/photo". Trả `nil` nếu chưa có ảnh hoặc lỗi.
    func image(for path: String) async -> UIImage? {
        let key = path as NSString
        if let cached = memory.object(forKey: key) { return cached }
        if let file = fileURL(for: path), let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key)
            return image
        }
        guard let url = absoluteURL(for: path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: APIConfig.timeout)
        if let token = SessionManager.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let result = try? await session.data(for: request) else { return nil }
        let (data, response) = result
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        if let file = fileURL(for: path) { try? data.write(to: file, options: .atomic) }
        return image
    }

    /// Tải trước ảnh khi mở chuyến; ảnh lỗi thì bỏ qua (05 §6).
    func prefetch(paths: [String]) {
        Task.detached(priority: .utility) { [weak self] in
            for path in paths {
                _ = await self?.image(for: path)
            }
        }
    }

    private func absoluteURL(for path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        // baseURL là ".../api/v1"; photo_url đã có sẵn "/api/v1/…".
        guard var components = URLComponents(url: APIConfig.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        return components.url
    }

    private func fileURL(for path: String) -> URL? {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest + ".jpg")
    }
}
