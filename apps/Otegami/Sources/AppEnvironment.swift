import Foundation
import GoogleOAuth
import GRDB
import MailTransport
import MailTransportMailCore
import OtegamiStore
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
            database = try AppDatabase.makeShared()
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
        self.credentialStore = KeychainCredentialStore()

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

        startObservingAccounts()
    }

    deinit {
        accountsObservationTask?.cancel()
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
        try? await database.dbWriter.write { db in
            _ = try account.delete(db)
        }
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
}
