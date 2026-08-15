/// Errors surfaced by `IMAPSessionProtocol` / `SMTPSessionProtocol` implementations.
///
/// This is deliberately transport-agnostic: it does not leak MailCore2 (or
/// any other backend) error types across the abstraction boundary, so
/// `SyncEngine` never needs to know which library is behind `MailTransport`.
public enum MailTransportError: Error, Sendable {
    /// The underlying connection could not be established (DNS, TCP, TLS
    /// handshake, etc). `underlyingDescription` carries the backend's
    /// message for logging; callers should not pattern-match on it.
    case connectionFailed(underlyingDescription: String)

    /// The server rejected the supplied credentials.
    case authenticationFailed(underlyingDescription: String)

    /// The server returned an error for an otherwise well-formed command
    /// (e.g. `NO`/`BAD` IMAP responses, an SMTP 5xx reply).
    case serverError(underlyingDescription: String)

    /// The server refused the connection because this account already has
    /// too many simultaneous connections open (Gmail allows 15 per account
    /// and answers the `LOGIN` with "Too many simultaneous connections" /
    /// "Maximum number of connections" — MailCore2 turns that into
    /// `MCOErrorGmailTooManySimultaneousConnections`).
    ///
    /// Deliberately its own case rather than folded into `.serverError`:
    /// this is a *self-inflicted, transient* condition — the credentials
    /// are fine, the mailbox is fine, and the same request succeeds once
    /// this app's own in-flight connections drop below the limit. Three
    /// call sites behave differently because of that distinction:
    ///
    /// - `SyncFailureClass.classify` treats it as connection-level, so an
    ///   `opQueue` op does not burn an attempt (and eventually fail
    ///   permanently) over a limit this app caused.
    /// - `PooledIMAPSession` discards rather than pools a session that hit
    ///   it, instead of handing the same doomed connection to the next
    ///   caller.
    /// - `BodyFetcher.attemptSelfHeal` engages only for `.serverError`, so
    ///   keeping this out of that case is what stops a connection-limit
    ///   failure from being mistaken for a stale UID and deleting the
    ///   message locally.
    case tooManyConnections(underlyingDescription: String)

    /// A response could not be parsed into the expected shape.
    case malformedResponse(underlyingDescription: String)

    /// The requested mailbox does not exist or is not selectable.
    case mailboxNotFound(path: String)

    /// The session was asked to operate before `connect()` succeeded, or
    /// after `disconnect()`.
    case notConnected

    /// The operation was cancelled (e.g. `Task` cancellation while awaiting
    /// a MailCore2 callback).
    case cancelled

    /// The method is part of the protocol surface for a later milestone
    /// (e.g. IDLE, CONDSTORE `changedSince`, APPEND, MOVE) but this adapter
    /// does not implement it yet.
    case notImplemented(String)

    /// Task #167 / F9: an `EmailAddress.address`/`.name` bound for this
    /// transport contains a CR, LF, or NUL byte. Backends that hand
    /// addresses to a line-oriented wire protocol (SMTP's `MAIL FROM`/
    /// `RCPT TO`) throw this rather than letting an embedded CRLF become a
    /// second, attacker-controlled protocol command — see
    /// `MailCoreSMTPSession.sendMessage`'s doc comment.
    case invalidAddress(underlyingDescription: String)
}

extension MailTransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionFailed(let message):
            "connectionFailed: \(message)"
        case .authenticationFailed(let message):
            "authenticationFailed: \(message)"
        case .serverError(let message):
            "serverError: \(message)"
        case .tooManyConnections(let message):
            "tooManyConnections: \(message)"
        case .malformedResponse(let message):
            "malformedResponse: \(message)"
        case .mailboxNotFound(let path):
            "mailboxNotFound: \(path)"
        case .notConnected:
            "notConnected"
        case .cancelled:
            "cancelled"
        case .notImplemented(let what):
            "notImplemented: \(what)"
        case .invalidAddress(let message):
            "invalidAddress: \(message)"
        }
    }
}
