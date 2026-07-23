import Foundation
import MailCore
import MailTransport
import OtegamiCore

/// `SMTPSessionProtocol` backed by MailCore2. Not exercised until M5
/// (Compose/Reply/SMTP) — every method throws
/// `MailTransportError.notImplemented` for now. Still wraps a real
/// `MCOSMTPSession` (rather than being an empty shell) so M5 only has to
/// add the `async`/`await` bridging, following the same pattern as
/// `MailCoreIMAPSession`.
public actor MailCoreSMTPSession: SMTPSessionProtocol {
    private let session: MCOSMTPSession

    public init(config: SMTPConfig) {
        let session = MCOSMTPSession()
        session.hostname = config.host
        session.port = UInt32(config.port)
        session.connectionType = MailCoreIMAPSession.connectionType(for: config.security)
        session.isCheckCertificateEnabled = !config.allowsInsecureTLS
        self.session = session
    }

    public func connect(auth: MailAuth) async throws {
        throw MailTransportError.notImplemented("MailCoreSMTPSession.connect — SMTP support lands in M5")
    }

    public func disconnect() async {
        // No-op until M5: there is nothing to tear down if connect() has
        // never succeeded.
    }

    public func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws {
        throw MailTransportError.notImplemented("MailCoreSMTPSession.sendMessage — SMTP support lands in M5")
    }
}
