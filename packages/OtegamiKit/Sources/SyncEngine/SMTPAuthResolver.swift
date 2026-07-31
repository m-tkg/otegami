import MailTransport
import OtegamiStore

/// Builds SMTP-specific credentials from `account.smtpUsername` (the
/// account setup form's own SMTP username field) rather than reusing
/// `imapAuth` verbatim — the IMAP and SMTP username can legitimately
/// differ, and reusing the IMAP username unconditionally would also mean
/// an account with an intentionally-blank SMTP username (some relays
/// require none — the dev mailstack's Mailpit among them; a blank
/// username there makes `MailCoreSMTPSession.connect` skip `AUTH`
/// entirely) would still attempt to authenticate. The password is the one
/// already resolved for `imapAuth`, since the schema only stores a single
/// Keychain-backed password per account (`AccountRecord`'s doc comment) —
/// real providers needing genuinely distinct IMAP/SMTP passwords are out
/// of scope until an account form actually collects a second one.
///
/// Extracted from `OpQueueProcessor`'s `.send` case and `SyncCoordinator
/// .sendCalendarReply(draft:account:auth:)` — both need to derive SMTP
/// credentials the identical way (`.send` submits over its own SMTP
/// connection at replay time; `sendCalendarReply` sends a calendar RSVP
/// immediately over its own short-lived SMTP connection), and previously
/// carried byte-for-byte identical private copies of this function.
enum SMTPAuthResolver {
    static func resolve(imapAuth: MailAuth, account: AccountRecord) -> MailAuth {
        switch imapAuth {
        case .password(_, let password):
            .password(username: account.smtpUsername ?? "", password: password)
        case .xoauth2(let username, let accessToken):
            .xoauth2(username: account.smtpUsername ?? username, accessToken: accessToken)
        }
    }
}
