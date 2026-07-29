import AccountCloudSync
import Foundation
import GoogleOAuth
import MailTransport
import MicrosoftOAuth
import OtegamiRelayAPI
import OtegamiStore
import PushRelayClient
import SyncEngine

/// The app's `LocalAccountDirectory` conformance: bridges
/// `AccountCloudSyncEngine`'s plain data operations to the real GRDB
/// database, Keychain, `SyncCoordinator`, and push-watch registration.
///
/// Deliberately holds direct references to `syncCoordinator`/`pushSettings`/
/// `pushRelayClient` (each already `Sendable` — `SyncCoordinator`/
/// `PushRelayClient` are actors, `PushSettingsStore` is `@unchecked
/// Sendable`) and does the "start the first sync"/"register or tear down a
/// push watch" work *inside* `insertFromCloud`/`deleteLocally` themselves,
/// rather than reporting back to `AppEnvironment` via callback closures for
/// it to do afterward. The alternative — closures capturing `AppEnvironment`
/// (a `@MainActor` class, not `Sendable`) — would need those closures
/// themselves to only ever be *bound method references* (the one shape
/// Swift lets a global-actor-isolated method cross into a `@Sendable`
/// closure type as), which is a much easier invariant to violate by
/// accident later than "this type only depends on already-`Sendable`
/// pieces". The small duplication against `AppEnvironment.registerWatch`/
/// `.unregisterWatch`/`.deleteAccount` this causes is intentional — see
/// each method's doc comment below for exactly what it mirrors.
struct CloudAccountDirectory: LocalAccountDirectory, @unchecked Sendable {
    let database: AppDatabase
    let credentialStore: KeychainCredentialStore
    let tokenStore: GoogleOAuth.TokenStore?
    /// Task #116 第2段: Microsoft's counterpart to `tokenStore` above — see
    /// `AppEnvironment.microsoftTokenStore`'s doc comment on why a build can
    /// have either, both, or neither provider's `TokenStore` non-`nil`.
    let microsoftTokenStore: MicrosoftOAuth.TokenStore?
    let syncCoordinator: SyncCoordinator
    let pushSettings: PushSettingsStore
    let pushRelayClient: PushRelayClient

    func allAccountSnapshots() async -> [CloudAccountSnapshot] {
        let accounts = (try? await database.dbWriter.read { db in try AccountRecord.fetchAll(db) }) ?? []
        return accounts.map(CloudAccountSnapshot.init(account:))
    }

    /// `authType` alone doesn't say *which* OAuth provider's `TokenStore`
    /// to check for an `.oauth2` account — `AccountCloudSyncEngine` only
    /// ever calls this against a `CloudAccountSnapshot` it already has
    /// `kind` for (`allAccountSnapshots()`/`insertFromCloud`'s `snapshot`
    /// parameter both carry it), so this takes `kind` as a separate
    /// parameter rather than looking it up again.
    func hasCredential(accountId: String, authType: AccountAuthType, kind: AccountKind) async -> Bool {
        switch authType {
        case .password:
            return ((try? credentialStore.password(forAccountId: accountId)) ?? nil) != nil
        case .oauth2:
            switch kind {
            case .gmail:
                guard let tokenStore else { return false }
                return await tokenStore.hasStoredRefreshToken(for: accountId)
            case .microsoft:
                guard let microsoftTokenStore else { return false }
                return await microsoftTokenStore.hasStoredRefreshToken(for: accountId)
            case .generic, .icloud:
                return false
            }
        }
    }

