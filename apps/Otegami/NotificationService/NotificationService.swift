import GRDB
import MailTransport
import MailTransportMailCore
import OtegamiCore
import OtegamiRelayAPI
import OtegamiStore
import Security
import SyncEngine
import UserNotifications

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
/// 4. Read its IMAP password from the shared Keychain Access Group
///    (`.password`-auth accounts only). Task #175 gave Gmail/Outlook
///    (`.oauth2`) accounts a relay watch too (an OAuth refresh token
///    instead of a password), but this Extension was **not** extended to
///    match — it still only knows how to read a Keychain password and
///    plain-`LOGIN`, never XOAUTH2. A push for a `.oauth2` account's watch
///    therefore always falls through step 6's generic fallback (the
///    notification still shows, just without sender/subject enrichment) —
///    same degraded-but-not-broken behavior as any other lookup/connect
///    failure here. Extending this Extension to refresh an access token
///    and authenticate via XOAUTH2 (mirroring `MinimalIMAPClient
///    .authenticateXOAuth2` on the relay side) is tracked as a follow-up,
///    not part of Task #175's scope.
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

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
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
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
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
        guard NotificationEnrichment.needsFetch(preferences: preferences) else { return }

        guard let account = try? await Self.lookupAccount(id: payload.accountId) else { return }
        guard account.authType == .password,
              let password = try? Self.password(forAccountId: account.id)
        else { return }

        let session = MailCoreIMAPSession(config: account.imapConfig)
        do {
            try await session.connect(auth: .password(username: account.imapUsername, password: password))
            let mailbox = "INBOX"
            _ = try await session.select(mailbox)
            let latestUID = UInt32(max(payload.uidNext - 1, 1))
            let envelopes = try await session.fetchEnvelopes(mailboxPath: mailbox, uids: .uid(latestUID), batchSize: 1)

            if let envelope = envelopes.first {
                // Only pay for the (meaningfully heavier) whole-message
                // fetch when `showsBodyPreview` is actually on — see this
                // type's doc comment, step 5. `try?`, not part of the outer
                // `do`/`catch`: a body-fetch failure here should only drop
                // the preview line, not the envelope-derived title/subject
                // this call already has in hand.
                var bodyPreviewSourceText: String?
                if preferences.showsBodyPreview {
                    bodyPreviewSourceText = try? await session.fetchBody(mailboxPath: mailbox, uid: latestUID).plainText
                }

                let sender = envelope.from.first
                bestAttemptContent?.title = NotificationEnrichment.title(
                    preferences: preferences, senderName: sender?.name, senderAddress: sender?.address
                )
                bestAttemptContent?.body = NotificationEnrichment.body(
                    preferences: preferences, subject: envelope.subject, bodyPreviewSourceText: bodyPreviewSourceText
                )
            }
        } catch {
            // Leave the generic fallback content in place — see the type's
            // doc comment on why this is a silent no-op rather than
            // surfacing the error anywhere a user could see it.
        }
        await session.disconnect()
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
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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

/// Mirrored copy of `PushRelayClient.NotificationContentPreferences`
/// (Task #176) — see `NotificationEnrichment`'s own doc comment right below
/// for why this target keeps a separately-compiled copy instead of an
/// `import PushRelayClient`. The 3 key names must match
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
/// .swift`) — see that type's doc comment for why this target has its own
/// separately-compiled copy instead of an `import PushRelayClient` (same
/// reasoning as `OtegamiAppGroup.swift`'s existing duplication). The
/// algorithm is unit-tested there (`NotificationEnrichmentTests`); this
/// copy is intentionally kept tiny and byte-for-byte identical so it needs
/// no independent test coverage of its own. Reuses `OtegamiCore
/// .SnippetBuilder` directly (rather than re-deriving its truncation
/// algorithm too) since `OtegamiCore` is already a real dependency of this
/// extension target (`project.yml`), unlike `PushRelayClient` itself.
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
