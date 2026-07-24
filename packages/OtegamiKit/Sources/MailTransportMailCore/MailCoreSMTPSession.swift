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
    private var session: MCOSMTPSession
    private var connected = false

    public init(config: SMTPConfig) {
        let session = MCOSMTPSession()
        session.hostname = config.host
        session.port = UInt32(config.port)
        session.connectionType = MailCoreIMAPSession.connectionType(for: config.security)
        session.isCheckCertificateEnabled = !config.allowsInsecureTLS
        self.session = session
    }

    /// Real-world discovery (a user filled in the SMTP username field
    /// pointing at a dev Mailpit instance that has no AUTH support at all)
    /// surfaced a UX trap: previously, a non-empty username always meant
    /// "attempt AUTH", and a server that doesn't support AUTH would reject
    /// it outright (Mailpit: `502 5.5.1 Command not implemented`), failing
    /// the connection test/send even though the exact same server accepts
    /// an unauthenticated session just fine. "Leave the username blank" is
    /// not a discoverable workaround, so this now retries once, without
    /// authenticating at all, specifically when the *first* attempt's
    /// failure looks like "the server doesn't understand/allow the `AUTH`
    /// command itself" rather than "the server rejected these credentials"
    /// — see `isAuthCommandRejectedAsUnsupported(_:)`'s doc comment for how
    /// that distinction is made and why it's conservative by construction
    /// (an ambiguous failure is always treated as a real auth rejection,
    /// never silently swallowed).
    public func connect(auth: MailAuth) async throws {
        Self.apply(auth, to: session)
        do {
            try await login()
        } catch {
            guard Self.isRetriableWithoutAuth(auth: auth, error: error) else {
                throw MailCoreIMAPSession.mapError(error)
            }
            // MailCore2's `SMTPSession::login()` skips authenticating
            // entirely (and never reopens the socket) when `username()`/
            // `password()` are unset (`NULL`) — see `apply(_:to:)`'s doc
            // comment on the empty-string special case below, which relies
            // on the same mechanism. Clearing them here re-triggers that
            // same "no AUTH at all" path on retry, reusing the connection
            // MailCore2 already has open (mailcore2 transparently
            // reconnects first if the server dropped it after the rejected
            // `AUTH`).
            session.username = nil
            session.password = nil
            do {
                try await login()
            } catch {
                throw MailCoreIMAPSession.mapError(error)
            }
        }
        connected = true
    }

    /// Runs `session.loginOperation()` (a plain `EHLO`/`AUTH` round trip)
    /// and throws the *raw* MailCore2 `NSError` rather than mapping it to
    /// `MailTransportError` — `connect(auth:)` needs to inspect
    /// `userInfo["MCOSMTPResponseCodeKey"]` on that raw error (see
    /// `isAuthCommandRejectedAsUnsupported(_:)`) before that distinction is
    /// lost to `MailCoreIMAPSession.mapError`'s coarser
    /// `.authenticationFailed` case, which every caller of *this* method
    /// still eventually maps to once the retry decision is made. An actor-
    /// isolated instance method (operating on `self.session`) rather than a
    /// `static` helper taking the session as a parameter — MailCore2's
    /// non-`Sendable` `MCOSMTPSession` can't safely cross into a `static`
    /// method's separate isolation domain under Swift 6 strict
    /// concurrency's region checking.
    private func login() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.loginOperation().start { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Only ever true for `.password` auth with a non-blank username (the
    /// only case where `apply(_:to:)` actually attempts a real `AUTH`
    /// exchange in the first place — an already-blank username skips `AUTH`
    /// up front and never reaches here, and XOAuth2 accounts are Gmail's
    /// own OAuth flow, which always requires auth, so "the server doesn't
    /// support AUTH" isn't a sensible fallback for it, nor would clearing
    /// `username`/`password` alone even skip its login path — mailcore2's
    /// `SMTPSession::login()` only takes the "AUTH unset → skip" branch for
    /// non-XOAuth2 auth types).
    static func isRetriableWithoutAuth(auth: MailAuth, error: Error) -> Bool {
        guard case .password(let username, _) = auth, !username.isEmpty else { return false }
        return isAuthCommandRejectedAsUnsupported(error)
    }

    /// SMTP response codes (RFC 5321 §4.2.1 / §4.2.4) a server sends in
    /// reply to the `AUTH` command itself when it doesn't support SMTP AUTH
    /// at all — `500`/`502` ("command unrecognized"/"not implemented"),
    /// `503` ("bad sequence of commands" — some servers reply this way to
    /// an `AUTH` they don't expect at all), `504` ("command parameter not
    /// implemented" — e.g. no AUTH mechanism they understand). Deliberately
    /// narrow and does **not** include `530`/`534`/`535`/`550`/`553`
    /// (real "these credentials are wrong" rejections) — misclassifying a
    /// wrong-password case as "just retry without auth" would silently
    /// let a genuine auth failure through as success, which is worse than
    /// leaving the user with today's confusing (but honest) error.
    ///
    /// mailcore2's own `SMTPSession::login()` (`MCSMTPSession.cpp`)
    /// collapses *every* non-stream SASL failure — regardless of which of
    /// these response codes the server actually sent — to the same
    /// `ErrorAuthentication` `ErrorCode`, so the response code itself
    /// (still attached to the operation's `NSError.userInfo` under
    /// `"MCOSMTPResponseCodeKey"`, populated from
    /// `SMTPOperation::lastSMTPResponseCode()`) is the *only* signal
    /// available in this mailcore2 revision for telling the two apart —
    /// confirmed by reading that revision's source directly (no public API
    /// exposes EHLO capabilities or a more specific error code). This key
    /// is not wrapped by mailcore2's Swift bindings, so it's referenced
    /// here as the literal string mailcore2's own `#define
    /// MCOSMTPResponseCodeKey @"MCOSMTPResponseCodeKey"` expands to, rather
    /// than a symbol.
    private static let authCommandUnsupportedResponseCodes: Set<Int> = [500, 502, 503, 504]

    private static func isAuthCommandRejectedAsUnsupported(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == MailCoreErrorDomain,
              let code = MailCoreError(rawValue: numericCast(nsError.code)),
              code == .errorAuthentication
        else { return false }
        // `NSNumber`, not a direct cast to `Int`: mailcore2 boxes the raw C
        // `int` it read off the wire as `@(op->lastSMTPResponseCode())`,
        // which Swift bridges into this `[String: Any]` dictionary as
        // `Int32` (its narrowest matching concrete type, going by the
        // NSNumber's `objCType`) rather than `Int` — confirmed empirically
        // against the dev mailstack's Mailpit (`as? Int` silently returned
        // `nil` here, `as? NSNumber` did not). `NSNumber.intValue` sidesteps
        // needing to know/guess that exact width.
        guard let responseCode = (nsError.userInfo["MCOSMTPResponseCodeKey"] as? NSNumber)?.intValue else {
            // No response code attached at all: can't tell "unsupported"
            // from "rejected" apart, so stay on the safe side and treat it
            // as a real auth failure rather than guessing.
            return false
        }
        return authCommandUnsupportedResponseCodes.contains(responseCode)
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
