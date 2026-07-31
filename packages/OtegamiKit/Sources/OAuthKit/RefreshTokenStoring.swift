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
/// always uses `KeychainRefreshTokenStore` (each provider's `TokenStore`
/// default — see that type's own doc comment for why `service` has no
/// default *here*).
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
///
/// iCloud sync (M11): marked `kSecAttrSynchronizable` on write, and
/// queried/deleted with `kSecAttrSynchronizableAny` plus the same lazy
/// delete-then-recreate migration for a pre-M11, non-synchronizable item —
/// see `KeychainCredentialStore`'s doc comment for the full rationale
/// (identical here; refresh tokens are exactly as sensitive/portable as an
/// IMAP password, and Gmail/Microsoft accounts benefit from the same "add on
/// iOS, appear ready-to-sync on macOS" experience).
///
/// `service` has **no default value** here (unlike the pre-consolidation
/// `GoogleOAuth`/`MicrosoftOAuth` copies of this type, which each defaulted
/// to their own hardcoded Keychain service string). Now that this one type
/// is shared between both providers, a single default would mean one of
/// them silently uses the *other's* Keychain items — each provider's
/// `TokenStore.init` supplies its own service string explicitly instead
/// (`"com.mtkg.otegami.oauth-refresh-token"` for Google,
/// `"com.mtkg.otegami.oauth-refresh-token.microsoft"` for Microsoft — both
/// values unchanged from before this consolidation, so existing Keychain
/// items keep resolving and no user is forced to re-authenticate).
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

    public init(service: String) {
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

    /// See `KeychainCredentialStore.migrateToSynchronizableAndWrite`'s doc
    /// comment — identical delete-then-recreate rationale.
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

    /// See `KeychainCredentialStore.anySynchronizableQuery`'s doc comment.
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
