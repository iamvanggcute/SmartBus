//
//  SessionManager.swift
//  SmartBus
//
//  Giữ phiên đăng nhập: JWT, thời điểm hết hạn và thông tin người dùng, lưu trong Keychain.
//

import Foundation

final class SessionManager {
    static let shared = SessionManager()

    private enum Key {
        static let accessToken = "access_token"
        static let expiresAt = "expires_at"
        static let user = "user"
    }

    private let keychain: KeychainStore
    private let lock = NSLock()
    private var cachedUser: AppUser?

    init(keychain: KeychainStore = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "SmartBus").session")) {
        self.keychain = keychain
        if let data = keychain.data(for: Key.user) {
            cachedUser = try? JSONDecoder().decode(AppUser.self, from: data)
        }
    }

    var accessToken: String? {
        keychain.string(for: Key.accessToken)
    }

    var currentUser: AppUser? {
        lock.lock(); defer { lock.unlock() }
        return cachedUser
    }

    var expiresAt: Date? {
        guard let raw = keychain.string(for: Key.expiresAt), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Có token còn hạn và có thông tin người dùng.
    var hasValidSession: Bool {
        guard accessToken != nil, currentUser != nil, let expiresAt else { return false }
        return expiresAt > Date()
    }

    func save(_ login: LoginResponse) {
        keychain.set(login.accessToken, for: Key.accessToken)
        let expiry = Date().addingTimeInterval(TimeInterval(login.expiresIn))
        keychain.set(String(expiry.timeIntervalSince1970), for: Key.expiresAt)
        update(user: login.user)
    }

    func update(user: AppUser) {
        if let data = try? JSONEncoder().encode(user) {
            keychain.set(data, for: Key.user)
        }
        lock.lock(); cachedUser = user; lock.unlock()
    }

    /// Xóa token và thông tin người dùng.
    /// KHÔNG xóa hàng đợi offline của phụ xe (US01 AC4): outbox nằm ở SQLite, do module khác quản lý.
    func clear() {
        keychain.remove(Key.accessToken)
        keychain.remove(Key.expiresAt)
        keychain.remove(Key.user)
        lock.lock(); cachedUser = nil; lock.unlock()
    }
}
