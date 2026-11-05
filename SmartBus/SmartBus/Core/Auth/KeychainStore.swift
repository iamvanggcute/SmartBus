//
//  KeychainStore.swift
//  SmartBus
//
//  Lưu dữ liệu nhạy cảm (JWT) trong iOS Keychain theo US01 AC4.
//

import Foundation
import Security

struct KeychainStore {
    let service: String

    /// Đọc được sau lần mở khóa máy đầu tiên, để GPS nền vẫn gửi được khi màn hình khóa.
    private let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    @discardableResult
    func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ string: String, for key: String) -> Bool {
        set(Data(string.utf8), for: key)
    }

    func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
