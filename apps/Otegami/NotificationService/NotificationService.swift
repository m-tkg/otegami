import GRDB
import MailTransport
import MailTransportMailCore
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
/// 2. Open the shared `AppDatabase` (App Group container, read-only in
///    practice — see `AppDatabase.makeShared(appGroupIdentifier:)`'s doc
///    comment) and look up that account's `AccountRecord`.
/// 3. Read its IMAP password from the shared Keychain Access Group
///    (`.password`-auth accounts only — v1 of the relay only supports
///    password auth, plan: "LOGIN/XOAUTH2 なし可: password のみ v1", so a
///    `.gmail`/`.oauth2` account can't have a watch in the first place;
///    this Extension never even tries XOAUTH2).
/// 4. Connect, `SELECT` the watched mailbox, `FETCH` the envelope for UID
///    `uidNext - 1` (the just-arrived message), and fill in the
///    notification's title (sender) / body (subject).
/// 5. Any failure at any step (account not found, no password, IMAP
///    connect/auth/fetch failure) falls back to a generic "新着メールが
///    あります" body — the notification still shows, just without the
///    enrichment — rather than dropping the notification.
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

    private func enrich(payload: PushNotificationPayload) async {
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
                if let sender = envelope.from.first {
                    bestAttemptContent?.title = NotificationEnrichment.title(senderName: sender.name, senderAddress: sender.address)
                }
                if let body = NotificationEnrichment.body(subject: envelope.subject) {
                    bestAttemptContent?.body = body
                }
            }
        } catch {
            // Leave the generic fallback content in place — see the type's
            // doc comment on why this is a silent no-op rather than
            // surfacing the error anywhere a user could see it.
        }
        await session.disconnect()
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

/// Mirrored copy of `PushRelayClient.NotificationEnrichment`
/// (`packages/OtegamiKit/Sources/PushRelayClient/NotificationEnrichment
/// .swift`) — see that type's doc comment for why this target has its own
/// separately-compiled copy instead of an `import PushRelayClient` (same
/// reasoning as `OtegamiAppGroup.swift`'s existing duplication). The
/// algorithm is unit-tested there (`NotificationEnrichmentTests`); this
/// copy is intentionally kept tiny and byte-for-byte identical so it needs
/// no independent test coverage of its own.
private enum NotificationEnrichment {
    static func title(senderName: String?, senderAddress: String) -> String {
        if let senderName, !senderName.isEmpty {
            return senderName
        }
        return senderAddress
    }

    static func body(subject: String?) -> String? {
        guard let subject, !subject.isEmpty else { return nil }
        return subject
    }
}