    /// A cloud-only account was found — insert it locally with
    /// `needsReauth` reflecting whether a usable credential already exists
    /// on this device (Keychain sync may simply not have caught up yet;
    /// `AccountsSettingsView` shows a distinct banner for that case — see
    /// `AccountRecord.needsReauth`'s doc comment). If a credential *is*
    /// already here, mirrors `AccountSetupView.saveAccount`'s "insert, then
    /// kick off the first sync and register a push watch" tail.
    func insertFromCloud(_ snapshot: CloudAccountSnapshot, hasCredential: Bool) async {
        var mutableAccount = snapshot.makeAccountRecord()
        mutableAccount.needsReauth = !hasCredential
        let account = mutableAccount
        guard (try? await database.dbWriter.write { db in try account.insert(db) }) != nil else { return }

        guard hasCredential, let auth = await resolveAuth(for: account) else { return }
        let coordinator = syncCoordinator
        Task {
            _ = try? await coordinator.syncAccount(account, auth: auth)
        }
        await registerWatchIfNeeded(for: account)
    }

    /// Cloud won a last-writer-wins conflict — overwrite the local row's
    /// synced metadata. Never touches Keychain/`TokenStore`/the sync
    /// scheduler: only `AccountRecord`'s own columns changed, not what
    /// credential to use or whether a sync is in flight.
    func updateFromCloud(_ snapshot: CloudAccountSnapshot) async {
        try? await database.dbWriter.write { db in
            guard var row = try AccountRecord.fetchOne(db, key: snapshot.accountId) else { return }
            snapshot.apply(to: &row)
            try row.update(db)
        }
    }

    /// A tombstone said this account was deleted on another device — the
    /// exact same local wipe `AppEnvironment.deleteAccount` does (stop
    /// `IDLE`, delete the Keychain item, tear down the push watch, cascade
    /// the DB row), just reached from a reconcile pass instead of a user
    /// tapping "削除". Must **not** push a new tombstone (unlike
    /// `AppEnvironment.deleteAccount`) — the tombstone that triggered this
    /// call already *is* the record of the deletion; pushing another would
    /// just rewrite the same entry with a slightly later `deletedAt`.
    func deleteLocally(accountId: String) async {
        guard let account = try? await database.dbWriter.read({ db in try AccountRecord.fetchOne(db, key: accountId) })
        else { return }

        await syncCoordinator.stopIdleLoop(for: account)
        try? credentialStore.deletePassword(forAccountId: accountId)
        // Task #116 第2段: cleared unconditionally from *both* provider
        // token stores rather than branching on `account.kind` — a
        // `clearTokens` call against a store that never held this
        // `accountId` is a harmless no-op (mirrors `KeychainCredentialStore
        // .deletePassword`'s existing "delete, tolerate not-found" shape),
        // so there's no need to duplicate the `kind` branch `auth(for:)`
        // already has just to skip one no-op call.
        if let tokenStore {
            try? await tokenStore.clearTokens(for: accountId)
        }
        if let microsoftTokenStore {
            try? await microsoftTokenStore.clearTokens(for: accountId)
        }
        await unregisterWatch(forAccountId: accountId)
        try? await database.dbWriter.write { db in
            // Mirrors `AppEnvironment.deleteAccount`'s FTS cleanup — see
            // its doc comment for why this can't just rely on the
            // cascading foreign keys the rest of the delete gets for free.
            let messageIds = try Int64.fetchAll(
                db,
                sql: """
                    SELECT message.id FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE mailbox.accountId = ?
                    """,
                arguments: [accountId]
            )
            try FTSIndexer.deleteAll(messageIds: messageIds, db: db)
            _ = try account.delete(db)
        }
    }

