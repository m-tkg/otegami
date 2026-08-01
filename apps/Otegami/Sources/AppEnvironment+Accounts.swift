import Foundation
import GoogleOAuth
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine
#if os(iOS)
import UserNotifications
#endif

@MainActor
extension AppEnvironment {
    /// The launch-time rescue for a device already left with an orphaned
    /// Keychain credential by a *previous* bad duplicate-account merge —
    /// see the two call sites in `init()` for the full picture (this is
    /// "part 2", the one that still helps on a later launch after the
    /// duplicate `account` rows themselves are long gone). `static` (not an
    /// instance method) and takes `database`/`credentialStore` as
    /// parameters rather than reading `self.database`/`self.credentialStore`
    /// because it runs from inside `init()` before `self` exists as a fully
    /// formed value — the exact same constraint the duplicate-merge block
    /// right above it in `init()` is already under.
    ///
    /// Deliberately conservative: only acts when there is exactly one
    /// `.password` account missing a working credential *and* exactly one
    /// Keychain item whose accountId matches no live account at all. Either
    /// count being 0 or ≥2 means this can't tell which orphan (if any)
    /// belongs to which account without guessing, so it does nothing and
    /// leaves the existing "パスワードを入力" flow (`AccountsSettingsView`) as
    /// the way out — silently reassigning the wrong password to the wrong
    /// account would be a far worse failure mode than leaving the banner up.
    @discardableResult
    static func adoptOrphanedCredentialIfUnambiguous(
        database: AppDatabase, credentialStore: KeychainCredentialStore
    ) -> String? {
        guard let accounts = try? database.dbWriter.read({ db in try AccountRecord.fetchAll(db) }) else { return nil }
        let knownAccountIds = Set(accounts.map(\.id))

        let needyAccounts = accounts.filter { account in
            account.authType == .password
                && ((try? credentialStore.password(forAccountId: account.id)) ?? nil) == nil
        }
        guard needyAccounts.count == 1, let needyAccount = needyAccounts.first else { return nil }

        let orphanAccountIds = credentialStore.allStoredAccountIds().subtracting(knownAccountIds)
        guard orphanAccountIds.count == 1, let orphanAccountId = orphanAccountIds.first else { return nil }

        guard (try? credentialStore.adoptOrphanedPassword(
            fromAccountId: orphanAccountId, toAccountId: needyAccount.id
        )) == true else { return nil }

        try? database.dbWriter.write { db in
            guard var row = try AccountRecord.fetchOne(db, key: needyAccount.id) else { return }
            row.needsReauth = false
            try row.update(db)
        }
        return needyAccount.id
    }

