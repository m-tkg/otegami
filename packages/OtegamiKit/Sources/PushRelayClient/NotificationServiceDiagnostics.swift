import Foundation

/// Task #211 (実機フィードバック: プッシュ通知の内容が Yahoo! JAPAN アカ
/// ウントだけ「新着メールがあります」の汎用文言のままで、差出人・件名が
/// 出ない): a pure, log-safe classifier for the errors
/// `NotificationService.enrich(payload:)`'s IMAP half can throw, so a real
/// device's next failure leaves an OSLog trail that actually says *why* —
/// connection refused, authentication rejected, or a tagged server error
/// (in particular `docs/architecture.md`'s pitfall i.: Yahoo returning
/// `[LIMIT]` for a rate-limited command, which is a strong signal that
/// `NotificationService`'s own short-lived IMAP connection is contending
/// with the relay's now-long-lived one for the same account — Task #201/
/// #208).
///
/// Deliberately takes primitive (`String`) arguments rather than
/// `MailTransport.MailTransportError` itself: `PushRelayClient` has no
/// dependency on `MailTransport` (it stays a small, Linux-compatible
/// target — see `Package.swift`'s doc comment on `PushOAuthAccessTokenResolution`
/// for the same closure/primitive-injection reasoning applied to a
/// different dependency), and `NotificationService.swift` is this type's
/// only production caller. It unwraps its own `MailTransportError` switch
/// right next to where it catches the error and hands the resulting
/// `(category, underlyingDescription)` pair here — keeping the actual
/// OSLog `Logger` call (not practically unit-testable; `Logger` has no
/// inspectable output) as thin as possible around this classification
/// logic (which is).
public enum NotificationServiceDiagnostics {
    /// What `NotificationService`'s single OSLog `.error` line for a failed
    /// IMAP stage should say — everything in here is safe to write to OSLog
    /// `.public` (no message body, no subject, no credentials, no email
    /// address).
    public struct ErrorSummary: Equatable, Sendable {
        /// One of `MailTransportError`'s case names, exactly as the caller
        /// derived it from its own `switch` (e.g. `"connectionFailed"`,
        /// `"authenticationFailed"`, `"serverError"`) — an opaque string as
        /// far as this type is concerned, never pattern-matched here beyond
        /// the special-cased `"authenticationFailed"` below.
        public let category: String

        /// Whether `underlyingDescription` looks like Yahoo's `[LIMIT]`
        /// rate-limit response (`docs/architecture.md`'s pitfall i. —
        /// `A87 NO [LIMIT] STATUS Rate limit hit.`, verified against a real
        /// Yahoo tagged response) — the single fact this whole classifier
        /// exists to surface without a human having to go hunting through
        /// `logDetail` for a bracketed substring.
        public let looksRateLimited: Bool

        /// The text to actually log alongside `category`, or `nil` when
        /// there's nothing safe/useful to add. `nil` for
        /// `category == "authenticationFailed"` even though that case
        /// carries an `underlyingDescription` too — some IMAP servers'
        /// tagged `NO [AUTHENTICATIONFAILED]` response echoes the attempted
        /// login name (an email address, PII) back in the response text,
        /// and this Extension must never write that to OSLog (CLAUDE.md's
        /// "実名・実メールアドレス...をどこにも書かない" — applies to a
        /// running device's log stream exactly as much as to the repo).
        /// Every other category's description is IMAP/TLS protocol text
        /// only (connection failures, tagged `NO`/`BAD` responses to
        /// non-auth commands) — safe to log, capped at
        /// `Self.maxLogDetailLength` so a pathologically long server string
        /// can't bloat the log.
        public let logDetail: String?

        public init(category: String, looksRateLimited: Bool, logDetail: String?) {
            self.category = category
            self.looksRateLimited = looksRateLimited
            self.logDetail = logDetail
        }
    }

    /// Longest `logDetail` this produces — comfortably long enough for any
    /// real IMAP tagged response line, short enough that a malformed/huge
    /// server string can't turn one log line into a wall of text.
    public static let maxLogDetailLength = 200

    /// `category` is never compared against `""`/whitespace-only — an
    /// empty string is passed straight through like any other value, since
    /// the caller (a `switch` over every `MailTransportError` case) can
    /// never actually produce one.
    public static func summarize(category: String, underlyingDescription: String?) -> ErrorSummary {
        let looksRateLimited = underlyingDescription?.contains("[LIMIT]") ?? false
        let logDetail: String? = {
            guard category != "authenticationFailed", let underlyingDescription, !underlyingDescription.isEmpty else {
                return nil
            }
            return String(underlyingDescription.prefix(maxLogDetailLength))
        }()
        return ErrorSummary(category: category, looksRateLimited: looksRateLimited, logDetail: logDetail)
    }
}
