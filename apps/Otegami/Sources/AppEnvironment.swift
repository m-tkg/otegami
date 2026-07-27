import AccountCloudSync
import Foundation
import GoogleOAuth
import GRDB
import MailTransport
import MailTransportMailCore
import OtegamiRelayAPI
import OtegamiStore
import OtegamiTranslation
import OtegamiTranslationFoundationModels
import PushRelayClient
import SyncEngine
import TranslationEngine
#if os(iOS)
import UserNotifications
#endif

/// Root dependency-injection container for the app: the shared database,
/// the sync coordinator (wired to the real `MailCoreIMAPSession` — tests
/// inject `FakeIMAPSession` directly into `SyncEngine`'s own test target
/// instead of going through this type), and the Keychain-backed credential
/// store. Also keeps a live `accounts` list so the sidebar (and anything
/// else that needs "which accounts exist") doesn't have to set up its own
/// top-level `ValueObservation`.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let syncCoordinator: SyncCoordinator
    let credentialStore: KeychainCredentialStore
    /// C6/C7 送信キャンセル — see `PendingSendCoordinator`'s doc comment.
    let pendingSendCoordinator = PendingSendCoordinator()
    /// M9: push opt-in. `pushSettings` is the persistence layer
    /// (`PushSettingsStore`'s doc comment); `isPushEnabled`/
    /// `pushRelayURLString` mirror it into `@Observable` state so
    /// `PushNotificationSettingsView` doesn't read `UserDefaults`
    /// directly.
    let pushRelayClient = PushRelayClient()
    @ObservationIgnored let pushSettings: PushSettingsStore
    private(set) var isPushEnabled: Bool
    private(set) var pushRelayURLString: String

    /// M11: iCloud account-definition sync. `accountCloudSync` reconciles
    /// the local `account` table against the `"accounts.v1"` iCloud KVS key
    /// (`docs/icloud-sync.md`); `cloudSyncSettings` is the "iCloud でアカウン
    /// トを同期" toggle's persistence (`AccountsSettingsView`),
    /// `isCloudSyncEnabled` its `@Observable` mirror for the UI, matching
    /// the `pushSettings`/`isPushEnabled` split above.
    @ObservationIgnored let cloudSyncSettings: CloudSyncSettingsStore
    @ObservationIgnored let accountCloudSync: AccountCloudSyncEngine
    private(set) var isCloudSyncEnabled: Bool
    // `nonisolated(unsafe)`: only ever written once, from `init()` (already
    // `@MainActor`), and read once, from `deinit` — which Swift requires to
    // be `nonisolated` even on a `@MainActor` class, so this property can't
    // itself be actor-isolated if `deinit` is going to read it at all.
    @ObservationIgnored nonisolated(unsafe) private var cloudSyncNotificationObserver: NSObjectProtocol?
    /// `nil` when `GOOGLE_OAUTH_CLIENT_ID` isn't configured for this build
    /// (see `GoogleOAuthConfig`'s doc comment) — every Gmail-entry point
    /// checks this (directly or via `isGmailOAuthConfigured`) before
    /// offering the option at all.
    let googleOAuthClient: GoogleOAuthClient?
    let tokenStore: TokenStore?

    /// Drives `AccountTypeSelectionView`'s Gmail button (disabled + a
    /// docs/oauth-setup.md hint when `false`) — see `GoogleOAuthConfig`.
    var isGmailOAuthConfigured: Bool { googleOAuthClient != nil }

    private(set) var accounts: [AccountRecord] = []
    @ObservationIgnored private var accountsObservationTask: Task<Void, Never>?
    /// H「アプリアイコンの未読バッジ」— restarted (not just left running)
    /// every time `accounts` changes, since `MessageQuery
    /// .unifiedInboxUnreadCountObservation(accountIds:)`'s `accountIds`
    /// argument has to track the current account list. See
    /// `restartBadgeObservationIfNeeded(accountIds:)`.
    @ObservationIgnored private var badgeObservationTask: Task<Void, Never>?
    /// Set once `BadgeCenter.requestAuthorizationIfNeeded()` has actually
    /// been called this launch — guards against re-requesting on every
    /// single `accounts` change (harmless either way since the OS itself is
    /// idempotent about a decided authorization, but there's no reason to
    /// call it more than once).
    @ObservationIgnored private var hasRequestedBadgeAuthorization = false

    /// design-phase-3 (1i/1k, `docs/translation.md`): the raw engine, for
    /// one-off translations not tied to a stored message (`ComposerView`'s
    /// "英語に翻訳して送る" — there's no `messageId` for a draft still being
    /// typed, so `MessageTranslator`'s per-message cache doesn't apply).
    /// Always `FoundationModelsTranslationService` — this app's deployment
    /// target is already iOS/macOS 26 (`project.yml`), so the type itself
    /// is unconditionally available at compile time; whether it can
    /// actually translate on *this* device/Apple Intelligence
    /// configuration is a runtime question `isTranslationAvailable`
    /// answers by reading `availability`, not something that needs a
    /// separate `FakeTranslationService` fallback in the shipping app (that
    /// fake exists for tests/previews — `OtegamiTranslation`'s own doc
    /// comment).
    @ObservationIgnored let translationService: any TranslationService
    /// The cached, per-message-persisted counterpart (`docs/translation.md`'s
    /// "キャッシュ方針") — what `MessageView`'s translation bar (1i) actually
    /// calls, so opening the same English message twice doesn't re-run the
    /// on-device model twice.
    @ObservationIgnored let messageTranslator: MessageTranslator

    /// Drives the translation bar's visibility/enabled state and the
    /// Composer's "英語に翻訳して送る" toggle — `false` covers every
    /// `TranslationUnavailableReason` (device not eligible, Apple
    /// Intelligence off, model not ready) with one check, matching how
    /// `isGmailOAuthConfigured` above collapses its own availability
    /// question to a single `Bool` for view code.
    var isTranslationAvailable: Bool { translationService.availability.isAvailable }

    init() {
        // Design system: registers the bundled Archivo variable font with
        // CoreText before any view can render — see `OtegamiFont
        // .registerCustomFontsIfNeeded()`'s doc comment. Was previously
        // never called at all (`docs/design-system.md`'s "次フェーズへの
        // 申し送り"), so every `Font.custom("ArchivoRoman-...", ...)` token
        // silently fell back to the system font; harmless but not what the
        // design system intends. `AppEnvironment.init()` runs exactly once,
        // synchronously, before `RootView` first renders, and is already
        // `@MainActor`, matching this call's own `@MainActor` requirement.
        OtegamiFont.registerCustomFontsIfNeeded()
        // design-phase-3: registers the 1l "翻訳" defaults (auto-translate
        // on, list summary off) before any `@AppStorage` reader — see
        // `UserDefaults.registerOtegamiTranslationDefaults()`'s doc comment.
        UserDefaults.registerOtegamiTranslationDefaults()
        // B「画像の設定」— see `UserDefaults.registerOtegamiImageDefaults()`'s
        // doc comment for why this needs to run before any `HTMLMessageView`
        // is ever constructed, not just before any `@AppStorage` read.
        UserDefaults.registerOtegamiImageDefaults()
        // F (実機フィードバック第3弾): one-time, idempotent cleanup of the
        // now-removed in-app "表示言語" setting's `AppleLanguages` override
        // — see `LocalizationSettingsStore.migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()`'s
        // doc comment. Must run before anything else in this `init()` reads
        // a localized string (nothing currently does synchronously here,
        // but this is the same "run migrations first" ordering the other
        // `register...Defaults()` calls above already follow).
        LocalizationSettingsStore.migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()

        let database: AppDatabase
        do {
            database = try AppDatabase.makeShared(appGroupIdentifier: OtegamiAppGroup.identifier)
        } catch {
            // The on-disk database couldn't be opened (corrupt file, out of
            // disk space, ...). Falling back to in-memory keeps the app
            // usable for the current launch rather than crashing outright;
            // the underlying issue would need a real repair/reset flow to
            // recover from permanently, which is out of scope for M1.
            assertionFailure("Failed to open shared database, falling back to in-memory: \(error)")
            guard let inMemory = try? AppDatabase.makeInMemory() else {
                fatalError("Failed to create even an in-memory database: \(error)")
            }
            database = inMemory
        }
        self.database = database

        // Moved ahead of the duplicate-account merge below (it used to be
        // constructed much further down, alongside `syncCoordinator`) so
        // the merge's survivor pick can do a *live* Keychain check instead
        // of trusting the persisted `AccountRecord.needsReauth` column —
        // see `AccountDuplicateMerger.mergeDuplicateAccounts`'s
        // `hasCredential` parameter doc comment for the real-device bug
        // (`KeychainCredentialStore.legacyServices`'s doc comment) that
        // made the column-only check pick a credential-less survivor.
        // `KeychainCredentialStore` itself has no dependency on anything
        // constructed later in this initializer, so moving it earlier is
        // safe.
        self.credentialStore = KeychainCredentialStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)

        // UITest-only escape hatch (mirrors `MessageView
        // .deleteCredentialIfUITestRequested`'s `OTEGAMI_UITEST_*`
        // pattern) — see `KeychainCredentialStore
        // .relocateToLegacyServiceForUITesting`'s doc comment.
        // `OtegamiCredentialRecoveryUITests` sets this on a *second* launch
        // (after a first, ordinary launch already added a real account, so
        // its password already exists under the current `service`) to
        // reproduce the exact state a device that predates the `52df393`
        // Keychain-service rename was left in, then lets the rest of this
        // very same `init()` — the duplicate-merge live credential check
        // right below, `startObservingAccounts`'s automatic retry, any
        // message body fetch — exercise `KeychainCredentialStore`'s own
        // legacy-service fallback for real, end to end.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE"] == "1" {
            let passwordAccountIds = (try? database.dbWriter.read { db in
                try AccountRecord.filter(Column("authType") == AccountAuthType.password.rawValue).fetchAll(db)
            })?.map(\.id) ?? []
            for accountId in passwordAccountIds {
                credentialStore.relocateToLegacyServiceForUITesting(accountId: accountId)
            }
        }

        // UITest-only escape hatch, the other shape of credential loss this
        // app now recovers from (see `KeychainCredentialStore
        // .relocateToOrphanAccountIdForUITesting`'s doc comment) — moves
        // every `.password` account's Keychain password onto a synthetic id
        // that matches no real `AccountRecord`, reproducing a device that
        // already went through a bad duplicate-account merge before this
        // fix shipped and was left with the real password stranded under
        // the merged-away account's now-nonexistent id.
        // `OtegamiCredentialRecoveryUITests` sets this on a *second* launch,
        // then lets the very next, ordinary launch (no flag) exercise
        // `adoptOrphanedCredentialIfUnambiguous` below for real.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID"] == "1" {
            let passwordAccountIds = (try? database.dbWriter.read { db in
                try AccountRecord.filter(Column("authType") == AccountAuthType.password.rawValue).fetchAll(db)
            })?.map(\.id) ?? []
            for accountId in passwordAccountIds {
                credentialStore.relocateToOrphanAccountIdForUITesting(
                    accountId: accountId, orphanAccountId: "\(accountId)-orphaned-uitest"
                )
            }
        }

        // M11 bug fix: consolidate already-local duplicate `account` rows
        // for the same real mailbox — see `AccountDuplicateMerger`'s doc
        // comment for the bug this is the migration side of
        // (`docs/icloud-sync.md`'s "重複挿入バグ"): a device that hit the
        // pre-fix `AccountCloudSyncEngine.reconcile()` duplicate-insertion
        // bug ends up with two account rows for the same mailbox — one
        // live, one perpetually `needsReauth` (no Keychain credential for
        // its UUID ever synced to this device) — which showed up as two
        // identical entries in Settings → アカウント and, because the
        // unified inbox merges both accounts' independently-synced mail,
        // duplicate messages that failed to open unpredictably depending on
        // which duplicate's copy a given message came from. Run
        // synchronously (unlike the FTS backfill/cloud reconcile `Task`s
        // below) so `startObservingAccounts()`'s very first read of the
        // account list already reflects the merged state — nobody should
        // ever see the duplicate flash by in Settings, even for one frame.
        // Idempotent (`AccountDuplicateMerger`'s doc comment) — safe to
        // leave unconditional on every launch rather than gating it behind
        // a one-shot flag.
        //
        // `OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE`: a UITest-only
        // escape hatch (mirrors `ComposerView
        // .attachUITestFixtureIfRequested`'s/`MessageView
        // .deleteCredentialIfUITestRequested`'s `OTEGAMI_UITEST_*` launch-
        // environment pattern), no-op unless explicitly set — lets
        // `OtegamiDuplicateAccountUITests` inject a duplicate `account` row
        // via `sqlite3` between two launches of the *same* build and
        // actually capture the pre-merge "two accounts" bug state on
        // screen for one launch, before letting the very next launch (flag
        // unset) run the real merge. Without this, the synchronous merge
        // above makes the bug state unobservable in the UI even for a
        // single frame by design — which is the correct behavior for real
        // users, but means an automated screenshot-based "before" repro
        // needs some way to hold that state still for one launch.
        let duplicateMerges: [AccountDuplicateMerger.MergeResult]
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE"] == "1" {
            duplicateMerges = []
        } else {
            // `.password`-kind credential check is a synchronous Keychain
            // read (`KeychainCredentialStore.password` never suspends), so
            // it can run live, right here, inside this still-synchronous
            // `init()` — unlike `.oauth2`'s `TokenStore.hasStoredRefreshToken`
            // (an actor method, genuinely `async`, and `init()` can't await
            // into it without breaking the "no duplicate-row flash" ordering
            // this whole block's doc comment above depends on). A `.oauth2`
            // duplicate group therefore still falls back to `order()`'s
            // `!needsReauth` heuristic, same as before this parameter
            // existed — only the `.password` path (the one the real-device
            // report was actually about) gets the live check.
            let credentialStore = self.credentialStore
            duplicateMerges = (try? database.dbWriter.write { db in
                try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) { account in
                    guard account.authType == .password else { return !account.needsReauth }
                    return ((try? credentialStore.password(forAccountId: account.id)) ?? nil) != nil
                }
            }) ?? []
        }

        // Immediate rescue, part 1 — this merge's own aftermath: even with
        // the live `hasCredential` check above, a `.oauth2` duplicate group
        // still falls back to the (possibly stale) `!needsReauth` heuristic
        // (see the closure's own comment), so it's still possible for a
        // merge picked *this very launch* to leave a `.password` survivor
        // with no working credential while one of the accounts it just
        // merged away genuinely had one. Adopt that credential onto the
        // survivor's accountId right now, synchronously, *before*
        // `cleanupAfterDuplicateMerge` below gets a chance to delete it as
        // this device's own stray leftover — this is what makes that
        // deletion safe to keep unconditional rather than needing to know
        // which ids were "rescued" and which weren't.
        for merge in duplicateMerges {
            guard let survivorAccount = (try? database.dbWriter.read { db in
                try AccountRecord.fetchOne(db, key: merge.survivorAccountId)
            }) ?? nil,
                survivorAccount.authType == .password,
                ((try? credentialStore.password(forAccountId: merge.survivorAccountId)) ?? nil) == nil
            else { continue }
            for loserAccountId in merge.mergedAccountIds {
                guard (try? credentialStore.adoptOrphanedPassword(
                    fromAccountId: loserAccountId, toAccountId: merge.survivorAccountId
                )) == true else { continue }
                try? database.dbWriter.write { db in
                    guard var row = try AccountRecord.fetchOne(db, key: merge.survivorAccountId) else { return }
                    row.needsReauth = false
                    try row.update(db)
                }
                break
            }
        }

        // Immediate rescue, part 2 — a device that already went through a
        // bad merge in a *previous* launch, before this fix shipped: the
        // duplicate `account` rows are long gone by now (so `duplicateMerges`
        // above is empty and part 1 never runs), but the real password can
        // still be sitting in the Keychain, orphaned, under the merged-away
        // account's id — `CloudAccountDirectory.cleanupAfterDuplicateMerge`'s
        // own credential delete is a `Task` that races the very next app
        // termination, so it isn't guaranteed to have run to completion.
        // Only acts when completely unambiguous (exactly one `.password`
        // account missing a credential, exactly one orphaned Keychain item)
        // — see `KeychainCredentialStore.adoptOrphanedPassword`'s doc
        // comment for why guessing between multiple candidates is
        // deliberately not attempted. Also a no-op if the user already
        // recovered by hand via `AccountEditView`'s "パスワードを入力" flow
        // before this fix shipped (`adoptOrphanedPassword` refuses to
        // clobber an existing credential).
        Self.adoptOrphanedCredentialIfUnambiguous(database: database, credentialStore: credentialStore)

        self.syncCoordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: { draft in MailCoreMessageBuilder.build(draft) }
        )
        // `credentialStore` itself was constructed further up — see the
        // duplicate-account-merge block's comment on why.

        // design-phase-3: see `translationService`/`messageTranslator`'s
        // doc comments.
        let translationService = FoundationModelsTranslationService()
        self.translationService = translationService
        self.messageTranslator = MessageTranslator(
            database: database,
            service: translationService,
            engineIdentifier: MessageTranslator.EngineIdentifier.foundationModels
        )

        let pushSettings = PushSettingsStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)
        self.pushSettings = pushSettings
        self.isPushEnabled = pushSettings.isEnabled
        self.pushRelayURLString = pushSettings.relayURLString ?? ""

        if let endpoints = GoogleOAuthConfig.endpoints {
            let client = GoogleOAuthClient(
                endpoints: endpoints,
                sessionRunner: ASWebAuthenticationSessionRunner(presentationContextProvider: AuthPresentationContextProvider())
            )
            self.googleOAuthClient = client
            self.tokenStore = TokenStore(refresher: client)
        } else {
            self.googleOAuthClient = nil
            self.tokenStore = nil
        }

        // M11: iCloud account sync. `directory` bundles everything
        // `AccountCloudSyncEngine` needs to actually apply a reconcile
        // decision locally — see `CloudAccountDirectory`'s doc comment for
        // why it holds these references directly instead of AppEnvironment
        // passing itself in via callback closures.
        let cloudSyncSettings = CloudSyncSettingsStore()
        self.cloudSyncSettings = cloudSyncSettings
        self.isCloudSyncEnabled = cloudSyncSettings.isEnabled
        let directory = CloudAccountDirectory(
            database: database,
            credentialStore: credentialStore,
            tokenStore: tokenStore,
            syncCoordinator: syncCoordinator,
            pushSettings: pushSettings,
            pushRelayClient: pushRelayClient
        )
        self.accountCloudSync = AccountCloudSyncEngine(
            store: SystemUbiquitousStore(),
            local: directory,
            isEnabled: { [cloudSyncSettings] in cloudSyncSettings.isEnabled }
        )

        // Tear down whatever per-device state (cached `AccountSyncer`/
        // `IDLE` loop, Keychain password, OAuth tokens, registered push
        // watch) the duplicate-merge pass above left behind for each
        // merged-away account id — the DB row is already gone by this
        // point (deleted inside the synchronous merge above), so this only
        // ever needs the id, never the full `AccountRecord`
        // (`CloudAccountDirectory.cleanupAfterDuplicateMerge`'s doc
        // comment). Captures `directory` (a `Sendable` struct), not
        // `self`, matching the `cloudSync`-only capture the reconcile
        // `Task` right below already uses.
        if !duplicateMerges.isEmpty {
            let mergedAwayAccountIds = duplicateMerges.flatMap(\.mergedAccountIds)
            Task {
                for accountId in mergedAwayAccountIds {
                    await directory.cleanupAfterDuplicateMerge(accountId: accountId)
                }
            }
        }

        // C6/C7: wired last, once every other stored property has a value
        // (Swift's two-phase init rule — `self` can't be handed to
        // anything, even just to store a `weak` back-reference, until then).
        pendingSendCoordinator.configure(environment: self)

        startObservingAccounts()

        // M7: defensive self-heal, in addition to the v7 migration's own
        // one-time backfill (`AppDatabase`) — cheap once caught up (a
        // single `NOT EXISTS` scan that finds nothing), so running it again
        // on every launch costs effectively nothing but guards against any
        // future code path that ever inserts a `message` row without going
        // through `AccountSyncer.upsert`/`BodyFetcher.fetchBody`.
        Task { [database] in
            try? await database.dbWriter.write { db in
                try FTSIndexer.backfillIfNeeded(db: db)
            }
        }

        // M11: reconcile once at launch, then again every time iCloud
        // reports the KVS payload changed externally (another device
        // pushed while this one wasn't running, or just now). Every actual
        // side effect (inserting/updating/deleting an `AccountRecord`,
        // starting a first sync, registering/tearing down a push watch)
        // happens inside `accountCloudSync`/`directory` themselves — see
        // `CloudAccountDirectory`'s doc comment — so the observer here only
        // ever needs to call `reconcile()` and can capture the engine
        // itself (an actor, `Sendable`) rather than `self`.
        let cloudSync = accountCloudSync
        Task {
            await cloudSync.reconcile()
        }
        cloudSyncNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: nil
        ) { _ in
            Task {
                await cloudSync.reconcile()
            }
        }

        // C「既読メール再表示の高速化」(実機フィードバック第3弾) — see
        // `HTMLWebViewPrewarmer`'s doc comment. Deferred to a `Task` (not
        // called synchronously here) so warming up a `WKWebView` never
        // delays `RootView`'s first render.
        Task { @MainActor in
            HTMLWebViewPrewarmer.prewarm()
        }
    }

    deinit {
        accountsObservationTask?.cancel()
        badgeObservationTask?.cancel()
        if let cloudSyncNotificationObserver {
            NotificationCenter.default.removeObserver(cloudSyncNotificationObserver)
        }
    }

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
    private static func adoptOrphanedCredentialIfUnambiguous(
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

    private func startObservingAccounts() {
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db)
        }
        accountsObservationTask = Task { [database] in
            do {
                for try await accounts in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    self.accounts = accounts
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
        }
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
        badgeObservationTask?.cancel()
        #if os(iOS)
        if !hasRequestedBadgeAuthorization {
            hasRequestedBadgeAuthorization = true
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
        badgeObservationTask = Task { [database] in
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
        }
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

    // MARK: - iCloud account sync (M11)

    /// `AccountsSettingsView`'s "iCloud でアカウントを同期" toggle. Flipping it
    /// on runs a full `reconcile()` immediately (plan: "OFF→ON で full
    /// reconcile") rather than waiting for the next launch/external-change
    /// notification; flipping it off just persists the flag — every
    /// in-flight `accountCloudSync` call already no-ops once
    /// `cloudSyncSettings.isEnabled` reads `false` (`AccountCloudSyncEngine`
    /// reads it fresh on every call, not just at construction time), so
    /// there's nothing further to tear down.
    func setCloudSyncEnabled(_ enabled: Bool) async {
        let wasEnabled = cloudSyncSettings.isEnabled
        cloudSyncSettings.isEnabled = enabled
        isCloudSyncEnabled = enabled
        if enabled, !wasEnabled {
            await accountCloudSync.reconcile()
        }
    }

    /// Pushes a locally-added or locally-changed account to iCloud right
    /// away — called after every account-creation flow's local DB insert
    /// (`AccountSetupView`/`ICloudAccountSetupView`/`createGmailAccount`
    /// below) instead of waiting for the next full `reconcile()`.
    func pushAccountToCloud(_ account: AccountRecord) async {
        await accountCloudSync.pushLocalChange(CloudAccountSnapshot(account: account))
    }

    /// A `.password`-kind account `CloudAccountDirectory.insertFromCloud`
    /// created without a credential (iCloud Keychain hadn't synced the
    /// password yet — see `AccountRecord.needsReauth`'s doc comment) gets
    /// Keychain re-checked automatically on every accounts-list tick
    /// (`startObservingAccounts`, cheap once resolved since this whole
    /// method becomes a no-op the moment `needsReauth` flips to `false`).
    /// Real-device bug fix: this used to also be reachable from
    /// `AccountsSettingsView`'s "再接続" button as an explicit-retry sibling
    /// (`retryPendingCredential(for:)`, since removed) — but a button whose
    /// only job is "run this same automatic check one time, right now" is
    /// useless once the credential is actually gone rather than merely not
    /// synced yet, and gives the user no way to tell the two apart. The
    /// button now pushes straight to `AccountEditView`'s password field
    /// instead (`AccountsSettingsView.passwordEntryAccount`'s doc comment)
    /// — a `.password` account's only real recovery path — leaving this
    /// automatic tick-based check as the sole caller. A `.gmail`/`.oauth2`
    /// account's `needsReauth` means something different (a rejected
    /// refresh token — `AppEnvironment.reauthenticateGmailAccount`'s
    /// interactive OAuth flow is the only way to clear that one), so this
    /// only ever touches `.password` accounts.
    private func retryPendingCredentialIfAvailable(_ account: AccountRecord) async {
        guard account.needsReauth, account.authType == .password else { return }
        guard let password = try? credentialStore.password(forAccountId: account.id) else { return }
        await setNeedsReauth(false, for: account)
        let auth = MailAuth.password(username: account.imapUsername, password: password)
        Task {
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        await registerWatchIfNeeded(for: account)
    }

    // MARK: - Auth resolution (M6: "SyncCoordinator のセッション構築経路に auth
    // provider を注入する形に拡張")

    enum AuthResolutionError: Error {
        /// `.password`-kind account with no Keychain entry (deleted
        /// externally, or the account row outlived a failed Keychain
        /// write — see `AccountSetupView.saveAccount`'s doc comment on
        /// that ordering).
        case missingCredential
        /// `.oauth2`-kind account but this build has no
        /// `GOOGLE_OAUTH_CLIENT_ID` configured — shouldn't be reachable in
        /// practice (the Gmail entry point is disabled without one, so no
        /// `.gmail` account could have been created), but handled
        /// explicitly rather than force-unwrapping `tokenStore`.
        case oauthUnavailable
    }

    /// The single place every call site that needs a `MailAuth` for
    /// `account` goes through — replaces the four near-identical
    /// "read Keychain, build `.password`" blocks M1–M5 each had (see
    /// `OtegamiApp.swift`/`ComposerView`/`MessageListView`/`MessageView`
    /// before this change) and adds the M6 branch: for a `.gmail`-kind
    /// account, asks `TokenStore` for a currently-valid access token
    /// (refreshing under the hood if needed) and returns
    /// `MailAuth.xoauth2`. On `TokenStoreError.reauthenticationRequired`,
    /// marks the account "要再認証" (persisted, so `AccountsSettingsView`'s
    /// banner survives a relaunch) before rethrowing.
    func auth(for account: AccountRecord) async throws -> MailAuth {
        switch account.authType {
        case .password:
            guard let password = try credentialStore.password(forAccountId: account.id) else {
                // Bug fix: previously this branch never touched
                // `needsReauth` at all, unlike the `.oauth2` branch below —
                // a `.password` account whose Keychain item genuinely goes
                // missing (not just the M11 "cloud-inserted, iCloud
                // Keychain hasn't caught up yet" case, which already sets
                // this at insert time via `CloudAccountDirectory
                // .insertFromCloud`) had no visible symptom anywhere in the
                // UI: every call site that needs a body/attachment/send
                // just failed with whatever error message *that* call site
                // happened to show, with no account-level banner and no
                // "再接続" affordance pointing at the actual cause. Setting
                // it here means `AccountsListContent`'s existing
                // "資格情報を待っています"/"再接続" UI (built for the M11 case)
                // now also covers this one "for free" — same flag, same
                // banner, same automatic retry-on-tick
                // (`retryPendingCredentialIfAvailable`, which only fires
                // when `needsReauth` is already `true`) — instead of this
                // being a second, undiscoverable failure mode.
                await setNeedsReauth(true, for: account)
                throw AuthResolutionError.missingCredential
            }
            // Mirrors `retryPendingCredentialIfAvailable`'s clearing: any
            // successful resolution — not just the automatic per-tick
            // retry — means the credential is available again, so a stale
            // `needsReauth` (set by a previous failure, here or in
            // `retryPendingCredentialIfAvailable`) should stop being shown.
            if account.needsReauth {
                await setNeedsReauth(false, for: account)
            }
            return .password(username: account.imapUsername, password: password)

        case .oauth2:
            guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
            do {
                let accessToken = try await tokenStore.accessToken(for: account.id)
                return .xoauth2(username: account.imapUsername, accessToken: accessToken)
            } catch TokenStoreError.reauthenticationRequired {
                await setNeedsReauth(true, for: account)
                throw TokenStoreError.reauthenticationRequired
            }
        }
    }

    /// Best-effort — a failed write here just means the banner doesn't
    /// show/clear until the next successful DB write for this row; never
    /// worth failing whatever `auth(for:)`/`reauthenticateGmailAccount(_:)`
    /// call this from over.
    private func setNeedsReauth(_ value: Bool, for account: AccountRecord) async {
        try? await database.dbWriter.write { db in
            guard var row = try AccountRecord.fetchOne(db, key: account.id) else { return }
            guard row.needsReauth != value else { return }
            row.needsReauth = value
            try row.update(db)
        }
    }

    // MARK: - Gmail sign-in (M6)

    /// Runs the interactive Authorization Code + PKCE flow, then looks up
    /// the signed-in account's email (see `GoogleOAuthEndpoints
    /// .userInfoEndpoint`'s doc comment for why that second round trip is
    /// needed). Used by `GmailAccountSetupView` both for a brand-new
    /// account and — with the returned tokens simply re-stored under an
    /// *existing* account id — for `reauthenticateGmailAccount(_:)` below.
    /// Throws `AuthResolutionError.oauthUnavailable` if this build has no
    /// Client ID (shouldn't be reachable: the Gmail button is disabled in
    /// that case).
    func requestGmailAuthorization() async throws -> (email: String, tokens: GoogleOAuthTokens) {
        guard let googleOAuthClient else { throw AuthResolutionError.oauthUnavailable }
        let tokens = try await googleOAuthClient.requestAuthorization()
        let email = try await googleOAuthClient.fetchUserEmail(accessToken: tokens.accessToken)
        return (email, tokens)
    }

    /// Creates and persists a new Gmail account: `imap.gmail.com`/
    /// `smtp.gmail.com` presets (plan: "imap.gmail.com:993 / smtp.gmail.com:465or587"
    /// — 587/STARTTLS chosen as the more broadly-compatible of the two, see
    /// `GmailAccountSetupView`), `kind: .gmail`, `authType: .oauth2`. Stores
    /// `tokens` in `TokenStore` keyed by the new account's id (assigned
    /// here, before either write, since both the DB row and the token
    /// storage need to agree on it) and kicks off the first sync the same
    /// way `AccountSetupView.saveAccount`/`iCloudAccountSetupView` do.
    func createGmailAccount(email: String, displayName: String, tokens: GoogleOAuthTokens) async throws {
        guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
        let account = AccountRecord(
            displayName: displayName.isEmpty ? email : displayName,
            email: email,
            authType: .oauth2,
            kind: .gmail,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: email,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            smtpUsername: email
        )
        // TokenStore first, same ordering rationale as
        // `AccountSetupView.saveAccount`'s Keychain-before-DB-row: an
        // account row with nowhere to get an access token from is useless,
        // while an orphaned TokenStore entry for an id nothing references
        // is harmless dead weight.
        try await tokenStore.storeInitialTokens(tokens, accountId: account.id)
        try await database.dbWriter.write { db in
            try account.insert(db)
        }

        Task {
            guard let auth = try? await self.auth(for: account) else { return }
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        // M11: see AccountSetupView.saveAccount's identical call.
        Task { await pushAccountToCloud(account) }
    }

    /// Re-runs the OAuth flow for an already-existing `.gmail` account
    /// (`AccountsSettingsView`'s "再認証" button) and clears its
    /// `needsReauth` flag on success. Deliberately does *not* verify the
    /// re-authenticated account is the same Google account as before —
    /// Google's consent screen always shows the account picker, so the
    /// user could pick a different one; that's treated as "the user's
    /// explicit choice", not an error to guard against here (a mismatch
    /// would just start delivering a different inbox's mail, which is
    /// immediately obvious rather than a silent data-integrity problem).
    func reauthenticateGmailAccount(_ account: AccountRecord) async throws {
        guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
        let (_, tokens) = try await requestGmailAuthorization()
        try await tokenStore.storeInitialTokens(tokens, accountId: account.id)
        await setNeedsReauth(false, for: account)
    }

    // MARK: - Push notifications (M9)

    enum PushError: Error, Equatable {
        /// Relay URL failed `PushNotificationSettingsView`'s "https
        /// required (http://localhost exempted for local dev)" check.
        case invalidRelayURL
        /// `PushTokenCenter` never got a device token — always the case on
        /// the iOS Simulator (`PushTokenCenter`'s doc comment). No longer
        /// used for a denied notification-authorization prompt on a real
        /// device — that's `.notificationPermissionDenied` now, so the UI
        /// can tell the two apart and point at Settings only for the
        /// latter.
        case noDeviceToken
        /// The user declined (or had previously declined) the
        /// `UNUserNotificationCenter` alert/badge/sound authorization
        /// prompt — `PushTokenCenter.requestToken()` throws
        /// `.notificationPermissionDenied` *before* attempting APNs
        /// device-token registration at all (M9 bug fix: the app
        /// previously never requested this permission, so push
        /// notifications silently never displayed — see
        /// `docs/verify.md`'s "M9 追補" section). `PushNotificationSettingsView`
        /// surfaces this with a link to the Settings app
        /// (`UIApplication.openSettingsURLString`), since iOS never
        /// re-shows the system prompt once denied.
        case notificationPermissionDenied
        /// This build has no `UIApplication` to register with at all
        /// (macOS) — push isn't implemented there yet (M9 scope: iOS-only
        /// `NotificationService`, plan/PENDING.md).
        case unsupportedPlatform
    }

    /// Validates `relayURLString`, requests notification authorization +
    /// an APNs device token, registers this device with the relay, and
    /// creates a watch for every currently-configured `.password`-auth
    /// account (Gmail/`.oauth2` accounts are skipped — the relay only
    /// supports password auth in v1, `OtegamiRelayAPI.WatchAuth.Kind`'s
    /// doc comment). Persists everything via `pushSettings` as it goes, so
    /// a failure partway through (e.g. the device registers fine but one
    /// account's watch creation fails) still leaves whatever succeeded in
    /// place rather than needing to be redone from scratch.
    func enablePushNotifications(relayURLString: String) async throws {
        guard let baseURL = Self.validatedRelayURL(relayURLString) else {
            throw PushError.invalidRelayURL
        }

        let apnsToken = try await requestAPNsToken()

        let deviceId: String
        let deviceSecret: String
        if let existingId = pushSettings.deviceId, let existingSecret = try pushSettings.deviceSecret() {
            // Already registered (re-enabling after a previous disable, or
            // recovering from a partial failure) — just refresh the token
            // rather than minting a brand new device registration.
            try await pushRelayClient.updateDeviceToken(
                baseURL: baseURL,
                deviceId: existingId,
                deviceSecret: existingSecret,
                apnsToken: apnsToken,
                environment: .sandbox
            )
            deviceId = existingId
            deviceSecret = existingSecret
        } else {
            let response = try await pushRelayClient.registerDevice(baseURL: baseURL, apnsToken: apnsToken, environment: .sandbox)
            deviceId = response.deviceId
            deviceSecret = response.deviceSecret
            try pushSettings.setDeviceSecret(deviceSecret)
        }

        pushSettings.relayURLString = relayURLString
        pushSettings.deviceId = deviceId
        pushRelayURLString = relayURLString

        for account in accounts where account.authType == .password {
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }

        pushSettings.isEnabled = true
        isPushEnabled = true
    }

    /// Deletes every watch this device has registered (best-effort — a
    /// relay that's unreachable at the moment shouldn't leave the user
    /// stuck unable to turn push back off locally) and clears all local
    /// push state.
    func disablePushNotifications() async {
        if let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
           let deviceSecret = try? pushSettings.deviceSecret() {
            for (_, watchId) in pushSettings.accountWatchMap {
                try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
            }
        }
        pushSettings.reset()
        isPushEnabled = false
        pushRelayURLString = ""
    }

    /// Registers a watch for `account` if push is enabled and it doesn't
    /// already have one — called both from `enablePushNotifications` (for
    /// every existing account) and should be called again whenever a new
    /// `.password` account is added while push is already enabled.
    func registerWatchIfNeeded(for account: AccountRecord) async {
        guard isPushEnabled, account.authType == .password else { return }
        guard pushSettings.accountWatchMap[account.id] == nil else { return }
        guard let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
    }

    private func registerWatch(for account: AccountRecord, baseURL: URL, deviceSecret: String) async {
        guard let password = try? credentialStore.password(forAccountId: account.id) else { return }
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

    private func unregisterWatch(forAccountId accountId: String) async {
        guard let watchId = pushSettings.accountWatchMap[accountId] else { return }
        defer { pushSettings.setWatchId(nil, forAccountId: accountId) }
        guard let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
    }

    private func requestAPNsToken() async throws -> String {
        #if os(iOS)
        do {
            return try await PushTokenCenter.shared.requestToken()
        } catch PushTokenCenter.PushTokenError.notificationPermissionDenied {
            throw PushError.notificationPermissionDenied
        } catch {
            throw PushError.noDeviceToken
        }
        #else
        throw PushError.unsupportedPlatform
        #endif
    }

    /// `https://` required; `http://localhost`/`http://127.0.0.1` (any
    /// port) exempted for local dev against a relay run with `swift run`
    /// on the same machine (plan: "リレー URL 入力 (https 必須、ローカル開発時
    /// のみ http://localhost 許可)"). Returns `nil` for anything else,
    /// including a URL that fails to parse at all.
    /// `nonisolated`: pure string parsing, no `AppEnvironment` state —
    /// called both from `@MainActor` call sites in this file and from
    /// `CloudAccountDirectory` (M11), which isn't `@MainActor`.
    nonisolated static func validatedRelayURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), let url = components.url else { return nil }
        if components.scheme == "https" { return url }
        if components.scheme == "http", let host = components.host, host == "localhost" || host == "127.0.0.1" {
            return url
        }
        return nil
    }
}
