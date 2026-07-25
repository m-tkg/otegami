import Foundation

/// The pure "how do we turn a freshly-fetched envelope into a notification's
/// title/body" policy that `apps/Otegami/NotificationService
/// /NotificationService.swift`'s `enrich(payload:)` applies after it
/// re-fetches the newest message's envelope over IMAP (M9's privacy design:
/// the push payload itself never carries subject/sender — see
/// `OtegamiRelayAPI.PushNotificationPayload`'s doc comment).
///
/// Extracted here, as plain `String`-in/`String`-out functions with no
/// `UNMutableNotificationContent`/`MailTransport.Envelope`/GRDB/Keychain/
/// IMAP-session involvement, purely so it's exercisable by `swift test`
/// (`NotificationEnrichmentTests`) — the app-extension target itself can't
/// run under SwiftPM's test runner (it's a `UNNotificationServiceExtension`,
/// needs a full iOS Simulator + XCUITest + `xcrun simctl push` to drive for
/// real, `docs/verify.md`'s `scripts/verify-ios-push-simulated.sh`).
///
/// `NotificationService.swift` keeps a small **mirrored** private copy of
/// these two functions rather than importing this type directly — the
/// app-extension target's `project.yml` dependency list doesn't currently
/// include the `PushRelayClient` product (only `OtegamiCore`/`MailTransport`/
/// `MailTransportMailCore`/`OtegamiStore`/`OtegamiRelayAPI`/`SyncEngine`),
/// and this task's scope is intentionally limited to files under
/// `apps/Otegami/NotificationService/`/`packages/OtegamiKit/Sources/
/// {PushRelayClient,AccountCloudSync}/` — not `project.yml`. Same reasoning
/// `OtegamiAppGroup.swift`'s doc comment already documents for why that type
/// has an identical, separately-compiled copy in the extension target
/// instead of a shared import: keep the algorithm itself defined once here
/// (and unit-tested here), and let the mirrored copy be a small, easy-to-
/// keep-in-sync-by-inspection duplicate.
public enum NotificationEnrichment {
    /// The notification's title, given the newest message's sender.
    /// Prefers a non-empty display name (`senderName`, mirrors
    /// `MailTransport.Address.name`/`MCOAddress.displayName`), falling back
    /// to the raw address when there's no display name at all or it's the
    /// empty string (some servers/clients send `"" <foo@bar.com>`).
    public static func title(senderName: String?, senderAddress: String) -> String {
        if let senderName, !senderName.isEmpty {
            return senderName
        }
        return senderAddress
    }

    /// The notification's body, given the newest message's subject —
    /// `nil` when `subject` is `nil` or empty, so the caller can leave
    /// whatever generic fallback body ("新着メールがあります") it already
    /// set in place rather than overwriting it with a blank string.
    public static func body(subject: String?) -> String? {
        guard let subject, !subject.isEmpty else { return nil }
        return subject
    }
}
