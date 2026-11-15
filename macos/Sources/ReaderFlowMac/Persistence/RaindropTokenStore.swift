import Foundation
import Security

/// Holds the user's own Raindrop client secret for personal mode, in the
/// Keychain only — never UserDefaults, logs, or the repository.
struct RaindropClientSecretStore {
    private let service = "com.readerflow.mac.raindrop"
    private let account = "raindrop-client-secret"

    func save(_ secret: String) throws {
        SecItemDelete(query() as CFDictionary)
        var add = query()
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw RaindropTokenStore.KeychainError.unhandled(status) }
    }

    func load() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clear() { SecItemDelete(query() as CFDictionary) }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// Stores the Raindrop OAuth token pair in the login Keychain. The token
/// belongs in OS secure storage, never in source control, logs, or phone-sync
/// payloads, so this is the only place a Raindrop token
/// is written to disk, and it is never included in Nearby Sync transfers.
struct RaindropTokenStore {
    struct StoredToken: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    enum KeychainError: Error {
        case unhandled(OSStatus)
    }

    private let service = "com.readerflow.mac.raindrop"
    private let account = "raindrop-oauth"

    func save(_ token: StoredToken) throws {
        let data = try JSONEncoder().encode(token)
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func load() -> StoredToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
