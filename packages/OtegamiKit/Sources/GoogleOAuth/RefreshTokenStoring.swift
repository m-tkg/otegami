import Foundation
import Security

/// Persists the one long-lived secret `TokenStore` needs to keep on disk
/// (the OAuth refresh token), keyed by account id. Split out from
/// `TokenStore` itself — which only ever talks to this narrow protocol —
/// so `TokenStoreTests` can inject an in-memory fake instead of hitting the
/// real macOS/iOS Keychain: an unsigned `swift test` binary has no
/// guaranteed Keychain access group, so exercising the real
/// `KeychainRefreshTokenStore` from an automated test could hang on a
/// permission prompt or fail non-deterministically in CI. Production code
/// always uses `KeychainRefreshTokenStore` (`TokenStore`'s default).
public protocol RefreshTokenStoring: Sendable {
    func write(_ refreshToken: String, accountId: String) throws
    func read(accountId: String) throws -> String?
    func delete(accountId: String) throws
}

/// `kSecClassGenericPassword` Keychain storage for OAuth refresh tokens.
/// `kSecAttrAccessibleAfterFirstUnlock` — same accessibility class
/// `KeychainCredentialStore` (the app's IMAP/SMTP password store) uses, and
/// for the same reason: a background sync or a future push-relay wake
/// (M9) needs to read this while the device is locked but has been
/// unlocked at least once since boot.
public struct KeychainRefreshTokenStore: RefreshTokenStoring {
    public enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String? {
                    "Keychain error \(status): \(message)"
                } else {
                    "Keychain error \(status)"
                }
            }
        }
    }

    private let service: String

    public init(service: String = "com.m-tkg.otegami.oauth-refresh-token") {
        self.service = service
    }

    public func write(_ refreshToken: String, accountId: String) throws {
        let data = Data(refreshToken.utf8)
        let query = baseQuery(accountId: accountId)

        let existsStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existsStatus {
        case errSecSuccess:
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        default:
            throw KeychainError.unexpectedStatus(existsStatus)
        }
    }

    public func read(accountId: String) throws -> String? {
        var query = baseQuery(accountId: accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(accountId: String) throws {
        let status = SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
    }
}