    func startObservingAccounts() {
        // アカウントの並び替え: `sortOrder` first (what a drag reorder
        // actually changes), `createdAt` only as a tiebreaker for rows that
        // happen to share a `sortOrder` (pre-migration backfill gives every
        // row a distinct value already, but this stays deterministic for
        // e.g. a brief post-`reconcile()` collision). Every account-order-
        // sensitive UI (`FolderListSheet`, `AccountFilterChipRow`,
        // `ComposerView`'s From picker, `AccountSettingsCategoryView`) reads
        // straight off `self.accounts`, so this one query is the single
        // place account order is decided.
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
        storeAccountsObservationTask(Task { [database] in
            do {
                for try await accounts in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    let previousAccountIds = self.accounts.map(\.id)
                    setObservedAccounts(accounts)
                    // Avatar resolution can start while the first account
                    // observation is still being delivered. In that window
                    // `GmailAccessTokenBridge.gmailAccountIds()` returns an
                    // empty list, so the Google source quietly falls back
                    // to initials. Re-run visible avatars once the live
                    // account list is available (and when accounts change).
                    if previousAccountIds != accounts.map(\.id) {
                        invalidateAvatarImages()
                    }
                    await restartBadgeObservationIfNeeded(accountIds: accounts.map(\.id))
                    // Backfill (M4): thread every not-yet-threaded message
                    // for each known account. Covers both a brand new
                    // account (belt-and-suspenders — `AccountSyncer`
                    // already threads as part of its own sync passes) and,
                    // more importantly, accounts synced before M4 shipped,
                    // whose `message.threadId` is still `nil` for every
                    // row. Cheap to re-run on every account-list tick: once
                    // an account's messages are threaded, the query this
                    // backs (`threadId IS NULL`) simply returns nothing.
                    for account in accounts {
                        try? await database.dbWriter.write { db in
                            try ThreadAssigner.assignAllUnthreaded(accountId: account.id, db: db)
                        }
                        // M11: see `retryPendingCredentialIfAvailable`'s doc
                        // comment — the "起動時再チェック" half of that
                        // method's two retry paths.
                        await retryPendingCredentialIfAvailable(account)
                    }
                }
            } catch {
                // A failing account-list observation shouldn't be fatal —
                // the sidebar just won't update further until relaunch.
            }
        })
    }

    /// H「アプリアイコンの未読バッジ」→ G「アイコンバッジの on/off 設定を
    /// アプリから削除」(実機フィードバック第3弾): (re)subscribes to
    /// `MessageQuery.unifiedInboxUnreadCountObservation(accountIds:)` and
    /// pushes every update to `BadgeCenter.setBadge(count:)` — this single
    /// `ValueObservation` is what covers "既読操作・同期・フォアグラウンド
    /// 復帰での更新" all at once (every one of those already writes to
    /// `message`/mutates flags through the same tables this query reads, so
    /// the observation fires on its own without any scene-phase-specific
    /// code here). Called from `startObservingAccounts()`'s loop on every
    /// `accounts` change, since `accountIds` has to track the current list
    /// — cancels and replaces any previous subscription rather than
    /// accumulating one per account change.
    ///
    /// G: the app's own on/off toggle (`BadgeSettingsStore`) is gone —
    /// whether the badge shows now follows **the OS's own notification
    /// settings** (設定 → 通知 → otegami → バッジ) exclusively, checked via
    /// `UNUserNotificationCenter.current().notificationSettings()
    /// .badgeSetting` on iOS. macOS keeps the unconditional pre-G behavior
    /// (`NSApplication.dockTile.badgeLabel` needs no permission at all, so
    /// there's no OS setting to defer to there — `BadgeCenter.setBadge
    /// (count:)`'s doc comment). `refreshBadgeObservation()` is public so
    /// `RootView.handleScenePhaseChange(.active)` can re-check on every
    /// foreground return — the OS setting can change at any time in
    /// Settings.app while this app is backgrounded, and there's no
    /// notification this app receives when that happens.
    func refreshBadgeObservation() {
        Task { await restartBadgeObservationIfNeeded(accountIds: accounts.map(\.id)) }
    }

    private func restartBadgeObservationIfNeeded(accountIds: [String]) async {
        cancelBadgeObservationTask()
        #if os(iOS)
        if markBadgeAuthorizationRequestedIfNeeded() {
            await BadgeCenter.requestAuthorizationIfNeeded()
        }
        // G: `.notDetermined`/`.disabled` both mean "OS says don't show a
        // badge" from this app's point of view — the request above only
        // resolves `.notDetermined` the *first* time this ever runs (a
        // decision, once made, persists); every call still re-fetches
        // current settings so a user who changes their mind in Settings.app
        // is picked up the next time this runs (see `refreshBadgeObservation`'s
        // doc comment on why `RootView` calls this on every foreground
        // return, not just once).
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        guard notificationSettings.badgeSetting == .enabled else {
            BadgeCenter.setBadge(count: 0)
            return
        }
        #endif
        guard !accountIds.isEmpty else {
            BadgeCenter.setBadge(count: 0)
            return
        }
        let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
        storeBadgeObservationTask(Task { [database] in
            do {
                for try await count in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    BadgeCenter.setBadge(count: count)
                }
            } catch {
                // Best-effort — a failing observation just leaves the badge
                // at whatever it last showed, same "not fatal" shape as
                // `startObservingAccounts()`'s own catch above.
            }
        })
    }

    /// Removes an account entirely (Settings → account list → delete):
    /// stops its `IDLE` loop, deletes the Keychain password, then deletes
    /// its `account` row — every `mailbox`/`message`/`thread`/`opQueue` row
    /// referencing it cascades via the schema's `onDelete: .cascade`
    /// foreign keys (`AppDatabase`'s migrator), so this one delete is
    /// enough to fully remove the account's local data too.
    func deleteAccount(_ account: AccountRecord) async {
        await syncCoordinator.stopIdleLoop(for: account)
        try? credentialStore.deletePassword(forAccountId: account.id)
        if let tokenStore {
            try? await tokenStore.clearTokens(for: account.id)
        }
        // M9: an account's watch (if push is enabled and one exists for
        // it) has to go too — otherwise the relay would keep IDLE-ing an
        // IMAP credential for an account this app no longer even knows
        // about.
        await unregisterWatch(forAccountId: account.id)
        try? await database.dbWriter.write { db in
            // M7: `account`→`mailbox`→`message` cascades via `onDelete:
            // .cascade` foreign keys, but `messageSearchIndex` is a virtual
            // table with no FK support — its rows for this account's
            // messages have to be removed explicitly, before the cascade
            // wipes the `message` rows that would otherwise identify them.
            let messageIds = try Int64.fetchAll(
                db,
                sql: """
                    SELECT message.id FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE mailbox.accountId = ?
                    """,
                arguments: [account.id]
            )
            try FTSIndexer.deleteAll(messageIds: messageIds, db: db)
            _ = try account.delete(db)
        }
        // M11: this deletion is user-initiated here (as opposed to one
        // `CloudAccountDirectory.deleteLocally` runs in response to a
        // tombstone that already exists) — push a fresh tombstone so every
        // other device syncing this Apple ID's iCloud account picks up the
        // deletion too.
        await accountCloudSync.pushLocalDeletion(accountId: account.id)
    }

    // MARK: - Account ordering

    /// The `sortOrder` a brand-new account should be created with — one past
    /// whatever's currently highest, so a freshly-added account always lands
    /// at the *end* of every account-ordered list rather than jumping to an
    /// arbitrary position. Reads `self.accounts` (already the live,
    /// correctly-ordered result of `startObservingAccounts`'s
    /// `ValueObservation`) rather than issuing a fresh DB query — cheap, and
    /// exactly the list every call site (`AccountSetupView`,
    /// `ICloudAccountSetupView`, `createGmailAccount`) would otherwise have
    /// had to read for itself.
    func nextAccountSortOrder() -> Int {
        (accounts.map(\.sortOrder).max() ?? -1) + 1
    }

    /// The `labelColorKey` a brand-new account should be created with —
    /// Task #72「自動割当の改善」: the palette color whose hue is farthest
    /// from every existing account's *resolved* color (manual pick or the
    /// FNV-1a hash fallback alike), so a freshly-added account doesn't land
    /// on a color an existing account already has by chance (real device
    /// report: three accounts in a row all auto-assigned "amber"/gold).
    /// Persisted as an explicit `labelColorKey` rather than left `nil` (which
    /// would just fall back to the same hash) — same reasoning and same
    /// three call sites as `nextAccountSortOrder()` above
    /// (`AccountSetupView`, `ICloudAccountSetupView`, `createGmailAccount`).
    func leastUsedAccountLabelColorKey() -> String {
        let usedColors = accounts.map {
            OtegamiAccountColor.resolvedPaletteColor(for: $0.id, override: $0.labelColorKey)
        }
        return OtegamiAccountColor.leastUsedColorKey(avoiding: usedColors).rawValue
    }

    /// Persists a drag-reorder from the accounts list (設定 のアカウント一覧
    /// — same content backs the hamburger menu/filter chips/Composer's From
    /// picker via `self.accounts`, so this one call is all any of those UIs
    /// needs). `orderedAccountIds` is the *complete* new order (every known
    /// account id, exactly once — what SwiftUI's `.onMove`-driven array
    /// already looks like after the move is applied locally); writes back a
    /// dense `0, 1, 2, ...` sequence matching that order.
    ///
    /// Only actually writes (and pushes to iCloud) the rows whose
    /// `sortOrder` genuinely changed — most `.onMove` calls only move one
    /// row past a handful of others, so most rows keep the position they
    /// already had. Builds `changedAccounts` as the write closure's *return
    /// value* rather than mutating a captured `var` from inside it — Swift 6
    /// strict concurrency rejects mutating a captured variable from within a
    /// `@Sendable` closure like `DatabaseWriter.write`'s, the same
    /// constraint `updateAccount`'s `toWrite` snapshot works around
    /// elsewhere in this file.
    func reorderAccounts(_ orderedAccountIds: [String]) async {
        let now = Date()
        let changedAccounts = (try? await database.dbWriter.write { db -> [AccountRecord] in
            var changed: [AccountRecord] = []
            for (index, accountId) in orderedAccountIds.enumerated() {
                guard var row = try AccountRecord.fetchOne(db, key: accountId) else { continue }
                guard row.sortOrder != index else { continue }
                row.sortOrder = index
                row.updatedAt = now
                try row.update(db, columns: [Column("sortOrder"), Column("updatedAt")])
                changed.append(row)
            }
            return changed
        }) ?? []
        for account in changedAccounts {
            await pushAccountToCloud(account)
        }
    }

    // MARK: - Account editing

    /// Saves an edit to an existing account (`AccountEditView`) — display
    /// name, IMAP/SMTP host/port/security, SMTP username, and (only when
    /// `newPassword` is non-`nil`/non-empty) a new Keychain password. Fixed
    /// per `AccountRecord.kind`/identity fields (`email`, `kind`,
    /// `imapUsername`) are deliberately **not** parameters here — the plan
    /// this implements is explicit that email/kind aren't editable (they're
    /// the account's identity; changing either means "a different
    /// account"), and `imapUsername` specifically is left out of the edit
    /// form too (only ever set at creation, alongside `email`).
    ///
    /// Bumps `updatedAt` (so `AccountCloudSyncEngine`'s last-writer-wins
    /// reconcile actually has something to compare — see
    /// `AccountRecord.updatedAt`'s doc comment on why this was previously
    /// dead weight) and pushes the result to iCloud, mirroring every other
    /// account-mutating call site's `pushAccountToCloud` tail.
    ///
    /// Also invalidates the account's cached `AccountSyncer` (see
    /// `SyncCoordinator.invalidateSyncer(for:)`'s doc comment for why this
    /// is necessary at all: without it, a syncer built before this edit
    /// keeps using the pre-edit host/port/credentials indefinitely) and
    /// stops its `IDLE` loop — `OtegamiApp`'s `.onChange(of:
    /// environment.accounts)` (already fires for any change to this
    /// `AccountRecord`, not just a brand-new one, since `AccountRecord` is
    /// `Equatable` and the array changed) restarts the `IDLE` loop and
    /// kicks an incremental sync with the fresh `AccountRecord`, the exact
    /// same path a newly-added account already goes through — no
    /// duplicate "restart sync" logic needed here.
    func updateAccount(
        _ account: AccountRecord,
        displayName: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: ConnectionSecurityRecord,
        smtpHost: String?,
        smtpPort: Int?,
        smtpSecurity: ConnectionSecurityRecord?,
        smtpUsername: String?,
        newPassword: String?,
        labelColorKey: String?? = nil,
        defaultSignatureId: Int64?? = nil
    ) async throws {
        var updated = account
        updated.displayName = displayName
        updated.imapHost = imapHost
        updated.imapPort = imapPort
        updated.imapSecurity = imapSecurity
        updated.smtpHost = smtpHost
        updated.smtpPort = smtpPort
        updated.smtpSecurity = smtpSecurity
        updated.smtpUsername = smtpUsername
        // D「アカウントのラベル色を変更可能に」: `labelColorKey` is `String??`
        // (an optional-of-an-optional) specifically so callers that don't
        // pass it at all (every pre-existing call site) leave the column
        // untouched, while `AccountEditView` — which always knows the
        // picker's current selection, including "自動" (nil) — can pass
        // `.some(nil)` to explicitly clear back to auto-assignment. `nil`
        // (the parameter itself absent) means "don't touch this field";
        // `.some(x)` means "set it to x", where x may itself be nil.
        if let labelColorKey {
            updated.labelColorKey = labelColorKey
        }
        // F「デフォルト署名（アカウントごと）」— same "`??` means don't touch,
        // `.some(x)` means set to x (possibly nil)" shape as `labelColorKey`
        // just above; see that parameter's doc comment.
        if let defaultSignatureId {
            updated.defaultSignatureId = defaultSignatureId
        }
        updated.updatedAt = Date()

        if let newPassword, !newPassword.isEmpty {
            try credentialStore.setPassword(newPassword, forAccountId: updated.id)
        }

        // Snapshotted as a `let` before the closure: `DatabaseWriter.write`'s
        // closure is `@Sendable`, and capturing a mutated `var` across that
        // boundary is rejected under Swift 6 strict concurrency (same
        // pattern `AccountSyncer.performInitialSync`'s `syncedRecord` uses).
        let toWrite = updated
        try await database.dbWriter.write { db in
            try toWrite.update(db)
        }

        await syncCoordinator.stopIdleLoop(for: updated)
        await syncCoordinator.invalidateSyncer(for: updated.id)

        await pushAccountToCloud(updated)
    }
}
