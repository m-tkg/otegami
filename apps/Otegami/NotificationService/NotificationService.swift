import GRDB
import GoogleOAuth
import MailTransport
import MailTransportMailCore
import MicrosoftOAuth
import OtegamiCore
import OtegamiRelayAPI
import OtegamiStore
import PushRelayClient
import Security
import SyncEngine
import UserNotifications
import os

/// Handles otegami-relay's `mutable-content` push (M9, plan §7's privacy
/// design: the payload only ever carries `accountId`/`uidNext`, never
/// subject/sender/body — see `OtegamiRelayAPI.PushNotificationPayload`).
/// This Extension re-fetches just the newest message's envelope over IMAP
/// itself and rewrites the notification's title/body before it's shown.
///
/// Flow:
/// 1. Decode `accountId`/`uidNext` from `userInfo`.
/// 2. Read this device's `NotificationContentPreferences` (Task #176: the
///    3 `PushNotificationSettingsView` toggles) from the shared App Group
///    `UserDefaults` suite — see `notificationContentPreferences()`'s doc
///    comment. If every one is off, stop right here: no account lookup, no
///    Keychain read, no IMAP connection at all (Task #176's own "無駄な
///    通信を避ける" ask) — the notification is left exactly as `didReceive`
///    already set it (`NotificationEnrichment.genericTitle`/`genericBody`).
/// 3. Otherwise, open the shared `AppDatabase` (App Group container,
///    read-only in practice — see `AppDatabase.makeShared(appGroupIdentifier:)`'s
///    doc comment) and look up that account's `AccountRecord`.
/// 4. Resolve credentials for `account.authType`:
///    - `.password`: read the IMAP password from the shared Keychain
///      Access Group, same as always.
///    - `.oauth2` (Task #177 — Gmail/Outlook accounts, following up on
///      Task #175's relay-side OAuth watch support): read the stored OAuth
///      refresh token from the shared Keychain (`GoogleOAuth.TokenStore`/
///      `MicrosoftOAuth.TokenStore`, the exact same types
///      `AppEnvironment.auth(for:)` already uses for a foregrounded sync —
///      see `oauthAccessToken(for:)`) and exchange it for a fresh access
///      token, racing that exchange against `oauthTokenFetchTimeout`
///      (`PushOAuthAccessTokenResolution`) so a slow/hanging token
///      endpoint can't consume this Extension's entire ~30 second OS
///      budget and leave no time for the IMAP half below. Any failure at
///      any point (build has no Client ID configured, no refresh token
///      stored, the refresh itself failing, or the timeout firing) is
///      collapsed into "no credential" and falls straight through to step
///      6's generic fallback — same degraded-but-not-broken behavior as a
///      `.password` account with no Keychain entry.
/// 5. Connect, `SELECT` the watched mailbox, `FETCH` the envelope for UID
///    `uidNext - 1` (the just-arrived message) — and, only if
///    `showsBodyPreview` is on, that same message's body too (a
///    `FETCH`-the-whole-message operation, meaningfully heavier than the
///    envelope-only fetch, so it's skipped whenever the user has that
///    toggle off, same "don't fetch what nothing will use" reasoning as
///    step 2) — and fill in the notification's title/body according to
///    `NotificationEnrichment`.
/// 6. Any failure at any step (account not found, no password, IMAP
///    connect/auth/fetch failure) falls back to a generic "新着メールが
///    あります" body — the notification still shows, just without the
///    enrichment — rather than dropping the notification. A body-fetch
///    failure specifically (step 5's second fetch) only drops the body
///    preview line, not the whole enrichment — the envelope-derived
///    title/subject (if any) still applies.
///
/// **On "件数のみ" for the all-off case**: Task #176's own request text
/// floated "新着メールがあります/複数件なら件数のみ" as an example of what
/// an all-toggles-off notification could look like. This deliberately
/// always uses the plain generic text instead, never a "N件" count: the
/// push payload here carries only one `accountId`/`uidNext` pair (no
/// message count), and the only two ways to get one — an extra IMAP round
/// trip just to count, or reading the locally-synced unread count out of
/// the shared `AppDatabase` — are both wrong for this specific case. The
/// former defeats the entire point of skipping the fetch. The latter would
/// be *stale*: this Extension never inserts the new message into the local
/// database itself (see the badge-increment doc comment on `Task` below),
/// so a DB-read count reflects only messages already synced *before* this
/// push arrived — not the new arrival(s) that triggered it — which would
/// be actively misleading rather than merely imprecise.
///
/// `serviceExtensionTimeWillExpire()` delivers whatever's on hand
/// (best-effort — the generic fallback, if step 4 hasn't completed yet)
/// before the OS's ~30 second budget runs out.
///
/// **Diagnostic logging (Task #211)**: 実機で「通知は届くが差出人・件名が
/// 出ない」報告があり (Gmail/iCloud は問題なし、Yahoo! JAPAN だけ)、この
/// ファイルは以前どの段階で失敗しているか一切ログを残していなかった —
/// `enrich(payload:)` のあらゆる失敗が同じ「無言で汎用文言のまま」に
/// 見えてしまい、原因を切り分けられなかった。今は各段階
/// (preferences/account lookup/credential/IMAP connect/select/envelope
/// fetch/body fetch) の成否を `logger` (`os.Logger`, `.notice`以上) へ
/// 記録する。`NotificationServiceDiagnostics.summarize(category:
/// underlyingDescription:)` (`PushRelayClient`, ユニットテスト済み) が
/// 実際のカテゴリ分類/レート制限検知/PII 除去を行い、ここは
/// `MailTransportError` の `switch` とログ呼び出しだけを担う。**本文・
/// 件名・差出人・資格情報は一切ログに出さない** — `authenticationFailed`
/// の `underlyingDescription` (サーバーがログイン名をエコーし返す実装が
/// あり得る) も意図的に落とす。実機での見方・既知の疑い (Yahoo の同時
/// 接続/レート制限) は `docs/architecture.md` の落とし穴 i. の追記
/// (Task #211) を参照。
// `@unchecked Sendable`: `UNNotificationServiceExtension` doesn't itself
// promise `didReceive(_:withContentHandler:)`/`serviceExtensionTimeWillExpire()`
// run on any particular actor, so the compiler can't otherwise prove the
// `Task { ... }` in `didReceive` capturing `self` is race-free — but the OS
// only ever has one `didReceive` in flight per extension process instance,
// and `contentHandler`/`bestAttemptContent` are only ever touched from
// that single in-flight call's continuation, so there's no actual
// concurrent access to reason about.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    /// Set once at the top of `didReceive`, read back by `deliver()` (from
    /// either the normal completion path or `serviceExtensionTimeWillExpire()`)
    /// to log how much of the ~30 second OS budget this run actually used —
    /// see this type's "Diagnostic logging" doc comment. `nil` only if
    /// `deliver()` is somehow reached before `didReceive` ever ran (doesn't
    /// happen in practice; guards the log line, not correctness).
    private var startedAt: Date?

    /// Task #211 — see this type's "Diagnostic logging" doc comment for
    /// what gets written here and why. `com.mtkg.otegami` matches every
    /// other `Logger(subsystem:category:)` call site in the app target
    /// (e.g. `AppDatabase.swift`).
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "NotificationService")

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        startedAt = Date()
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = "Otegami"
        content.body = "新着メールがあります"
        bestAttemptContent = content

        // Parsed synchronously, before spawning the Task below, so the
        // escaping closure only ever captures a plain `Sendable` struct —
        // not `request` (a `UNNotificationRequest`, not provably safe to
        // access concurrently) itself. `enrich(payload:)` below reads/
        // writes `self.bestAttemptContent` rather than taking `content` as
        // a parameter too, for the same reason: capturing the very same
        // `UNMutableNotificationContent` instance both directly and via
        // `self` is what the compiler can't prove race-free, not `self`
        // alone (this class is `@unchecked Sendable`).
        let payload = Self.parsePayload(request.content.userInfo)
        if let payload {
            Self.logger.notice("didReceive: accountId=\(payload.accountId, privacy: .public) uidNext=\(payload.uidNext, privacy: .public)")
        } else {
            Self.logger.notice("didReceive: push carried no accountId/uidNext — nothing to enrich, leaving generic content")
        }

        Task {
            if let payload {
                // H「アプリアイコンの未読バッジ」— best-effort increment from
                // whatever count `AppEnvironment.restartBadgeObservationIfNeeded`
                // last wrote to the shared App Group `UserDefaults` suite.
                // Setting `content.badge` here (rather than calling
                // `UNUserNotificationCenter.setBadgeCount` from this
                // Extension process) is the actual supported mechanism for
                // an Extension to affect the badge — the OS applies it the
                // moment this notification is delivered. This is
                // deliberately just "+1", not the true unread count: the
                // Extension never inserts the new message into the shared
                // database itself (only `enrich(payload:)`'s own read-only
                // envelope fetch, for display text), so it has no way to
                // compute the *true* post-sync count here. The next time
                // the main app runs its own live `ValueObservation` (any
                // foreground/sync/read-toggle — `AppEnvironment
                // .restartBadgeObservationIfNeeded`'s doc comment) it
                // overwrites this with the real number, self-correcting
                // any drift from multiple pushes arriving before that.
                incrementSharedBadgeCount()
                await enrich(payload: payload)
            }
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called by the OS shortly before the ~30 second budget for this
        // extension process runs out — deliver whatever's on hand (the
        // generic fallback body set in didReceive, if enrich(payload:)
        // hasn't finished) rather than let the notification disappear.
        // Logged unconditionally (Task #211): the immediately-following
        // `deliver()` log's `elapsedMs` tells a real device's next
        // reproduction whether this run actually timed out (elapsedMs near
        // 30000, this line present) versus finished normally well under
        // budget (this line absent).
        Self.logger.notice("serviceExtensionTimeWillExpire: OS budget about to run out — delivering best-effort content")
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        if let startedAt {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Self.logger.notice("deliver: elapsedMs=\(elapsedMs, privacy: .public)")
        }
        contentHandler(bestAttemptContent)
    }

    /// H「アプリアイコンの未読バッジ」— see the `Task` block's doc comment in
    /// `didReceive(_:withContentHandler:)` for the overall "increment here,
    /// main app self-corrects to the true count later" design.
    private func incrementSharedBadgeCount() {
        guard let appGroupIdentifier = Self.appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        let newCount = defaults.integer(forKey: Self.sharedBadgeCountKey) + 1
        defaults.set(newCount, forKey: Self.sharedBadgeCountKey)
        bestAttemptContent?.badge = NSNumber(value: newCount)
    }

    /// Mirrored copy of `BadgeCenter.sharedCountKey`
    /// (`apps/Otegami/Sources/Support/BadgeCenter.swift`) — must match
    /// byte-for-byte (same reasoning as `NotificationEnrichment` below:
    /// this Extension target doesn't share source files with the app
    /// target, per `OtegamiAppGroup.swift`'s doc comment).
    private static let sharedBadgeCountKey = "badge.sharedCount"

    private func enrich(payload: PushNotificationPayload) async {
        let preferences = Self.notificationContentPreferences()
        // Task #176: every toggle off -> nothing below would ever be used,
        // so skip the account/Keychain lookup and the IMAP connection
        // entirely — see this type's doc comment, step 2.
        guard NotificationEnrichment.needsFetch(preferences: preferences) else {
            Self.logger.notice("enrich: all 3 content toggles are off — skipping account lookup/IMAP entirely")
            return
        }
        Self.logger.notice("""
        enrich: preferences showsSender=\(preferences.showsSender, privacy: .public) \
        showsSubject=\(preferences.showsSubject, privacy: .public) \
        showsBodyPreview=\(preferences.showsBodyPreview, privacy: .public)
        """)

        let account: AccountRecord
        do {
            guard let found = try await Self.lookupAccount(id: payload.accountId) else {
                Self.logger.notice("enrich: account lookup: no row for this accountId — falling back to generic")
                return
            }
            account = found
        } catch {
            Self.logger.error("enrich: account lookup: shared AppDatabase read threw — falling back to generic: \(String(describing: error), privacy: .public)")
            return
        }
        Self.logger.notice("""
        enrich: account lookup: found kind=\(account.kind.rawValue, privacy: .public) \
        authType=\(account.authType.rawValue, privacy: .public) host=\(account.imapHost, privacy: .public)
        """)

        guard let auth = await Self.resolveAuth(for: account) else {
            Self.logger.notice("enrich: credential: no usable credential resolved (see preceding log line) — falling back to generic")
            return
        }
        Self.logger.notice("enrich: credential: resolved, connecting")

        let session = MailCoreIMAPSession(config: account.imapConfig)
        let mailbox = "INBOX"

        do {
            try await session.connect(auth: auth)
            Self.logger.notice("enrich: connect: succeeded")
        } catch {
            Self.log(error, stage: "connect")
            await session.disconnect()
            return
        }

        do {
            _ = try await session.select(mailbox)
            Self.logger.notice("enrich: select: succeeded")
        } catch {
            Self.log(error, stage: "select")
            await session.disconnect()
            return
        }

        let latestUID = UInt32(max(payload.uidNext - 1, 1))
        let envelopes: [FetchedEnvelope]
        do {
            envelopes = try await session.fetchEnvelopes(mailboxPath: mailbox, uids: .uid(latestUID), batchSize: 1)
            Self.logger.notice("enrich: fetchEnvelope: succeeded count=\(envelopes.count, privacy: .public)")
        } catch {
            Self.log(error, stage: "fetchEnvelope")
            await session.disconnect()
            return
        }

        guard let envelope = envelopes.first else {
            Self.logger.notice("""
            enrich: fetchEnvelope: no results for uid=\(latestUID, privacy: .public) \
            (uidNext=\(payload.uidNext, privacy: .public)) — already expunged/moved, \
            or a uidNext/UID mismatch; falling back to generic
            """)
            await session.disconnect()
            return
        }

        // Only pay for the (meaningfully heavier) whole-message fetch when
        // `showsBodyPreview` is actually on — see this type's doc comment,
        // step 5. A body-fetch failure here only drops the preview line,
        // not the envelope-derived title/subject already in hand, so it's
        // logged but never treated as this whole call failing.
        var bodyPreviewSourceText: String?
        if preferences.showsBodyPreview {
            do {
                bodyPreviewSourceText = try await session.fetchBody(mailboxPath: mailbox, uid: latestUID).plainText
                Self.logger.notice("enrich: fetchBody: succeeded")
            } catch {
                Self.log(error, stage: "fetchBody")
            }
        }

        let sender = envelope.from.first
        bestAttemptContent?.title = NotificationEnrichment.title(
            preferences: preferences, senderName: sender?.name, senderAddress: sender?.address
        )
        bestAttemptContent?.body = NotificationEnrichment.body(
            preferences: preferences, subject: envelope.subject, bodyPreviewSourceText: bodyPreviewSourceText
        )
        Self.logger.notice("enrich: applied enrichment to notification content")
        await session.disconnect()
    }

    /// Classifies `error` (expected to be a `MailTransport.MailTransportError`
    /// from one of `enrich(payload:)`'s IMAP calls, but handled defensively
    /// for anything `Error`-shaped) and writes exactly one `.error`-level
    /// OSLog line naming `stage` and the failure category — see this type's
    /// "Diagnostic logging" doc comment. Only unwraps the
    /// `MailTransportError` case here (a `switch`, not practically unit
    /// testable — it's a straight one-to-one string mapping); the actual
    /// redaction/rate-limit-detection logic lives in
    /// `NotificationServiceDiagnostics.summarize(category:
    /// underlyingDescription:)` (`PushRelayClient`), which is.
    private static func log(_ error: Error, stage: String) {
        let category: String
        let underlyingDescription: String?
        switch error {
        case let transportError as MailTransportError:
            switch transportError {
            case .connectionFailed(let description):
                category = "connectionFailed"
                underlyingDescription = description
            case .authenticationFailed(let description):
                category = "authenticationFailed"
                underlyingDescription = description
            case .serverError(let description):
                category = "serverError"
                underlyingDescription = description
            case .malformedResponse(let description):
                category = "malformedResponse"
                underlyingDescription = description
            case .mailboxNotFound(let path):
                category = "mailboxNotFound"
                underlyingDescription = path
            case .notConnected:
                category = "notConnected"
                underlyingDescription = nil
            case .cancelled:
                category = "cancelled"
                underlyingDescription = nil
            case .notImplemented(let description):
                category = "notImplemented"
                underlyingDescription = description
            case .invalidAddress:
                category = "invalidAddress"
                underlyingDescription = nil
            }
        default:
            category = "unknown"
            underlyingDescription = String(describing: type(of: error))
        }

        let summary = NotificationServiceDiagnostics.summarize(category: category, underlyingDescription: underlyingDescription)
        if let detail = summary.logDetail {
            Self.logger.error("""
            enrich: \(stage, privacy: .public) failed category=\(summary.category, privacy: .public) \
            rateLimited=\(summary.looksRateLimited, privacy: .public) detail=\(detail, privacy: .public)
            """)
        } else {
            Self.logger.error("""
            enrich: \(stage, privacy: .public) failed category=\(summary.category, privacy: .public) \
            rateLimited=\(summary.looksRateLimited, privacy: .public)
            """)
        }
    }

    /// Task #176: this device's current `NotificationContentPreferences`,
    /// read from the shared App Group `UserDefaults` suite —
    /// `NotificationContentSettingsStore.mirrorToAppGroup()` (app-side) is
    /// what keeps that suite's copy of these 3 keys up to date; this
    /// Extension only ever reads them, never writes. Falls back to
    /// `.allEnabled` (today's pre-#176 behavior) when the App Group
    /// container isn't reachable at all, or a key was never written there
    /// yet (a device that upgraded to this app version but hasn't launched
    /// the main app even once since — `AppEnvironment.init()`'s unconditional
    /// launch-time mirror call is what normally prevents that gap, but this
    /// Extension can in principle run before the containing app ever has).
    private static func notificationContentPreferences() -> NotificationContentPreferences {
        guard let appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return .allEnabled
        }
        return NotificationContentPreferences(
            showsSender: (defaults.object(forKey: NotificationContentPreferences.showsSenderKey) as? Bool) ?? true,
            showsSubject: (defaults.object(forKey: NotificationContentPreferences.showsSubjectKey) as? Bool) ?? true,
            showsBodyPreview: (defaults.object(forKey: NotificationContentPreferences.showsBodyPreviewKey) as? Bool) ?? true
        )
    }

    // MARK: - Payload / account lookup

    private static func parsePayload(_ userInfo: [AnyHashable: Any]) -> PushNotificationPayload? {
        guard let accountId = userInfo["accountId"] as? String,
              let uidNext = userInfo["uidNext"] as? Int
        else { return nil }
        return PushNotificationPayload(accountId: accountId, uidNext: uidNext)
    }

    /// Task #192 (0xDEAD10CC 対策の調査): this `DatabasePool` shares the same
    /// App Group container/file the main app's `AppDatabase.makeShared`
    /// opens, and `AppDatabase.makeConfiguration
    /// (observesSuspensionNotifications:)` now enables GRDB's suspension
    /// observing for *any* caller that resolves to that shared container —
    /// including this Extension — so it would react correctly to a
    /// `Database.suspendNotification` if one were ever posted here. In
    /// practice none is needed: confirmed this Extension only ever reads
    /// (`dbWriter.read` below — never `.write`), so it never holds a lock
    /// capable of triggering `0xDEAD10CC` in the first place, and `database`
    /// is a local variable that goes out of scope (closing the connection
    /// via GRDB's own `deinit`, matching `DatabaseReader.close()`'s doc
    /// comment — "you do not have to call this method... automatically
    /// closed when they are deinitialized") the moment this function
    /// returns, well before the OS could ever suspend this short-lived
    /// Extension process. See `docs/architecture.md`'s Known pitfalls
    /// (Task #192) for the full writeup.
    private static func lookupAccount(id: String) async throws -> AccountRecord? {
        let database = try AppDatabase.makeShared(appGroupIdentifier: appGroupIdentifier)
        return try await database.dbWriter.read { db in
            try AccountRecord.fetchOne(db, key: id)
        }
    }

    private static func password(forAccountId accountId: String) throws -> String? {
        let query: [String: Any] = {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.mtkg.otegami.account-password",
                kSecAttrAccount as String: accountId,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let keychainAccessGroup {
                query[kSecAttrAccessGroup as String] = keychainAccessGroup
            }
            return query
        }()
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // `status` is a plain `OSStatus` (a numeric code, e.g.
            // `errSecItemNotFound`/`-25300` vs. `errSecInteractionNotAllowed`
            // /`-25308` — the latter meaning the Keychain item's data
            // protection class requires the device to be unlocked, which
            // this Extension can run before) — not the password itself, so
            // safe to log (Task #211).
            Self.logger.notice("auth: password branch: SecItemCopyMatching failed status=\(status, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Task #177: OAuth (`.oauth2`) account credentials

    /// The `MailAuth` `enrich(payload:)` connects with, for either
    /// `authType` — `.password`'s existing Keychain-password lookup, or
    /// (Task #177) `.oauth2`'s Keychain-refresh-token-to-access-token
    /// exchange (`oauthAccessToken(for:)`). `nil` on any failure, meaning
    /// "no usable credential" — the caller's existing generic-fallback
    /// behavior applies identically regardless of which branch failed.
    private static func resolveAuth(for account: AccountRecord) async -> MailAuth? {
        switch account.authType {
        case .password:
            guard let password = try? Self.password(forAccountId: account.id) else { return nil }
            return .password(username: account.imapUsername, password: password)
        case .oauth2:
            guard let accessToken = await Self.oauthAccessToken(for: account) else {
                Self.logger.notice("auth: oauth2 branch: no access token resolved (see preceding log line for which sub-reason)")
                return nil
            }
            return .xoauth2(username: account.imapUsername, accessToken: accessToken)
        }
    }

    /// Well under the ~30 second OS budget for this Extension process's
    /// entire `didReceive(_:withContentHandler:)` call — leaves comfortable
    /// room for the IMAP connect/`SELECT`/envelope-fetch (and, if
    /// `showsBodyPreview` is on, the body fetch) that follows once a token
    /// is in hand. `oauthAccessToken(for:)` bounds *both* the transport
    /// level (the `URLSession` used for the token-endpoint request) and the
    /// overall exchange (`PushOAuthAccessTokenResolution`'s race) to this
    /// same value, so a hung TCP connection can't itself be the thing that
    /// silently burns the whole budget before the race even gets a chance
    /// to fire.
    private static let oauthTokenFetchTimeout: TimeInterval = 10

    /// A currently-valid XOAUTH2 access token for `account` (`.oauth2`-kind
    /// only — Gmail/Outlook), or `nil` on any failure: this build has no
    /// Client ID configured for `account.kind`'s provider (`OAuthConfig`),
    /// no refresh token is stored for this account (never signed in via
    /// this provider, or a previous `invalid_grant` already wiped it —
    /// see `GoogleOAuth.TokenStore`/`MicrosoftOAuth.TokenStore`'s own doc
    /// comments), the refresh itself failed, or it simply took longer than
    /// `oauthTokenFetchTimeout` (`PushOAuthAccessTokenResolution`).
    ///
    /// Uses the exact same `TokenStore`/OAuth client types
    /// `AppEnvironment.auth(for:)` uses for a foregrounded `.oauth2` sync
    /// (`AppEnvironment.swift`'s "Auth resolution" section) — a fresh
    /// `TokenStore` instance per call (this Extension is a short-lived,
    /// per-push process; there's no long-lived `AppEnvironment` to hold
    /// one), backed by the same default `KeychainRefreshTokenStore` (no
    /// explicit access group — see this file's doc comment on why that
    /// alone is already enough to read what the main app wrote: both
    /// targets' entitlements list the same single Keychain Access Group,
    /// which is therefore each process's *default* group too). A
    /// successful refresh here that hits `invalid_grant` has the exact
    /// same side effect it would in the main app: `TokenStore` wipes the
    /// now-dead refresh token from that same shared Keychain, so the next
    /// time the main app itself calls `auth(for:)` it correctly reports
    /// "要再認証" rather than retrying a token Google has already rejected.
    private static func oauthAccessToken(for account: AccountRecord) async -> String? {
        guard account.kind == .gmail || account.kind == .microsoft else {
            Self.logger.notice("auth: oauth2 branch: account.kind is neither gmail nor microsoft — unreachable in practice, no token")
            return nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = oauthTokenFetchTimeout
        configuration.timeoutIntervalForResource = oauthTokenFetchTimeout
        let urlSession = URLSession(configuration: configuration)
        let sessionRunner = UnreachableAuthorizationSessionRunner()

        switch account.kind {
        case .gmail:
            guard let clientId = OAuthConfig.googleClientId else {
                Self.logger.notice("auth: oauth2 branch (gmail): this build has no Google Client ID configured")
                return nil
            }
            let client = GoogleOAuthClient(
                endpoints: .standard(clientId: clientId),
                sessionRunner: sessionRunner,
                urlSession: urlSession
            )
            let tokenStore = GoogleOAuth.TokenStore(refresher: client)
            let token = await PushOAuthAccessTokenResolution.resolve(timeout: oauthTokenFetchTimeout) {
                try await tokenStore.accessToken(for: account.id)
            }
            // Collapses "no stored refresh token" / "refresh itself failed
            // (e.g. invalid_grant)" / "timed out" into one line by design —
            // `PushOAuthAccessTokenResolution`'s own doc comment: "this
            // type never logs at all", so this is the closest this
            // Extension gets to knowing *that* the gmail branch lost
            // without ever touching the token value itself.
            if token == nil {
                Self.logger.notice("auth: oauth2 branch (gmail): token resolution returned nil (no refresh token / refresh failed / timed out)")
            }
            return token
        case .microsoft:
            guard let clientId = OAuthConfig.microsoftClientId else {
                Self.logger.notice("auth: oauth2 branch (microsoft): this build has no Microsoft Client ID configured")
                return nil
            }
            let client = MicrosoftOAuthClient(
                endpoints: .standard(clientId: clientId),
                sessionRunner: sessionRunner,
                urlSession: urlSession
            )
            let tokenStore = MicrosoftOAuth.TokenStore(refresher: client)
            let token = await PushOAuthAccessTokenResolution.resolve(timeout: oauthTokenFetchTimeout) {
                try await tokenStore.accessToken(for: account.id)
            }
            if token == nil {
                Self.logger.notice("auth: oauth2 branch (microsoft): token resolution returned nil (no refresh token / refresh failed / timed out)")
            }
            return token
        case .generic, .icloud:
            return nil
        }
    }

    /// `Bundle.main` here is the Extension's own bundle (not the
    /// containing app's) — see `apps/Otegami/Sources/Support
    /// /OtegamiAppGroup.swift`'s doc comment on why this is a separate,
    /// identically-named copy rather than a shared import.
    private static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiAppGroupIdentifier") as? String
    }

    private static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiKeychainAccessGroup") as? String
    }
}

