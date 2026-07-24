import Foundation
import Security

/// Stores/retrieves account passwords in the Keychain, keyed by
/// `AccountRecord.id`. The `account` table itself only ever stores
/// `authType` (see `OtegamiStore.AccountRecord`'s doc comment) — this is
/// the one place the actual secret lives.
///
/// `kSecAttrAccessibleAfterFirstUnlock` (rather than
/// `.whenUnlocked`) so a background sync — BGAppRefresh, or a future push
/// relay wake (M9) — can read the password while the device is locked but
/// has been unlocked at least once since boot, which is the usual state for
/// a background task. Compatible with `kSecAttrSynchronizable` below — only
/// the `ThisDeviceOnly` accessibility constants (which this store never
/// uses) are mutually exclusive with iCloud Keychain sync.
///
/// iCloud sync (M11: `docs/icloud-sync.md`): every item this store writes
/// is marked `kSecAttrSynchronizable = true`, so it rides along on the same
/// iCloud Keychain the user already has enabled for every other app — this
/// store does nothing to *opt in* beyond setting the attribute; whether the
/// item actually syncs is entirely up to the user's system-level iCloud
/// Keychain toggle. Reads/deletes ask for `kSecAttrSynchronizableAny` (not
/// just `true`) so an item written before this change (synchronizable
/// unset, i.e. `false`) still round-trips: `setPassword` below lazily
/// rewrites any such item with the attribute the next time it's touched,
/// so a pre-M11 install converges to fully-synchronizable storage without
/// a one-time migration pass having to run anywhere.
struct KeychainCredentialStore: Sendable {
    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
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
    /// M9: shares these Keychain items with the `NotificationService`
    /// Extension (`OTEGAMI_KEYCHAIN_GROUP`, `Config/Shared.xcconfig`) so it
    /// can look up a `.password`-auth account's IMAP password without the
    /// push payload ever carrying it. `nil` (the pre-M9 default) omits
    /// `kSecAttrAccessGroup` from every query entirely — that's not "no
    /// group", it's "whichever group SecItemAdd chooses by default for
    /// this process" (the app's own primary group when unspecified),
    /// functionally identical to before this existed for callers that
    /// never opt in (`swift test`, previews, or a build with no App Group
    /// entitlement configured).
    private let accessGroup: String?

    init(service: String = "com.m-tkg.otegami.account-password", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func setPassword(_ password: String, forAccountId accountId: String) throws {
        let data = Data(password.utf8)
        let lookupQuery = Self.anySynchronizableQuery(baseQuery(accountId: accountId))

        var existingAttributes: AnyObject?
        let existsStatus = SecItemCopyMatching(
            Self.returningAttributes(lookupQuery) as CFDictionary,
            &existingAttributes
        )

        switch existsStatus {
        case errSecSuccess:
            // A pre-existing item might be either kind — see this type's
            // doc comment on the lazy migration this branches into.
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

    /// Pre-M11 items were written with no `kSecAttrSynchronizable` at all
    /// (Keychain's default: non-synchronizable) — `SecItemUpdate` can't
    /// flip that attribute on an existing item in place (Apple documents
    /// this as unsupported; it's treated as part of the item's identity,
    /// not a freely-mutable attribute), so migrating means delete-then-
    /// recreate. The delete query deliberately omits
    /// `kSecAttrSynchronizable` (rather than reusing `anySynchronizableQuery`),
    /// so it only ever removes the specific non-synchronizable item
    /// `setPassword` just found — never a synchronizable item another
    /// device might have raced in concurrently.
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

    func password(forAccountId accountId: String) throws -> String? {
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

    func deletePassword(forAccountId accountId: String) throws {
        let status = SecItemDelete(Self.anySynchronizableQuery(baseQuery(accountId: accountId)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountId: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Widens a lookup/delete query to match an item regardless of whether
    /// it's synchronizable — omitting `kSecAttrSynchronizable` entirely (as
    /// `baseQuery` does) makes `SecItemCopyMatching`/`SecItemDelete` only
    /// match *non*-synchronizable items, which would silently stop finding
    /// anything written after M11. Pulled out as its own pure function
    /// (rather than inlined at each call site) so the query-construction
    /// logic itself — the one part of this Security-framework-backed type
    /// that's actually meaningful to look at in isolation — reads as a
    /// single well-named step; there's no `swift test`-reachable target for
    /// `apps/Otegami/Sources` to unit test it against, so this is verified
    /// by inspection plus the app-level verify scripts instead (see
    /// `docs/icloud-sync.md`).
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
