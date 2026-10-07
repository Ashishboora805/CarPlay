import Foundation
import Security

/// Generic-password Keychain wrapper for secrets: playlist/EPG URLs (which often embed
/// credentials), HTTP Basic credentials and the user's YouTube API key.
///
/// Items use `AfterFirstUnlockThisDeviceOnly` so CarPlay can start playback while the phone
/// is locked in a cradle, but secrets never migrate to other devices via backups.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "app.lumen.secrets") {
        self.service = service
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ data: Data, for key: String) -> Bool {
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func set(_ string: String, for key: String) -> Bool {
        set(Data(string.utf8), for: key)
    }

    func value<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    @discardableResult
    func set<T: Encodable>(value: T, for key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return set(data, for: key)
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

extension KeychainStore {
    enum Keys {
        static let youtubeAPIKey = "youtube.apiKey"
        static func source(_ id: UUID) -> String { "source.\(id.uuidString)" }
    }
}
