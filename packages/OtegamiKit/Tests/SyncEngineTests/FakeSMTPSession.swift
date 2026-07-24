import Foundation
import MailTransport
import OtegamiCore

/// A scriptable, in-memory `SMTPSessionProtocol` double for `OpQueueProcessor
/// .send` replay tests (M5) — the SMTP counterpart of `FakeIMAPSession`.
public actor FakeSMTPSession: SMTPSessionProtocol {
    public struct Script: Sendable {
        /// When set, `connect(auth:)` throws this instead of succeeding.
        public var failConnection: MailTransportError?
        /// When set, `sendMessage` throws this instead of recording the
        /// call and succeeding.
        public var failSend: MailTransportError?

        public init(failConnection: MailTransportError? = nil, failSend: MailTransportError? = nil) {
            self.failConnection = failConnection
            self.failSend = failSend
        }
    }

    /// Thread-safe recorder for `sendMessage` calls, shared across however
    /// many `FakeSMTPSession` instances a test's session factory creates —
    /// same pattern as `FakeIMAPSession.CallRecorder`.
    public final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _sendCalls: [(messageData: Data, from: EmailAddress, recipients: [EmailAddress])] = []
        private var _connectAuths: [MailAuth] = []

        public init() {}

        func recordSend(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) {
            lock.lock()
            _sendCalls.append((messageData, from, recipients))
            lock.unlock()
        }

        func recordConnect(auth: MailAuth) {
            lock.lock()
            _connectAuths.append(auth)
            lock.unlock()
        }

        public var sendCalls: [(messageData: Data, from: EmailAddress, recipients: [EmailAddress])] {
            lock.lock()
            defer { lock.unlock() }
            return _sendCalls
        }

        /// Every `connect(auth:)` call, in order — `OpQueueProcessorTests`
        /// uses this to assert `OpQueueProcessor.smtpAuth` actually derives
        /// SMTP-specific credentials from `account.smtpUsername` rather
        /// than reusing the IMAP auth verbatim.
        public var connectAuths: [MailAuth] {
            lock.lock()
            defer { lock.unlock() }
            return _connectAuths
        }
    }

    public let config: SMTPConfig
    private let script: Script
    private let recorder: CallRecorder?
    public private(set) var connected = false

    /// Satisfies `SMTPSessionProtocol`'s required initializer with an empty
    /// script (always succeeds, records nothing). Tests should use
    /// ``init(config:script:recorder:)`` instead.
    public init(config: SMTPConfig) {
        self.config = config
        self.script = Script()
        self.recorder = nil
    }

    public init(config: SMTPConfig, script: Script, recorder: CallRecorder? = nil) {
        self.config = config
        self.script = script
        self.recorder = recorder
    }

    public func connect(auth: MailAuth) async throws {
        recorder?.recordConnect(auth: auth)
        if let failConnection = script.failConnection {
            throw failConnection
        }
        connected = true
    }

    public func disconnect() async {
        connected = false
    }

    public func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws {
        if let failSend = script.failSend {
            throw failSend
        }
        recorder?.recordSend(messageData: messageData, from: from, recipients: recipients)
    }
}
