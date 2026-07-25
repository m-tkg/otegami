import AccountCloudSync
import Foundation
import GoogleOAuth
import GRDB
import MailTransport
import MailTransportMailCore
import OtegamiRelayAPI
import OtegamiStore
import PushRelayClient
import SyncEngine

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

    init() {
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
        self.syncCoordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: { draft in MailCoreMessageBuilder.build(draft) }
        )
        self.credentialStore = KeychainCredentialStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)

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
    }

    deinit {
        accountsObservationTask?.cancel()
        if let cloudSyncNotificationObserver {
            NotificationCenter.default.removeObserver(cloudSyncNotificationObserver)
        }
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
    /// password yet — see `AccountRecord.needsReauth`'s doc comment) can
    /// have Keychain re-checked at any later point: either automatically,
    /// on every accounts-list tick (`startObservingAccounts`, cheap once
    /// resolved since this whole method becomes a no-op the moment
    /// `needsReauth` flips to `false`), or explicitly from
    /// `AccountsSettingsView`'s "再接続" button
    /// (`retryPendingCredential(for:)` below, which surfaces a failure
    /// instead of silently ignoring it). A `.gmail`/`.oauth2` account's
    /// `needsReauth` means something different (a rejected refresh token —
    /// `AppEnvironment.reauthenticateGmailAccount`'s interactive OAuth flow
    /// is the only way to clear that one), so this only ever touches
    /// `.password` accounts.
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

    enum RetryPendingCredentialError: Error {
        /// Still no Keychain password for this account — either iCloud
        /// Keychain hasn't finished syncing yet, or it's turned off
        /// entirely on this device.
        case stillMissing
    }

    /// `AccountsSettingsView`'s "再接続" button — the explicit-retry sibling
    /// of `retryPendingCredentialIfAvailable`'s automatic one, throwing
    /// `.stillMissing` instead of silently doing nothing so the button can
    /// show an error rather than just appearing to do nothing.
    func retryPendingCredential(for account: AccountRecord) async throws {
        guard account.authType == .password, try credentialStore.password(forAccountId: account.id) != nil else {
            throw RetryPendingCredentialError.stillMissing
        }
        await retryPendingCredentialIfAvailable(account)
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
                throw AuthResolutionError.missingCredential
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
    func createGmailAccount(email: String, tokens: GoogleOAuthTokens) async throws {
        guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
        let account = AccountRecord(
            displayName: email,
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
