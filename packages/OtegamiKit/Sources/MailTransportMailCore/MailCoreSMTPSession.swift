import Foundation
import MailCore
import MailTransport
import OtegamiCore

/// `SMTPSessionProtocol` backed by `MCOSMTPSession` (M5). Follows the same
/// bridging pattern as `MailCoreIMAPSession`: one instance per connection,
/// actor-isolated so MailCore2's non-`Sendable` objects never need to cross
/// an isolation boundary, `withCheckedThrowingContinuation` to turn its
/// callback-based operations into `async`/`await`.
///
/// Unlike IMAP, MailCore2's `MCOSMTPSession` has no persistent-connection
/// notion of its own — every operation (`loginOperation`, `sendOperation`,
/// `checkAccountOperation`) independently opens a socket as needed.
/// `connect(auth:)` is implemented as `session.loginOperation()` (a plain
/// `EHLO`/`AUTH` round trip, nothing else) rather than
/// `checkAccountOperationWithFrom:` — the latter issues a full `MAIL FROM`
/// + `RCPT TO:<bogus>` probe and, critically, never sends the matching
/// `RSET`, leaving the connection's SMTP transaction state "dirty" for any
/// *subsequent* operation on the same session (confirmed empirically
/// against the dev mailstack's Mailpit: a `sendOperationWithData` right
/// after a `checkAccountOperation` gets rejected `503 Bad sequence of
/// commands` — `MAIL FROM` twice without an intervening `RSET`/`EHLO`).
/// `OpQueueProcessor.send` reuses one `MailCoreSMTPSession` for exactly
/// that connect-then-send sequence, so `connect(auth:)` has to leave the
/// connection ready to send afterward; `loginOperation()` does, since it
/// never touches `MAIL`/`RCPT` at all. It still doubles as the account-setup
/// "SMTP接続テスト" button's connection test (a real `EHLO`+`AUTH` round
/// trip is exactly what that button wants to verify) — that call site
/// always discards the session right after, so never observes the
/// difference.
public actor MailCoreSMTPSession: SMTPSessionProtocol {
    private let session: MCOSMTPSession
    private var connected = false

    public init(config: SMTPConfig) {
        let session = MCOSMTPSession()
        session.hostname = config.host
        session.port = UInt32(config.port)
        session.connectionType = MailCoreIMAPSession.connectionType(for: config.security)
        session.isCheckCertificateEnabled = !config.allowsInsecureTLS
        self.session = session
    }

    public func connect(auth: MailAuth) async throws {
        Self.apply(auth, to: session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.loginOperation().start { error in
                if let error {
                    continuation.resume(throwing: MailCoreIMAPSession.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
        connected = true
    }

    public func disconnect() async {
        connected = false
        // MCOSMTPSession has no explicit teardown of its own — every
        // operation opens/closes its own socket — so the closest thing to
        // "disconnect" is dropping any operations still in flight.
        session.cancelAllOperations()
    }

    public func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws {
        guard connected else { throw MailTransportError.notConnected }
        let fromAddress = Self.mcoAddress(from)
        let recipientAddresses = recipients.map(Self.mcoAddress)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.sendOperationWithData(messageData: messageData, from: fromAddress, recipients: recipientAddresses).start { error in
                if let error {
                    continuation.resume(throwing: MailCoreIMAPSession.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func apply(_ auth: MailAuth, to session: MCOSMTPSession) {
        switch auth {
        case .password(let username, let password):
            // MailCore2's `SMTPSession::login` only skips authenticating
            // when `username()`/`password()` are unset (`NULL`) — an empty
            // *string* still counts as "set" and triggers a real `AUTH`
            // attempt the server then rejects. Leaving both unset for an
            // empty username lets an SMTP relay that requires no
            // authentication at all (e.g. the dev mailstack's Mailpit)
            // work with a `MailAuth.password(username: "", password: "")`
            // placeholder, rather than forcing every caller to know to
            // skip `connect(auth:)` entirely for that case.
            guard !username.isEmpty else { return }
            session.username = username
            session.password = password
            session.authType = .SASLNone
        case .xoauth2(let username, let accessToken):
            session.username = username
            session.OAuth2Token = accessToken
            session.authType = .XOAuth2
        }
    }

    private static func mcoAddress(_ address: EmailAddress) -> MCOAddress {
        if let name = address.name, !name.isEmpty {
            // swiftlint:disable:next force_unwrap
            return MCOAddress(displayName: name, mailbox: address.address)!
        }
        // swiftlint:disable:next force_unwrap
        return MCOAddress(mailbox: address.address)!
    }
}
