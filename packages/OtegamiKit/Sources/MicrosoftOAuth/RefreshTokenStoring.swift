import Foundation
import Security

/// Mirrors `GoogleOAuth.RefreshTokenStoring`/`KeychainRefreshTokenStore` —
/// see that type's doc comment for the full rationale (identical here: a
/// narrow protocol so tests can inject an in-memory fake instead of the
/// real Keychain).
public protocol RefreshTokenStoring: Sendable {
    func write(_ refreshToken: String, accountId: String) throws
    func read(accountId: String) throws -> String?
    func delete(accountId: String) throws
}

/// `kSecClassGenericPassword` Keychain storage for Microsoft OAuth refresh
/// tokens. Uses a **different `service` string than `GoogleOAuth
/// .KeychainRefreshTokenStore`** (`...oauth-refresh-token.microsoft` vs.
/// `...oauth-refresh-token`) — not strictly required for correctness (both
/// stores key entries by `accountId`, and every `AccountRecord.id` is a
/// fresh UUID, so a Gmail and a Microsoft account could never collide on
/// the same key even sharing one service string), but keeping the two
/// providers' Keychain items visibly distinct is cheap insurance and makes
/// the Keychain contents easier to reason about if anyone ever inspects
/// them directly (e.g. via `security dump-keychain`). Same
/// `kSecAttrAccessibleAfterFirstUnlock`/`kSecAttrSynchronizable` iCloud
/// Keychain sync story as `GoogleOAuth`'s copy — see that type's doc
/// comment for the full accessibility-class rationale.
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

    public init(service: String = "com.mtkg.otegami.oauth-refresh-token.microsoft") {
        self.service = service
    }

    public func write(_ refreshToken: String, accountId: String) throws {
        let data = Data(refreshToken.utf8)
        let lookupQuery = Self.anySynchronizableQuery(baseQuery(accountId: accountId))

        var existingAttributes: AnyObject?
        let existsStatus = SecItemCopyMatching(
            Self.returningAttributes(lookupQuery) as CFDictionary,
            &existingAttributes
        )

        switch existsStatus {
        case errSecSuccess:
            let isSynchronizable = (existingAttributes as? [String: Any])?[kSecAttrSynchronizable as String] as? Bool ?? false
            if isSynchronizable {
                let status = SecItemUpdate(lookupQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            } else {
                try migrateToSynchronizableAndWrite(data, accountId: accountId)
            }
        case errSecItemNotFound:
            try addSynchronizable(data, accountId: accountId)
        default:
            throw KeychainError.unexpectedStatus(existsStatus)
        }
    }

    private func migrateToSynchronizableAndWrite(_ data: Data, accountId: String) throws {
        _ = SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
        try addSynchronizable(data, accountId: accountId)
    }

    private func addSynchronizable(_ data: Data, accountId: String) throws {
        var attributes = baseQuery(accountId: accountId)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = true
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func read(accountId: String) throws -> String? {
        var query = Self.anySynchronizableQuery(baseQuery(accountId: accountId))
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
        let status = SecItemDelete(Self.anySynchronizableQuery(baseQuery(accountId: accountId)) as CFDictionary)
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

    private static func anySynchronizableQuery(_ query: [String: Any]) -> [String: Any] {
        var query = query
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    private static func returningAttributes(_ query: [String: Any]) -> [String: Any] {
        var query = query
        query[kSecReturnAttributes as String] = true
        return query
    }
}
