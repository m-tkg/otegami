import Foundation
import OtegamiCore

/// Abstraction over a single SMTP session, implemented by
/// `MailTransportMailCore.MailCoreSMTPSession` (backed by MailCore2). Not
/// exercised until M5 (Compose/Reply/SMTP); the protocol is defined now so
/// `OtegamiRelayAPI`/`SyncEngine` types that reference it can be written
/// against a stable shape. `MailCoreSMTPSession` throws
/// `MailTransportError.notImplemented` for all methods until M5.
public protocol SMTPSessionProtocol: Sendable {
    init(config: SMTPConfig)

    /// Opens the TCP connection (applying `SMTPConfig.security`) and
    /// authenticates with `auth`.
    func connect(auth: MailAuth) async throws

    /// Closes the connection. Safe to call when not connected.
    func disconnect() async

    /// Sends `messageData` (a full RFC 822 message, including headers) to
    /// `recipients`. `from` is used for the `MAIL FROM` envelope sender;
    /// the message's own `From:` header is expected to already be present
    /// in `messageData`.
    func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws
}
