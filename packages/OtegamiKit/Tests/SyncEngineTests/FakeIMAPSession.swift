import Foundation
import MailTransport
import OtegamiCore

/// A scriptable, in-memory `IMAPSessionProtocol` double for `SyncEngine`
/// scenario tests. `SyncCoordinator`/`AccountSyncer` never talk to
/// MailCore2 directly, so this is enough to exercise the full initial-sync
/// flow (list mailboxes → select INBOX → fetch envelope batches) without a
/// real IMAP server.
///
/// One instance per connection, built fresh by the injected session
/// factory for each `connect()` — matching how `MailCoreIMAPSession` is
/// used in production (one instance wraps one physical connection).
public actor FakeIMAPSession: IMAPSessionProtocol {
    /// The fixed data set this session serves. Shared (read-only) across
    /// however many `FakeIMAPSession` instances a test's session factory
    /// creates, so repeated syncs against "the same server" see the same
    /// mailboxes/envelopes.
    public struct Script: Sendable {
        public var mailboxes: [MailboxInfo]
        public var envelopesByPath: [String: [FetchedEnvelope]]
        public var statusByPath: [String: MailboxStatus]
        /// When set, `connect(auth:)` throws this instead of succeeding.
        public var failConnection: MailTransportError?

        public init(
            mailboxes: [MailboxInfo] = [],
            envelopesByPath: [String: [FetchedEnvelope]] = [:],
            statusByPath: [String: MailboxStatus] = [:],
            failConnection: MailTransportError? = nil
        ) {
            self.mailboxes = mailboxes
            self.envelopesByPath = envelopesByPath
            self.statusByPath = statusByPath
            self.failConnection = failConnection
        }
    }

    public let config: IMAPConfig
    private let script: Script
    public private(set) var connected = false
    public private(set) var selectedPaths: [String] = []
    /// Every `fetchEnvelopes(mailboxPath:uids:batchSize:)` call's requested
    /// range, in call order — lets a test assert exactly which UID window
    /// `AccountSyncer` asked for, not just what came back.
    public private(set) var fetchedRanges: [(path: String, lowerBound: UInt32, upperBound: UInt32?)] = []

    /// Satisfies `IMAPSessionProtocol`'s required initializer with an empty
    /// script. Tests should use ``init(config:script:)`` instead so the
    /// session actually has data to serve.
    public init(config: IMAPConfig) {
        self.config = config
        self.script = Script()
    }

    public init(config: IMAPConfig, script: Script) {
        self.config = config
        self.script = script
    }

    public func connect(auth: MailAuth) async throws {
        if let failConnection = script.failConnection {
            throw failConnection
        }
        connected = true
    }

    public func disconnect() async {
        connected = false
    }

    public func capabilities() async throws -> Set<IMAPCapability> {
        []
    }

    public func listMailboxes() async throws -> [MailboxInfo] {
        script.mailboxes
    }

    public func select(_ mailboxPath: String) async throws -> MailboxStatus {
        selectedPaths.append(mailboxPath)
        return try await status(mailboxPath)
    }

    public func status(_ mailboxPath: String) async throws -> MailboxStatus {
        guard let status = script.statusByPath[mailboxPath] else {
            throw MailTransportError.mailboxNotFound(path: mailboxPath)
        }
        return status
    }

    public func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        fetchedRanges.append((mailboxPath, uids.lowerBound, uids.upperBound))
        let all = script.envelopesByPath[mailboxPath] ?? []
        return all
            .filter { envelope in envelope.uid >= uids.lowerBound && (uids.upperBound.map { upper in envelope.uid <= upper } ?? true) }
            .sorted { $0.uid < $1.uid }
    }

    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope] {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script CONDSTORE (M3) behavior")
    }

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script body fetch (M2) behavior")
    }

    public func store(mailboxPath: String, change: FlagChange) async throws {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script STORE (M3) behavior")
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script APPEND (M5) behavior")
    }

    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script MOVE (M5) behavior")
    }

    public func expunge(mailboxPath: String) async throws {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script EXPUNGE (M3) behavior")
    }

    public nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailTransportError.notImplemented("FakeIMAPSession doesn't script IDLE (M3) behavior"))
        }
    }
}
