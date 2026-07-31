import GoogleOAuth
import GRDB
import MailTransport
import MicrosoftOAuth
import OtegamiStore
import SyncEngine

@MainActor
extension AppEnvironment {
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
    func retryPendingCredentialIfAvailable(_ account: AccountRecord) async {
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
            // Task #116 第2段: `.oauth2` alone doesn't say *which* provider's
            // tokens to use — `account.kind` does. Each branch below is a
            // near-identical mirror of the other, just against a different
            // `TokenStore`/error type (`GoogleOAuth.TokenStoreError` vs
            // `MicrosoftOAuth.TokenStoreError` — same case names, different
            // types, since the two OAuth packages are deliberately
            // independent of each other).
            switch account.kind {
            case .gmail:
                guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
                do {
                    let accessToken = try await tokenStore.accessToken(for: account.id)
                    return .xoauth2(username: account.imapUsername, accessToken: accessToken)
                } catch GoogleOAuth.TokenStoreError.reauthenticationRequired {
                    await setNeedsReauth(true, for: account)
                    throw GoogleOAuth.TokenStoreError.reauthenticationRequired
                }
            case .microsoft:
                guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
                do {
                    let accessToken = try await microsoftTokenStore.accessToken(for: account.id)
                    return .xoauth2(username: account.imapUsername, accessToken: accessToken)
                } catch MicrosoftOAuth.TokenStoreError.reauthenticationRequired {
                    await setNeedsReauth(true, for: account)
                    throw MicrosoftOAuth.TokenStoreError.reauthenticationRequired
                }
            case .generic, .icloud:
                // Shouldn't be reachable — only `.gmail`/`.microsoft`-kind
                // accounts are ever created with `authType: .oauth2` (every
                // account-creation call site pairs the two together). Not a
                // `fatalError` regardless, matching this method's existing
                // "handled explicitly rather than force-unwrapping" style
                // for the sibling `AuthResolutionError.oauthUnavailable`
                // case just above.
                throw AuthResolutionError.oauthUnavailable
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
    /// needed). Used by `GmailAccountSetupView` for a brand-new account
    /// (always `promptConsent: true`, the default — see
    /// `GoogleOAuthEndpoints.authorizationURL(pkce:state:promptConsent:)`'s
    /// doc comment for why a first-time grant needs the consent screen
    /// forced) and — with the returned tokens simply re-stored under an
    /// *existing* account id — by `reauthenticateGmailAccount(_:)` below,
    /// which decides `promptConsent` for itself.
    /// Throws `AuthResolutionError.oauthUnavailable` if this build has no
    /// Client ID (shouldn't be reachable: the Gmail button is disabled in
    /// that case).
    func requestGmailAuthorization(promptConsent: Bool = true) async throws -> (email: String, tokens: GoogleOAuthTokens) {
        guard let googleOAuthClient else { throw AuthResolutionError.oauthUnavailable }
        let tokens = try await googleOAuthClient.requestAuthorization(promptConsent: promptConsent)
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
            smtpUsername: email,
            // Task #72「自動割当の改善」: see this call's identical doc
            // comment on `AccountSetupView.saveAccount`/
            // `ICloudAccountSetupView.saveAccount`.
            labelColorKey: leastUsedAccountLabelColorKey(),
            sortOrder: nextAccountSortOrder()
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
    /// Google's consent screen (when it's shown at all — see below) always
    /// shows the account picker, so the user could pick a different one;
    /// that's treated as "the user's explicit choice", not an error to
    /// guard against here (a mismatch would just start delivering a
    /// different inbox's mail, which is immediately obvious rather than a
    /// silent data-integrity problem).
    ///
    /// Task #47 (「毎回gmailアカウント追加時に警告のようなものが出るのが
    /// つらい」): before requesting authorization, checks whether the
    /// account's last-known granted scope (`TokenStore.diagnosticScope(for:)`,
    /// the same forced-refresh lookup `AccountEditView`'s「権限の診断」uses)
    /// already covers everything this build's `scope` asks for
    /// (`GoogleOAuthEndpoints.isSatisfied(byGrantedScope:)`). If so, the
    /// authorization request omits `prompt=consent` entirely — Google
    /// silently reissues a code for the existing grant with no screen and
    /// no "アプリは確認されていません" warning, so a routine token refresh
    /// (the common case: nothing about `scope` changed since the account
    /// was last connected) is a single tap with no consent screen at all.
    /// Only when the stored scope is missing, stale, or genuinely
    /// insufficient (a new scope was added to `scope` since this account
    /// last connected, or the diagnostic lookup itself failed) does this
    /// fall back to forcing the consent screen, the same as before this
    /// fix — see `GoogleOAuthEndpoints.authorizationURL(pkce:state:promptConsent:)`'s
    /// doc comment for the full reasoning.
    func reauthenticateGmailAccount(_ account: AccountRecord) async throws {
        guard let tokenStore, let endpoints = GoogleOAuthConfig.endpoints else {
            throw AuthResolutionError.oauthUnavailable
        }
        let grantedScope = try? await tokenStore.diagnosticScope(for: account.id)
        let promptConsent = !endpoints.isSatisfied(byGrantedScope: grantedScope)
        let (_, tokens) = try await requestGmailAuthorization(promptConsent: promptConsent)
        try await tokenStore.storeInitialTokens(tokens, accountId: account.id)
        await setNeedsReauth(false, for: account)
        // 実機バグ修正: `GoogleProfilePhotoAvatarResolver.scopeInsufficientAccountIds`
        // のドキュメントコメント参照 — 再認証成功でこのアカウントの
        // 「スコープ不足」記憶を即座に消す。これをしないと、次にスコープ
        // 不足で401/403を踏んでいた同一プロセス内では、再認証で新しい
        // スコープを得た直後でも次回起動までGoogleプロフィール写真の
        // 取得が永久にスキップされ続ける。
        await googleProfilePhotoAvatarResolver.clearScopeInsufficientMemory(for: account.id)
    }

    /// `AccountEditView`の「権限の診断」表示専用 — `account`の現在の
    /// 付与済みスコープを Google に強制的に問い合わせて返す
    /// (`TokenStore.diagnosticScope(for:)`のドキュメントコメント参照:
    /// キャッシュされた既存トークンにはスコープ情報が付随しないため、
    /// 診断のたびに実際にリフレッシュリクエストを送る必要がある)。
    /// `.oauth2`以外のアカウントやこのビルドに`tokenStore`が無い場合は
    /// `nil`。問い合わせ自体が失敗した場合 (ネットワークエラー・
    /// リフレッシュトークン喪失等) も`nil` — このビューは「わからない」
    /// と「未許可」を区別して見せる必要があるほど厳密な用途ではなく、
    /// 失敗時は`reauthErrorMessage`側の通常のエラー表示に任せる。
    func googleGrantedScope(for account: AccountRecord) async -> String? {
        guard account.authType == .oauth2, account.kind == .gmail, let tokenStore else { return nil }
        return try? await tokenStore.diagnosticScope(for: account.id)
    }

    /// Task #42「アバター診断」— `AccountEditView`の「アバター診断」画面が
    /// タップ時に呼ぶ。`googleProfilePhotoAvatarResolver
    /// .forceRebuildDiagnostics(accountId:)`への薄い橋渡しで、実質的な
    /// 内容はそちらのドキュメントコメント参照。`.oauth2`以外のアカウント
    /// (呼び出し元がそもそもこの画面を出さない) には`nil`。
    func googleAvatarDiagnostics(for account: AccountRecord) async -> GoogleAvatarAccountDiagnostics? {
        guard account.authType == .oauth2 else { return nil }
        return await googleProfilePhotoAvatarResolver.forceRebuildDiagnostics(accountId: account.id)
    }

    // MARK: - Microsoft sign-in (Task #116 第2段)

    /// Mirrors `requestGmailAuthorization(promptConsent:)` — runs the
    /// interactive Authorization Code + PKCE flow, then reads the signed-in
    /// account's email straight out of the token response's id_token
    /// (`MicrosoftOAuthClient.fetchUserEmail(idToken:)`'s doc comment on
    /// why that needs no extra network round trip the way Google's does).
    /// Unlike Google, there's no `promptConsent` parameter to thread
    /// through — Microsoft's flow always requests `prompt=select_account`
    /// (`MicrosoftOAuthEndpoints.authorizationURL(pkce:state:)`'s doc
    /// comment), and `offline_access` alone (no forced-reconsent flag
    /// needed) already guarantees a `refresh_token` on every grant.
    func requestMicrosoftAuthorization() async throws -> (email: String, tokens: MicrosoftOAuthTokens) {
        guard let microsoftOAuthClient else { throw AuthResolutionError.oauthUnavailable }
        let tokens = try await microsoftOAuthClient.requestAuthorization()
        let email = try microsoftOAuthClient.fetchUserEmail(idToken: tokens.idToken)
        return (email, tokens)
    }

    /// Mirrors `createGmailAccount(email:displayName:tokens:)` — Outlook.com/
    /// Office 365 preset (`outlook.office365.com:993` TLS /
    /// `smtp.office365.com:587` STARTTLS, plan-specified), `kind: .microsoft`,
    /// `authType: .oauth2`. Both "Outlook" and "Office365" buttons on
    /// `AccountTypeSelectionView` call this same method — see
    /// `MicrosoftOAuthEndpoints.authorizationEndpoint`'s doc comment for why
    /// there's no server-side difference between the two entry points.
    func createMicrosoftAccount(email: String, displayName: String, tokens: MicrosoftOAuthTokens) async throws {
        guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
        let account = AccountRecord(
            displayName: displayName.isEmpty ? email : displayName,
            email: email,
            authType: .oauth2,
            kind: .microsoft,
            imapHost: "outlook.office365.com",
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: email,
            smtpHost: "smtp.office365.com",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            smtpUsername: email,
            labelColorKey: leastUsedAccountLabelColorKey(),
            sortOrder: nextAccountSortOrder()
        )
        try await microsoftTokenStore.storeInitialTokens(tokens, accountId: account.id)
        try await database.dbWriter.write { db in
            try account.insert(db)
        }

        Task {
            guard let auth = try? await self.auth(for: account) else { return }
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        Task { await pushAccountToCloud(account) }
    }

    /// Mirrors `reauthenticateGmailAccount(_:)` — re-runs the OAuth flow for
    /// an already-existing `.microsoft` account and clears `needsReauth` on
    /// success. No `isSatisfied(byGrantedScope:)`-driven "skip the consent
    /// screen" fast path the way Gmail's reauth has (Task #47) — Microsoft's
    /// `prompt=select_account` always shows the account picker regardless,
    /// so there's no silent-refresh case to special-case here.
    func reauthenticateMicrosoftAccount(_ account: AccountRecord) async throws {
        guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
        let (_, tokens) = try await requestMicrosoftAuthorization()
        try await microsoftTokenStore.storeInitialTokens(tokens, accountId: account.id)
        await setNeedsReauth(false, for: account)
    }
}
