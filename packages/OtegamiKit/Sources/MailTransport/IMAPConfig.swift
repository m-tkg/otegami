/// How a session's TCP connection is secured.
public enum MailConnectionSecurity: Sendable, Codable, Hashable {
    /// Plain TCP, no encryption (dev mailstack default, port 1143).
    case plain
    /// Implicit TLS from the first byte (IMAPS/SMTPS, typically 993/465).
    case tls
    /// Plain TCP that upgrades to TLS via `STARTTLS` before authentication.
    case startTLS
}

/// Connection parameters for an IMAP session. Credentials are supplied
/// separately via `MailAuth` at `connect(auth:)` time so they never need to
/// be embedded in a value that might be logged or persisted.
public struct IMAPConfig: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var security: MailConnectionSecurity

    /// Whether to allow connecting to a server presenting a certificate
    /// that fails validation (self-signed, hostname mismatch, ...). Used
    /// for the dev mailstack's self-signed IMAPS certificate; must be
    /// `false` for any real account.
    public var allowsInsecureTLS: Bool

    public init(
        host: String,
        port: Int,
        security: MailConnectionSecurity,
        allowsInsecureTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.allowsInsecureTLS = allowsInsecureTLS
    }
}

/// Connection parameters for an SMTP session. See `IMAPConfig` for the
/// rationale behind keeping credentials out of this type.
public struct SMTPConfig: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var security: MailConnectionSecurity
    public var allowsInsecureTLS: Bool

    public init(
        host: String,
        port: Int,
        security: MailConnectionSecurity,
        allowsInsecureTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.allowsInsecureTLS = allowsInsecureTLS
    }
}

/// Credentials for authenticating an IMAP or SMTP session. Kept separate
/// from `IMAPConfig`/`SMTPConfig` so callers can source it from Keychain
/// (password/generic) or `TokenStore` (XOAUTH2) right before `connect`.
public enum MailAuth: Sendable {
    /// Plain username/password (`LOGIN`), used by generic IMAP/SMTP,
    /// iCloud (app-specific password), and the dev mailstack.
    case password(username: String, password: String)

    /// `XOAUTH2` SASL, used by Gmail. `accessToken` is a short-lived OAuth2
    /// access token; refreshing it is `TokenStore`'s responsibility, not
    /// the transport's.
    case xoauth2(username: String, accessToken: String)
}
