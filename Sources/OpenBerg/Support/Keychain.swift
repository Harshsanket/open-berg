import Foundation

/// Credentials live in one login-keychain item, so a boot reads the keychain
/// exactly once instead of once per value — fewer round trips, and only one
/// item whose access-control list can ever ask for permission.
///
/// Not a secret store for anything else: no API key, refresh token or access
/// token ever leaves the keychain for UserDefaults, files or logs.
enum Keychain {
    private static let service = "com.openberg.OpenBerg"
    private static let account = "credentials"

    struct Credentials: Codable {
        var apiKey: String
        var refreshToken: String
        var accessToken: String?
        /// Seconds since 1970; the token minted at this moment.
        var accessTokenExpiry: Double?
    }

    static func load() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    @discardableResult
    static func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create.merge(attributes) { _, new in new }
            return SecItemAdd(create as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Called when the account's credentials are replaced or forgotten.
    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
