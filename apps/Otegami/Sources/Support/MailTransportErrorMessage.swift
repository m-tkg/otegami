import Foundation
import MailTransport

/// A short, Japanese, user-facing classification of `MailTransportError` for
/// the account connection-test buttons (IMAP's `接続テスト` and SMTP's
/// `SMTP接続テスト`, shared by `AccountSetupView`/`ICloudAccountSetupView`
/// for a brand-new account and `AccountEditView` for an existing one — see
/// `AccountConnectionTesting.swift`). Both buttons previously just
/// interpolated the raw error (`"接続に失敗しました: \(error)"`), which for a
/// `MailTransportError` prints its `CustomStringConvertible` form (e.g.
/// `"authenticationFailed: ..."`) — technically accurate but not something a
/// non-technical user filling in a mail account form can act on. This keeps
/// the underlying description too (folded in after the classified
/// headline), so nothing informative is lost for anyone who *does* want the
/// raw detail (support requests, bug reports).
extension MailTransportError {
    /// `prefix` is the call site's own headline (e.g. "接続に失敗しました",
    /// "SMTP接続に失敗しました") so IMAP/SMTP test buttons can keep saying
    /// which of the two failed while sharing this classification.
    ///
    /// - Parameter hasSucceededBefore: Task #187 — whether *this* account's
    ///   credential is known to have authenticated successfully at some
    ///   point in the past (an existing, already-used account being
    ///   re-tested from `AccountEditView`), as opposed to a brand-new
    ///   account whose credential has never been proven at all
    ///   (`AccountSetupView`/`ICloudAccountSetupView` always pass the
    ///   default `false` — no history is even possible yet). Only changes
    ///   `.authenticationFailed`'s wording — see `classification`'s doc
    ///   comment on that case for why.
    func userFacingMessage(prefix: String, hasSucceededBefore: Bool = false) -> String {
        "\(prefix): \(classification(hasSucceededBefore: hasSucceededBefore))"
    }

    private func classification(hasSucceededBefore: Bool) -> String {
        switch self {
        case .authenticationFailed:
            if hasSucceededBefore {
                // Task #187: a Yahoo! JAPAN account observed failing IMAP
                // LOGIN intermittently with the *same* credential that had
                // connected successfully earlier the same day — the
                // server's own response was a plain
                // `[AUTHENTICATIONFAILED] Incorrect username or password.`,
                // indistinguishable at the protocol level from an actually
                // wrong password (see `docs/architecture.md`'s Known
                // pitfalls on IDLE-unsupported servers and provider-side
                // auth lockouts). Asserting
                // "確認してください" here is misleading for a credential with
                // a proven track record, and led a real user to doubt (and
                // needlessly re-enter) settings that were already correct.
                // Softened to name the more likely cause (a temporary
                // provider-side restriction) without ruling out a genuine
                // password change either.
                String(localized: "認証に失敗しました。ただし、この資格情報は過去に接続に成功しているため、パスワードの誤りではなく一時的な制限の可能性があります。しばらく時間をおいてから再度お試しください。") + " (\(description))"
            } else {
                "認証に失敗しました。ユーザー名またはパスワードを確認してください。(\(description))"
            }
        case .connectionFailed:
            "サーバーに接続できません。ホスト名・ポート・接続方式を確認してください。(\(description))"
        case .mailboxNotFound(let path):
            "メールボックスが見つかりません: \(path)"
        case .notConnected, .cancelled, .malformedResponse, .serverError, .notImplemented, .invalidAddress:
            description
        }
    }
}

/// Falls back to classifying `error` if it's a `MailTransportError`,
/// otherwise (e.g. a `CancellationError`, or some other backend's error
/// type) prints it as-is — a connection test button should never crash or
/// show nothing just because the failure wasn't the expected shape.
///
/// - Parameter hasSucceededBefore: see `MailTransportError
///   .userFacingMessage(prefix:hasSucceededBefore:)`'s doc comment.
func mailTransportUserFacingMessage(for error: Error, prefix: String, hasSucceededBefore: Bool = false) -> String {
    guard let transportError = error as? MailTransportError else {
        return "\(prefix): \(error)"
    }
    return transportError.userFacingMessage(prefix: prefix, hasSucceededBefore: hasSucceededBefore)
}