/// Task #177: mirrors `GoogleOAuthConfig`/`MicrosoftOAuthConfig`
/// (`apps/Otegami/Sources/Features/Settings/Auth/`) — reads the same two
/// xcconfig-sourced Client ID `Info.plist` keys those two enums read, but
/// against *this* target's own `Bundle.main` (this Extension's bundle, not
/// the containing app's — same reasoning `appGroupIdentifier`/
/// `keychainAccessGroup` above already document, and why this is a small
/// separate copy rather than an import: those two enums live in the
/// `Otegami` app target itself, which an app extension target can't depend
/// on). `project.yml`'s `NotificationService` target now declares both
/// `GOOGLE_OAUTH_CLIENT_ID`/`OTEGAMI_MICROSOFT_CLIENT_ID` in its own
/// `info.properties` to make that possible.
private enum OAuthConfig {
    static var googleClientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_OAUTH_CLIENT_ID") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    static var microsoftClientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_MICROSOFT_CLIENT_ID") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }
}

/// `GoogleOAuthClient`/`MicrosoftOAuthClient` both require a concrete
/// `AuthorizationSessionRunning` conformer at `init`, but this Extension
/// only ever calls `TokenStore.accessToken(for:)` — a plain silent refresh,
/// never the interactive `requestAuthorization()` flow that's the only
/// caller of `sessionRunner.run(authorizationURL:callbackURLScheme:)`.
/// Satisfies both packages' identically-shaped (but distinct) protocols
/// with one throwing implementation, so a latent bug that somehow *did*
/// reach this path degrades to "this account's push falls back to the
/// generic notification body" (same as every other failure in
/// `oauthAccessToken(for:)`) rather than crashing the Extension process —
/// there is no UI to present a web authentication session from here even
/// if it were somehow reached.
private struct UnreachableAuthorizationSessionRunner: GoogleOAuth.AuthorizationSessionRunning, MicrosoftOAuth.AuthorizationSessionRunning {
    struct UnexpectedCallError: Error {}

    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        throw UnexpectedCallError()
    }
}