    /// Post-merge cleanup for an account id `AccountDuplicateMerger` already
    /// removed from the database (`AppEnvironment.init()`'s duplicate-
    /// account migration, `docs/icloud-sync.md`'s "重複挿入バグ"). Unlike
    /// `deleteLocally`, this doesn't require the `account` row to still
    /// exist — it doesn't, the merger already deleted it after repointing/
    /// merging everything it owned into the surviving account — so it only
    /// tears down the per-*device* state a since-deleted id might still be
    /// holding: a cached `AccountSyncer`/`IDLE` loop, a Keychain password,
    /// stored OAuth tokens, and a registered push watch. Deliberately never
    /// pushes a tombstone (unlike `AppEnvironment.deleteAccount`, and
    /// unlike `deleteLocally` reacting to one) — this isn't a user-initiated
    /// deletion that should propagate to other devices, it's this device
    /// privately tidying up after a merge it alone decided to make; another
    /// device may still legitimately have this exact id as its own live,
    /// unmerged account.
    func cleanupAfterDuplicateMerge(accountId: String) async {
        await syncCoordinator.invalidateSyncer(for: accountId)
        try? credentialStore.deletePassword(forAccountId: accountId)
        // See `deleteLocally`'s identical comment on why both stores are
        // cleared unconditionally.
        if let tokenStore {
            try? await tokenStore.clearTokens(for: accountId)
        }
        if let microsoftTokenStore {
            try? await microsoftTokenStore.clearTokens(for: accountId)
        }
        await unregisterWatch(forAccountId: accountId)
    }

    /// A minimal echo of `AppEnvironment.auth(for:)` — doesn't set
    /// `needsReauth` on a `.reauthenticationRequired` failure (unlike that
    /// method) since this only ever runs immediately after
    /// `insertFromCloud` already decided a credential exists; a
    /// `TokenStore` refresh failing at that exact moment is rare enough,
    /// and low-stakes enough (the very next real sync attempt goes through
    /// `AppEnvironment.auth(for:)` and sets the banner correctly then), not
    /// to justify duplicating that bookkeeping here too.
    private func resolveAuth(for account: AccountRecord) async -> MailAuth? {
        switch account.authType {
        case .password:
            guard let password = (try? credentialStore.password(forAccountId: account.id)) ?? nil else { return nil }
            return .password(username: account.imapUsername, password: password)
        case .oauth2:
            // See `AppEnvironment.auth(for:)`'s identical `kind` branch.
            switch account.kind {
            case .gmail:
                guard let tokenStore, let accessToken = try? await tokenStore.accessToken(for: account.id) else { return nil }
                return .xoauth2(username: account.imapUsername, accessToken: accessToken)
            case .microsoft:
                guard let microsoftTokenStore, let accessToken = try? await microsoftTokenStore.accessToken(for: account.id) else { return nil }
                return .xoauth2(username: account.imapUsername, accessToken: accessToken)
            case .generic, .icloud:
                return nil
            }
        }
    }

    /// Mirrors `AppEnvironment.registerWatch(for:baseURL:deviceSecret:)` +
    /// its `registerWatchIfNeeded` guard — see this type's doc comment on
    /// why this is a deliberate duplication rather than a shared callback.
    private func registerWatchIfNeeded(for account: AccountRecord) async {
        guard pushSettings.isEnabled, account.authType == .password else { return }
        guard pushSettings.accountWatchMap[account.id] == nil else { return }
        guard let relayURLString = pushSettings.relayURLString,
              let baseURL = AppEnvironment.validatedRelayURL(relayURLString),
              let deviceSecret = try? pushSettings.deviceSecret(),
              let password = (try? credentialStore.password(forAccountId: account.id)) ?? nil
        else { return }

        let request = CreateWatchRequest(
            accountId: account.id,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapUseTLS: account.imapSecurity != .plain,
            imapUsername: account.imapUsername,
            auth: WatchAuth(secret: password),
            mailbox: "INBOX"
        )
        guard let response = try? await pushRelayClient.createWatch(baseURL: baseURL, deviceSecret: deviceSecret, request: request) else {
            return
        }
        pushSettings.setWatchId(response.watchId, forAccountId: account.id)
    }

    /// Mirrors `AppEnvironment.unregisterWatch(forAccountId:)` — see this
    /// type's doc comment.
    private func unregisterWatch(forAccountId accountId: String) async {
        guard let watchId = pushSettings.accountWatchMap[accountId] else { return }
        defer { pushSettings.setWatchId(nil, forAccountId: accountId) }
        guard let relayURLString = pushSettings.relayURLString,
              let baseURL = AppEnvironment.validatedRelayURL(relayURLString),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
    }
}
