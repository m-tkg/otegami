import Foundation
import MailTransport

/// A short, Japanese, user-facing classification of `MailTransportError` for
/// the account-setup connection-test buttons (IMAP's `接続テスト` and SMTP's
/// `SMTP接続テスト`, `AccountSetupView`). Both buttons previously just
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
    func userFacingMessage(prefix: String) -> String {
        "\(prefix): \(classification)"
    }

    private var classification: String {
        switch self {
        case .authenticationFailed:
            "認証に失敗しました。ユーザー名またはパスワードを確認してください。(\(description))"
        case .connectionFailed:
            "サーバーに接続できません。ホスト名・ポート・接続方式を確認してください。(\(description))"
        case .mailboxNotFound(let path):
            "メールボックスが見つかりません: \(path)"
        case .notConnected, .cancelled, .malformedResponse, .serverError, .notImplemented:
            description
        }
    }
}

/// Falls back to classifying `error` if it's a `MailTransportError`,
/// otherwise (e.g. a `CancellationError`, or some other backend's error
/// type) prints it as-is — a connection test button should never crash or
/// show nothing just because the failure wasn't the expected shape.
func mailTransportUserFacingMessage(for error: Error, prefix: String) -> String {
    guard let transportError = error as? MailTransportError else {
        return "\(prefix): \(error)"
    }
    return transportError.userFacingMessage(prefix: prefix)
}
