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
        /// Scripted `fetchBody` results, keyed by mailbox path then UID —
        /// `BodyFetcher` tests script per-message plain/html/attachment
        /// content here rather than raw MIME bytes (see `fetchBody`'s doc
        /// comment: decoding is `MailTransportMailCore`'s job, so a Fake
        /// exercising `SyncEngine` in isolation is expected to hand back
        /// already-decoded content, same as the real backend would).
        public var bodiesByPath: [String: [UInt32: MessageBodyContent]]
        /// When set, `connect(auth:)` throws this instead of succeeding.
        public var failConnection: MailTransportError?
        /// What `capabilities()` reports — `MailboxSyncer`'s CONDSTORE
        /// branch only tests as `true` when a script sets `.condstore`
        /// here (M3).
        public var capabilitiesToReport: Set<IMAPCapability>
        /// `fetchEnvelopes(mailboxPath:changedSince:)`'s scripted result
        /// per mailbox path (M3) — the modSeq argument itself isn't
        /// consulted, since a test only ever needs one "what's changed"
        /// answer per `MailboxSyncer.incrementalSync` call.
        public var changedSinceEnvelopesByPath: [String: [FetchedEnvelope]]
        /// When set, `fetchEnvelopes(changedSince:)` throws this instead —
        /// scripts a non-CONDSTORE server for a test even if
        /// `capabilitiesToReport` doesn't already omit `.condstore`.
        public var failChangedSince: MailTransportError?
        /// Scripted `idle(mailboxPath:)` events (M3), yielded in order and
        /// then the stream finishes; empty means the stream finishes
        /// immediately with no events.
        public var idleEvents: [IdleEvent]
        /// When set, the idle stream throws this after yielding
        /// `idleEvents` (or immediately, if `idleEvents` is empty).
        public var failIdle: MailTransportError?

        public init(
            mailboxes: [MailboxInfo] = [],
            envelopesByPath: [String: [FetchedEnvelope]] = [:],
            statusByPath: [String: MailboxStatus] = [:],
            bodiesByPath: [String: [UInt32: MessageBodyContent]] = [:],
            failConnection: MailTransportError? = nil,
            capabilitiesToReport: Set<IMAPCapability> = [],
            changedSinceEnvelopesByPath: [String: [FetchedEnvelope]] = [:],
            failChangedSince: MailTransportError? = nil,
            idleEvents: [IdleEvent] = [],
            failIdle: MailTransportError? = nil
        ) {
            self.mailboxes = mailboxes
            self.envelopesByPath = envelopesByPath
            self.statusByPath = statusByPath
            self.bodiesByPath = bodiesByPath
            self.failConnection = failConnection
            self.capabilitiesToReport = capabilitiesToReport
            self.changedSinceEnvelopesByPath = changedSinceEnvelopesByPath
            self.failChangedSince = failChangedSince
            self.idleEvents = idleEvents
            self.failIdle = failIdle
        }
    }

    /// Thread-safe recorder for `store`/`move`/`expunge` calls (M3),
    /// shared across however many `FakeIMAPSession` instances a test's
    /// session factory creates (e.g. `OpQueueProcessor.replay` opens its
    /// own connection separately from whatever `MailboxSyncer` used) —
    /// pass the same instance to every `FakeIMAPSession(config:script:
    /// recorder:)` a test's session factory constructs to see every call
    /// made across all of them, in call order.
    public final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _storeCalls: [(path: String, change: FlagChange)] = []
        private var _moveCalls: [(path: String, uids: [UInt32], destination: String)] = []
        private var _expungeCalls: [String] = []

        public init() {}

        func recordStore(path: String, change: FlagChange) {
            lock.lock()
            _storeCalls.append((path, change))
            lock.unlock()
        }

        func recordMove(path: String, uids: [UInt32], destination: String) {
            lock.lock()
            _moveCalls.append((path, uids, destination))
            lock.unlock()
        }

        func recordExpunge(path: String) {
            lock.lock()
            _expungeCalls.append(path)
            lock.unlock()
        }

        public var storeCalls: [(path: String, change: FlagChange)] {
            lock.lock()
            defer { lock.unlock() }
            return _storeCalls
        }

        public var moveCalls: [(path: String, uids: [UInt32], destination: String)] {
            lock.lock()
            defer { lock.unlock() }
            return _moveCalls
        }

        public var expungeCalls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _expungeCalls
        }
    }

    public let config: IMAPConfig
    private let script: Script
    private let recorder: CallRecorder?
    public private(set) var connected = false
    public private(set) var selectedPaths: [String] = []
    /// Every `fetchEnvelopes(mailboxPath:uids:batchSize:)` call's requested
    /// range, in call order — lets a test assert exactly which UID window
    /// `AccountSyncer` asked for, not just what came back.
    public private(set) var fetchedRanges: [(path: String, lowerBound: UInt32, upperBound: UInt32?)] = []

    /// Satisfies `IMAPSessionProtocol`'s required initializer with an empty
    /// script. Tests should use ``init(config:script:recorder:)`` instead
    /// so the session actually has data to serve.
    public init(config: IMAPConfig) {
        self.config = config
        self.script = Script()
        self.recorder = nil
    }

    public init(config: IMAPConfig, script: Script, recorder: CallRecorder? = nil) {
        self.config = config
        self.script = script
        self.recorder = recorder
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
        script.capabilitiesToReport
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
        if let failChangedSince = script.failChangedSince {
            throw failChangedSince
        }
        return script.changedSinceEnvelopesByPath[mailboxPath] ?? []
    }

    public func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        guard let content = script.bodiesByPath[mailboxPath]?[uid] else {
            throw MailTransportError.malformedResponse(
                underlyingDescription: "FakeIMAPSession has no scripted body for uid \(uid) in \(mailboxPath)"
            )
        }
        return content
    }

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script raw per-part fetch (M8) behavior")
    }

    public func store(mailboxPath: String, change: FlagChange) async throws {
        recorder?.recordStore(path: mailboxPath, change: change)
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        throw MailTransportError.notImplemented("FakeIMAPSession doesn't script APPEND (M5) behavior")
    }

    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        recorder?.recordMove(path: mailboxPath, uids: uids.uids, destination: destinationPath)
    }

    public func expunge(mailboxPath: String) async throws {
        recorder?.recordExpunge(path: mailboxPath)
    }

    public nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        let events = script.idleEvents
        let failIdle = script.failIdle
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if let failIdle {
                continuation.finish(throwing: failIdle)
            } else {
                continuation.finish()
            }
        }
    }
}
