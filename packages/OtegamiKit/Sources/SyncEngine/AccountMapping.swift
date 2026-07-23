import MailTransport
import OtegamiStore

/// Bridges `OtegamiStore`'s transport-agnostic `ConnectionSecurityRecord`
/// (which can't depend on `MailTransport`, see `AccountAuthType`'s doc
/// comment) to `MailTransport.MailConnectionSecurity`. `SyncEngine` is the
/// one layer that depends on both, so this conversion lives here; the app
/// reuses it via `import SyncEngine` rather than duplicating the mapping.
extension ConnectionSecurityRecord {
    public var mailTransportSecurity: MailConnectionSecurity {
        switch self {
        case .plain: .plain
        case .tls: .tls
        case .startTLS: .startTLS
        }
    }

    public init(_ security: MailConnectionSecurity) {
        switch security {
        case .plain: self = .plain
        case .tls: self = .tls
        case .startTLS: self = .startTLS
        }
    }
}

extension MailboxRoleRecord {
    public init(_ role: MailboxRole) {
        self = MailboxRoleRecord(rawValue: role.rawValue) ?? .none
    }
}

extension AccountRecord {
    /// The `IMAPConfig` to open a session against this account, as stored
    /// (host/port/security only — credentials come from Keychain/TokenStore
    /// separately via `MailAuth`).
    public var imapConfig: IMAPConfig {
        IMAPConfig(
            host: imapHost,
            port: imapPort,
            security: imapSecurity.mailTransportSecurity,
            allowsInsecureTLS: imapAllowsInsecureTLS
        )
    }
}
