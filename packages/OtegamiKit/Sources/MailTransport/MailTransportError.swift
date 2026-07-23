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
        }
    }
}