/// Mirrored copy of `PushRelayClient.NotificationContentPreferences`
/// (Task #176) — see `NotificationEnrichment`'s own doc comment right below
/// for why this type stays a separately-compiled copy even though Task
/// #177 added a real `import PushRelayClient` to this target (for
/// `PushOAuthAccessTokenResolution` only — see `oauthAccessToken(for:)`).
/// The 3 key names must match
/// `apps/Otegami/Sources/Support/NotificationContentSettingsStore.swift`'s
/// (and by extension `AppSettingsCloudDirectory`'s allowlist entries for
/// them) byte-for-byte — `notificationContentPreferences()` above is the
/// only reader of these 3 strings on this side.
private struct NotificationContentPreferences {
    static let showsSenderKey = "notification.showsSender"
    static let showsSubjectKey = "notification.showsSubject"
    static let showsBodyPreviewKey = "notification.showsBodyPreview"

    var showsSender: Bool
    var showsSubject: Bool
    var showsBodyPreview: Bool

    static let allEnabled = NotificationContentPreferences(showsSender: true, showsSubject: true, showsBodyPreview: true)
}

/// Mirrored copy of `PushRelayClient.NotificationEnrichment`
/// (`packages/OtegamiKit/Sources/PushRelayClient/NotificationEnrichment
/// .swift`) — kept as its own separately-compiled copy even though Task
/// #177 added a real `import PushRelayClient` to this target (for
/// `PushOAuthAccessTokenResolution` only, a type this file's Task #176
/// era predates). Switching this pre-existing, already-tested duplicate
/// over to the real import too was deliberately left out of Task #177's
/// scope — no behavior here needed to change, so there was nothing to
/// gain from touching it beyond the risk of a subtle regression (same
/// reasoning `OtegamiAppGroup.swift`'s existing duplication doc comment
/// gives for the *App Group id*/*Keychain Access Group* copies). The
/// algorithm is unit-tested there (`NotificationEnrichmentTests`); this
/// copy is intentionally kept tiny and byte-for-byte identical so it needs
/// no independent test coverage of its own. Reuses `OtegamiCore
/// .SnippetBuilder` directly (rather than re-deriving its truncation
/// algorithm too) since `OtegamiCore` is already a real dependency of this
/// extension target (`project.yml`).
private enum NotificationEnrichment {
    static let genericTitle = "Otegami"
    static let genericBody = "新着メールがあります"

    static func needsFetch(preferences: NotificationContentPreferences) -> Bool {
        preferences.showsSender || preferences.showsSubject || preferences.showsBodyPreview
    }

    static func title(preferences: NotificationContentPreferences, senderName: String?, senderAddress: String?) -> String {
        guard preferences.showsSender else { return genericTitle }
        if let senderName, !senderName.isEmpty { return senderName }
        if let senderAddress, !senderAddress.isEmpty { return senderAddress }
        return genericTitle
    }

    static func body(
        preferences: NotificationContentPreferences,
        subject: String?,
        bodyPreviewSourceText: String?,
        bodyPreviewMaxLength: Int = 120
    ) -> String {
        var lines: [String] = []
        if preferences.showsSubject, let subject, !subject.isEmpty {
            lines.append(subject)
        }
        if preferences.showsBodyPreview,
           let preview = SnippetBuilder.make(from: bodyPreviewSourceText, maxLength: bodyPreviewMaxLength) {
            lines.append(preview)
        }
        guard !lines.isEmpty else { return genericBody }
        return lines.joined(separator: "\n")
    }
}
