import Foundation
import OtegamiCore

/// Task #176 (実機フィードバック 2026-07-30「通知にタイトル、差出人、本文の
/// 一部を出すかどうかの設定を追加して」): which of the 3 content categories a
/// push notification is allowed to show, one bool per `PushNotificationSettingsView`
/// toggle. Every device's `NotificationService` reads its own copy of this
/// from the shared App Group `UserDefaults` suite (`NotificationContentSettingsStore`'s
/// doc comment covers why — that Extension runs in a separate process from
/// the app that owns the toggle).
///
/// This is a *content* preference, not the OS-level "プレビューを表示"
/// (Settings → 通知 → Otegami) setting: that one governs whether the *system*
/// ever renders a notification's title/body at all (on the lock screen, in
/// notification center, ...) regardless of what's in it. This one governs
/// what this app puts into that title/body in the first place — the two
/// stack (both have to allow it for a user to actually see, say, the
/// subject on their lock screen), which is exactly the "混同しやすい" gap
/// `PushNotificationSettingsView`'s footer text calls out explicitly.
public struct NotificationContentPreferences: Equatable, Sendable {
    /// Stable keys shared by the app's settings store and Notification
    /// Service Extension. Changing these would discard existing choices.
    public static let showsSenderKey = "notification.showsSender"
    public static let showsSubjectKey = "notification.showsSubject"
    public static let showsBodyPreviewKey = "notification.showsBodyPreview"

    public var showsSender: Bool
    public var showsSubject: Bool
    public var showsBodyPreview: Bool

    public init(showsSender: Bool, showsSubject: Bool, showsBodyPreview: Bool) {
        self.showsSender = showsSender
        self.showsSubject = showsSubject
        self.showsBodyPreview = showsBodyPreview
    }

    /// The compiled-in default for all 3 toggles — every one on, i.e.
    /// exactly today's pre-#176 behavior. `PushNotificationSettingsView`'s
    /// `@AppStorage` bindings and `NotificationContentSettingsStore` both
    /// resolve a never-explicitly-set key to this same default, so a fresh
    /// install (or a device that never opened this settings screen) never
    /// silently shows *less* than it used to.
    public static let allEnabled = NotificationContentPreferences(showsSender: true, showsSubject: true, showsBodyPreview: true)
}

/// The pure "how do we turn a freshly-fetched envelope/body into a
/// notification's title/body" policy that `apps/Otegami/NotificationService
/// /NotificationService.swift`'s `enrich(payload:)` applies after it
/// re-fetches the newest message's data over IMAP (M9's privacy design:
/// the push payload itself never carries subject/sender/body — see
/// `OtegamiRelayAPI.PushNotificationPayload`'s doc comment).
///
/// Extracted here, as plain value-in/value-out functions with no
/// `UNMutableNotificationContent`/`MailTransport.Envelope`/GRDB/Keychain/
/// IMAP-session involvement, purely so it's exercisable by `swift test`
/// (`NotificationEnrichmentTests`) — the app-extension target itself can't
/// run under SwiftPM's test runner (it's a `UNNotificationServiceExtension`,
/// needs a full iOS Simulator + XCUITest + `xcrun simctl push` to drive for
/// real, `docs/verify.md`'s `scripts/verify-ios-push-simulated.sh`).
///
/// `NotificationService.swift` imports this type directly through the
/// extension target's `PushRelayClient` dependency. The policy therefore
/// has one implementation shared by its unit tests and production caller.
public enum NotificationEnrichment {
    /// Title/body shown when nothing enrichable is available — either every
    /// toggle in `NotificationContentPreferences` is off, or (unrelated to
    /// this task) the IMAP re-fetch itself failed for any reason. Matches
    /// `NotificationService.didReceive(_:withContentHandler:)`'s own
    /// pre-enrichment default deliberately: a notification a user has
    /// configured to hide, say, the sender must look *identical* to one
    /// that simply failed to enrich for some other reason — never a
    /// confusing "we clearly know who this is from, but you told us not to
    /// say."
    public static let genericTitle = "Otegami"
    public static let genericBody = "新着メールがあります"

    /// Whether `NotificationService.enrich(payload:)` needs to fetch
    /// *anything* from IMAP at all. `false` only when every one of the 3
    /// toggles is off — Task #176's own "この場合 Extension が IMAP
    /// フェッチをする必要すらない" ask. When this is `false`, the caller
    /// skips not just the IMAP connection but the account/Keychain lookup
    /// that would otherwise precede it too, since neither one's result
    /// would end up used for anything: the notification is left exactly as
    /// `didReceive` already set it (`genericTitle`/`genericBody`).
    public static func needsFetch(preferences: NotificationContentPreferences) -> Bool {
        preferences.showsSender || preferences.showsSubject || preferences.showsBodyPreview
    }

    /// The notification's title: the newest message's sender, when
    /// `preferences.showsSender` is on and a usable one was found — prefers
    /// a non-empty display name over the raw address, falling back to the
    /// address only when there's no display name at all (some servers/
    /// clients send `"" <foo@bar.com>`). `genericTitle` when the toggle is
    /// off, or when neither a name nor an address is available.
    public static func title(
        preferences: NotificationContentPreferences,
        senderName: String?,
        senderAddress: String?
    ) -> String {
        guard preferences.showsSender else { return genericTitle }
        if let senderName, !senderName.isEmpty { return senderName }
        if let senderAddress, !senderAddress.isEmpty { return senderAddress }
        return genericTitle
    }

    /// The notification's body: the subject line (if `preferences
    /// .showsSubject` and non-empty) and a whitespace-collapsed,
    /// length-limited body-preview snippet built from `bodyPreviewSourceText`
    /// (if `preferences.showsBodyPreview` and it yields anything —
    /// `SnippetBuilder.make(from:maxLength:)` is the same truncation/
    /// whitespace-collapsing algorithm `message.snippet`'s list-row preview
    /// already uses, so a notification's preview text reads the same way a
    /// mailbox row's does), one per line, in that order.
    ///
    /// `genericBody` when both are off, *or* when both are on but happen to
    /// yield nothing (e.g. an empty subject and no body text at all) — a
    /// notification should never show a blank body just because its
    /// content happened to be empty, only because the user asked it to be.
    public static func body(
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
