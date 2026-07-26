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

    /// Real-device bug (found while investigating "重複アカウントは統合された
    /// のに資格情報が無い" — `docs/icloud-sync.md`'s "資格情報消失バグ"): commit
    /// `52df393` ("use com.mtkg as the bundle identifier prefix
    /// everywhere") changed this type's *default* `service` parameter from
    /// `"com.m-tkg.otegami.account-password"` to
    /// `"com.mtkg.otegami.account-password"`. That default is a plain
    /// Swift string literal compiled into this file — completely
    /// independent of `PRODUCT_BUNDLE_IDENTIFIER`/`Local.xcconfig`'s own
    /// `com.mtkg.*` override (which is what the commit message's "the
    /// actual signed builds have always used com.mtkg.*" refers to, and
    /// which never changed). So every password this store had ever written
    /// before that commit — on every real device, regardless of its actual
    /// bundle id — is filed under the *old* service string, and every
    /// build compiled from a checkout at or after that commit looks it up
    /// under a *different* one. `kSecAttrService` is part of a generic
    /// password item's identity for `SecItemCopyMatching`, not a freely
    /// re-queryable label, so this is a silent, total split: `password(
    /// forAccountId:)` under the new service name returns
    /// `errSecItemNotFound` for every account whose password predates the
    /// rename, indistinguishable from "no password was ever stored" —
    /// exactly the "資格情報がありません" symptom, and (because
    /// `AccountDuplicateMerger`'s survivor pick is driven by
    /// `AccountRecord.needsReauth`, which `AppEnvironment.auth(for:)` sets
    /// the moment a lookup like this comes up empty) the same failure that
    /// made a real device's duplicate-account merge (`docs/icloud-sync.md`)
    /// keep the *wrong* side of a duplicate the very next time it launched
    /// after picking up this rename.
    ///
    /// `password(forAccountId:)` below falls back to checking every string
    /// in `legacyServices` when the current `service` misses, and — same
    /// lazy-migration shape as `migrateToSynchronizableAndWrite` already
    /// uses for the "pre-M11, not yet synchronizable" case — rewrites the
    /// item under the current `service` (and deletes the legacy copy) the
    /// moment it's found, so a device that already lost visibility into an
    /// old password recovers it automatically on the very next successful
    /// lookup, no re-entered password required. New entries here should
    /// only ever happen if this `service` string itself is ever renamed
    /// again — append, never remove, so an item from an even-older rename
    /// still round-trips.
    private static let legacyServices = ["com.m-tkg.otegami.account-password"]

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

    init(service: String = "com.mtkg.otegami.account-password", accessGroup: String? = nil) {
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
            // No item under the *current* `service` — this account might
            // still have one sitting under a `legacyServices` name (this
            // lookup, unlike `password(forAccountId:)`, only ever checked
            // `service`). Writing the new password under the current
            // service either way is correct (it's what every future lookup
            // will find first), so any legacy leftover is now purely
            // redundant — clean it up best-effort rather than leaving a
            // stale duplicate nothing will ever query again.
            try addSynchronizable(data, accountId: accountId)
            for legacyService in Self.legacyServices {
                _ = SecItemDelete(Self.anySynchronizableQuery(baseQuery(service: legacyService, accountId: accountId)) as CFDictionary)
            }
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
        if let data = try data(service: service, accountId: accountId) {
            return String(data: data, encoding: .utf8)
        }
        // See `legacyServices`' doc comment: an item written before a past
        // `service` rename is otherwise permanently invisible to every
        // query above, even though it's still sitting in the Keychain.
        for legacyService in Self.legacyServices {
            guard let data = try data(service: legacyService, accountId: accountId) else { continue }
            // Best-effort: migrating forward is a nice-to-have (avoids
            // paying this fallback lookup again next time), not something
            // this read should fail over — the password found under the
            // legacy service is still returned below even if the rewrite
            // itself fails for some reason.
            try? migrateLegacyItem(data: data, fromService: legacyService, accountId: accountId)
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// UITest-only escape hatch (mirrors `MessageView
    /// .deleteCredentialIfUITestRequested`'s `OTEGAMI_UITEST_*` launch-
    /// environment pattern — `AppEnvironment.init()`'s
    /// `OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE` hook is
    /// the caller): moves `accountId`'s password from the *current*
    /// `service` onto the first `legacyServices` entry, reproducing exactly
    /// the state a real device was left in by the `52df393` rename (a
    /// password only findable under the old service string). Lets
    /// `OtegamiCredentialRecoveryUITests` set that state up on demand and
    /// then assert this store's own `password(forAccountId:)` fallback
    /// recovers it, instead of needing an actual pre-rename build to
    /// reproduce against. No-op if this account has no password under the
    /// current service right now.
    func relocateToLegacyServiceForUITesting(accountId: String) {
        guard let legacyService = Self.legacyServices.first,
              let data = try? data(service: service, accountId: accountId)
        else { return }
        _ = SecItemDelete(Self.anySynchronizableQuery(baseQuery(accountId: accountId)) as CFDictionary)
        var attributes = baseQuery(service: legacyService, accountId: accountId)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = true
        _ = SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Every `accountId` this store currently holds a `.password` credential
    /// under — scanned across the current `service` and every
    /// `legacyServices` entry (an item can still be sitting under a legacy
    /// service if it was never looked up via `password(forAccountId:)`
    /// since the rename, which only migrates lazily on read). Used by
    /// `AppEnvironment`'s duplicate-account-merge rescue
    /// (`docs/icloud-sync.md`'s "資格情報消失バグ") to find an **orphaned**
    /// item — one whose accountId no longer matches any `AccountRecord` row
    /// at all, i.e. it survived under the id of an account this device
    /// already deleted (most concretely: the losing side of a duplicate-
    /// account merge, back when the merge picked the wrong survivor and/or
    /// `CloudAccountDirectory.cleanupAfterDuplicateMerge`'s own delete never
    /// got to run before the app was terminated) — by diffing the result
    /// against the live account id set. Read-only; never mutates anything.
    func allStoredAccountIds() -> Set<String> {
        var result: Set<String> = []
        for candidateService in [service] + Self.legacyServices {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidateService,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            var matches: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &matches)
            guard status == errSecSuccess, let items = matches as? [[String: Any]] else { continue }
            for item in items {
                if let accountId = item[kSecAttrAccount as String] as? String {
                    result.insert(accountId)
                }
            }
        }
        return result
    }

    /// Moves a password from `orphanAccountId` onto `accountId` — the
    /// rescue counterpart to `allStoredAccountIds()` above: once an orphaned
    /// item (an accountId no live `AccountRecord` references anymore) has
    /// been identified, this is what actually reassigns it to the account
    /// that needs it, as a fresh synchronizable item under the *current*
    /// service (mirrors `addSynchronizable`), then deletes the source item
    /// under every service name (current + legacy — wherever it happened to
    /// still be). Refuses to clobber an existing credential: if `accountId`
    /// already has a password, this is a no-op that returns `false` — the
    /// safety net for "the user already re-entered the password manually
    /// via account edit before this fix shipped", so re-running this on a
    /// device that already recovered on its own never overwrites a
    /// perfectly good, freshly-entered password with a stale orphaned one.
    /// Returns whether an adoption actually happened.
    @discardableResult
    func adoptOrphanedPassword(fromAccountId orphanAccountId: String, toAccountId accountId: String) throws -> Bool {
        guard try password(forAccountId: accountId) == nil else { return false }
        guard let data = try orphanedData(accountId: orphanAccountId) else { return false }
        try addSynchronizable(data, accountId: accountId)
        for candidateService in [service] + Self.legacyServices {
            _ = SecItemDelete(Self.anySynchronizableQuery(baseQuery(service: candidateService, accountId: orphanAccountId)) as CFDictionary)
        }
        return true
    }

    private func orphanedData(accountId: String) throws -> Data? {
        if let data = try data(service: service, accountId: accountId) {
            return data
        }
        for legacyService in Self.legacyServices {
            if let data = try data(service: legacyService, accountId: accountId) {
                return data
            }
        }
        return nil
    }

    /// UITest-only escape hatch (mirrors `relocateToLegacyServiceForUITesting`
    /// just above, and the same `OTEGAMI_UITEST_*` launch-environment
    /// pattern) — reproduces the *other* shape of credential loss this app
    /// now recovers from: relocates `accountId`'s password onto a
    /// synthetic, unrelated `orphanAccountId` that matches no real
    /// `AccountRecord`, simulating a device that already went through a bad
    /// duplicate-account merge and was left with the real password
    /// stranded under the merged-away account's (now nonexistent) id. Lets
    /// `OtegamiCredentialRecoveryUITests` set that state up on demand and
    /// then assert `AppEnvironment.init()`'s orphan-adoption rescue finds
    /// and reassigns it back automatically. No-op if this account has no
    /// password under the current service right now.
    func relocateToOrphanAccountIdForUITesting(accountId: String, orphanAccountId: String) {
        guard let data = try? data(service: service, accountId: accountId) else { return }
        _ = SecItemDelete(Self.anySynchronizableQuery(baseQuery(accountId: accountId)) as CFDictionary)
        var attributes = baseQuery(accountId: orphanAccountId)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = true
        _ = SecItemAdd(attributes as CFDictionary, nil)
    }

    private func data(service: String, accountId: String) throws -> Data? {
        var query = Self.anySynchronizableQuery(baseQuery(service: service, accountId: accountId))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return result as? Data
    }

    /// Rewrites a password found under an old `service` string onto the
    /// current one (as a fresh, synchronizable item — mirrors
    /// `addSynchronizable`) and removes the legacy copy, so the account
    /// converges onto a single up-to-date Keychain item instead of leaving
    /// a stale duplicate behind under a service name nothing will ever
    /// query again.
    private func migrateLegacyItem(data: Data, fromService legacyService: String, accountId: String) throws {
        try addSynchronizable(data, accountId: accountId)
        _ = SecItemDelete(Self.anySynchronizableQuery(baseQuery(service: legacyService, accountId: accountId)) as CFDictionary)
    }

    func deletePassword(forAccountId accountId: String) throws {
        var lastError: KeychainError?
        for candidateService in [service] + Self.legacyServices {
            let status = SecItemDelete(Self.anySynchronizableQuery(baseQuery(service: candidateService, accountId: accountId)) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                lastError = .unexpectedStatus(status)
                continue
            }
        }
        if let lastError { throw lastError }
    }

    private func baseQuery(accountId: String) -> [String: Any] {
        baseQuery(service: service, accountId: accountId)
    }

    private func baseQuery(service: String, accountId: String) -> [String: Any] {
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
