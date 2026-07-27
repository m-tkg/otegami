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
        /// M8: scripted `fetchMessageBody(mailboxPath:uid:partId:)` results
        /// — mailbox path, then UID, then `partId` (`nil`-partId results
        /// keyed by the empty string, since `[String: Data]`'s key can't be
        /// optional; `AttachmentFetcherTests`/`AttachmentFetcher` itself
        /// never actually requests a `nil` partId, only real
        /// `AttachmentRecord.partId` values, so this is unused in practice
        /// but keeps the map's shape uniform).
        public var attachmentDataByPath: [String: [UInt32: [String: Data]]]
        /// When set, `fetchMessageBody(mailboxPath:uid:partId:)` throws
        /// this instead of consulting `attachmentDataByPath`.
        public var failAttachmentFetch: MailTransportError?
        /// Per-`(mailboxPath, uid)` scripted `fetchBody` failures —
        /// `BodyFetcherTests`' self-healing scenarios need `fetchBody` to
        /// fail with `.serverError` specifically (the shape `MailCoreErrorDomain
        /// error 19`/`MCOErrorFetch` surfaces as) to exercise `BodyFetcher
        /// .attemptSelfHeal`, distinct from the plain "no scripted body at
        /// all" `.malformedResponse` every other `fetchBody` test relies on
        /// (`fetchFailureRevertsBodyState`) — this takes priority over
        /// `bodiesByPath` when both are set for the same UID.
        public var failFetchBody: [String: [UInt32: MailTransportError]]
        /// When set, every `fetchEnvelopes(mailboxPath:uids:batchSize:)` call
        /// throws this instead of consulting `envelopesByPath` — scripts a
        /// server that can't even complete the `UID SEARCH`-equivalent
        /// existence check `BodyFetcher.attemptSelfHeal` does after a
        /// `fetchBody` failure (disconnect/timeout while confirming
        /// staleness), which must never be treated as confirmation that a
        /// UID is gone.
        public var failFetchEnvelopes: MailTransportError?
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
        /// When set, `createMailbox(path:)` throws this instead of
        /// succeeding — scripts a server that rejects `CREATE` (e.g. no
        /// permission), for `OpQueueProcessorTests`' Trash-auto-create
        /// fallback-to-`mailboxNotFound` case.
        public var failCreateMailbox: MailTransportError?
        /// The `MailboxInfo` a successful `createMailbox(path:)` should make
        /// visible on the *next* `listMailboxes()` call (mimicking a real
        /// server: the new mailbox doesn't exist until `CREATE` succeeds,
        /// but does from then on). `nil` means "script doesn't model this
        /// mailbox appearing" — a test that doesn't care about the
        /// subsequent re-list can leave it unset.
        public var mailboxRevealedAfterCreate: MailboxInfo?
        /// What `append(mailboxPath:messageData:flags:)` returns as the new
        /// message's UID — `nil` (the default) models a server without
        /// `UIDPLUS`; Drafts-sync tests set this to model one that has it,
        /// so `OpQueueProcessor`'s `.saveDraft` replay can capture
        /// `DraftMessageRecord.serverUid`.
        public var appendReturnsUID: UInt32?

        public init(
            mailboxes: [MailboxInfo] = [],
            envelopesByPath: [String: [FetchedEnvelope]] = [:],
            statusByPath: [String: MailboxStatus] = [:],
            bodiesByPath: [String: [UInt32: MessageBodyContent]] = [:],
            attachmentDataByPath: [String: [UInt32: [String: Data]]] = [:],
            failAttachmentFetch: MailTransportError? = nil,
            failFetchBody: [String: [UInt32: MailTransportError]] = [:],
            failFetchEnvelopes: MailTransportError? = nil,
            failConnection: MailTransportError? = nil,
            capabilitiesToReport: Set<IMAPCapability> = [],
            changedSinceEnvelopesByPath: [String: [FetchedEnvelope]] = [:],
            failChangedSince: MailTransportError? = nil,
            idleEvents: [IdleEvent] = [],
            failIdle: MailTransportError? = nil,
            failCreateMailbox: MailTransportError? = nil,
            mailboxRevealedAfterCreate: MailboxInfo? = nil,
            appendReturnsUID: UInt32? = nil
        ) {
            self.mailboxes = mailboxes
            self.envelopesByPath = envelopesByPath
            self.statusByPath = statusByPath
            self.bodiesByPath = bodiesByPath
            self.attachmentDataByPath = attachmentDataByPath
            self.failAttachmentFetch = failAttachmentFetch
            self.failFetchBody = failFetchBody
            self.failFetchEnvelopes = failFetchEnvelopes
            self.failConnection = failConnection
            self.capabilitiesToReport = capabilitiesToReport
            self.changedSinceEnvelopesByPath = changedSinceEnvelopesByPath
            self.failChangedSince = failChangedSince
            self.idleEvents = idleEvents
            self.failIdle = failIdle
            self.failCreateMailbox = failCreateMailbox
            self.mailboxRevealedAfterCreate = mailboxRevealedAfterCreate
            self.appendReturnsUID = appendReturnsUID
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
        /// M5: `append(mailboxPath:messageData:flags:)` calls (`OpQueueProcessor
        /// .send`'s best-effort Sent-mailbox copy), in call order.
        private var _appendCalls: [(path: String, messageData: Data, flags: MessageFlags)] = []
        /// `createMailbox(path:)` calls, in call order — lets a test assert
        /// the Trash auto-create fallback actually asked the server to
        /// create the mailbox it then retried the move against.
        private var _createMailboxCalls: [String] = []

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

        func recordAppend(path: String, messageData: Data, flags: MessageFlags) {
            lock.lock()
            _appendCalls.append((path, messageData, flags))
            lock.unlock()
        }

        func recordCreateMailbox(path: String) {
            lock.lock()
            _createMailboxCalls.append(path)
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

        public var appendCalls: [(path: String, messageData: Data, flags: MessageFlags)] {
            lock.lock()
            defer { lock.unlock() }
            return _appendCalls
        }

        public var createMailboxCalls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _createMailboxCalls
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
    /// Set once `createMailbox(path:)` succeeds and `script
    /// .mailboxRevealedAfterCreate` is non-nil — merged into
    /// `listMailboxes()`'s result from then on, modeling a real server
    /// where the newly created mailbox now exists.
    private var revealedMailbox: MailboxInfo?

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
        if let revealedMailbox {
            return script.mailboxes + [revealedMailbox]
        }
        return script.mailboxes
    }

    public func select(_ mailboxPath: String) async throws -> MailboxStatus {
        selectedPaths.append(mailboxPath)
        return try await status(mailboxPath)
    }

    public func createMailbox(path: String) async throws {
        recorder?.recordCreateMailbox(path: path)
        if let failCreateMailbox = script.failCreateMailbox {
            throw failCreateMailbox
        }
        if let mailboxRevealedAfterCreate = script.mailboxRevealedAfterCreate {
            revealedMailbox = mailboxRevealedAfterCreate
        }
    }

    public func status(_ mailboxPath: String) async throws -> MailboxStatus {
        guard let status = script.statusByPath[mailboxPath] else {
            throw MailTransportError.mailboxNotFound(path: mailboxPath)
        }
        return status
    }

    public func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        if let failFetchEnvelopes = script.failFetchEnvelopes {
            throw failFetchEnvelopes
        }
        fetchedRanges.append((mailboxPath, uids.lowerBound, uids.upperBound))
        let all = script.envelopesByPath[mailboxPath] ?? []
        return all
            .filter { envelope in envelope.uid >= uids.lowerBound && (uids.upperBound.map { upper in envelope.uid <= upper } ?? true) }
            .sorted { $0.uid < $1.uid }
    }

    /// Sequence-number counterpart of `fetchEnvelopes(mailboxPath:uids:
    /// batchSize:)` above: `script.envelopesByPath[mailboxPath]` already
    /// models "every message currently in this mailbox" (like a real
    /// server's contents), so the most recent `count` by *sequence* number
    /// is just its last `count` entries sorted by UID ascending — same
    /// "arrival order == UID order" assumption `FakeIMAPSession` makes
    /// throughout, and deliberately UID-gap-agnostic (unlike the UID-range
    /// overload above) to match what the real `MailCoreIMAPSession`
    /// implementation guarantees.
    public func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int) async throws -> [FetchedEnvelope] {
        guard count > 0 else { return [] }
        let all = (script.envelopesByPath[mailboxPath] ?? []).sorted { $0.uid < $1.uid }
        return Array(all.suffix(count))
    }

    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope] {
        if let failChangedSince = script.failChangedSince {
            throw failChangedSince
        }
        return script.changedSinceEnvelopesByPath[mailboxPath] ?? []
    }

    public func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        if let failure = script.failFetchBody[mailboxPath]?[uid] {
            throw failure
        }
        guard let content = script.bodiesByPath[mailboxPath]?[uid] else {
            throw MailTransportError.malformedResponse(
                underlyingDescription: "FakeIMAPSession has no scripted body for uid \(uid) in \(mailboxPath)"
            )
        }
        return content
    }

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        if let failAttachmentFetch = script.failAttachmentFetch {
            throw failAttachmentFetch
        }
        guard let data = script.attachmentDataByPath[mailboxPath]?[uid]?[partId ?? ""] else {
            throw MailTransportError.malformedResponse(
                underlyingDescription: "FakeIMAPSession has no scripted attachment data for uid \(uid), partId \(partId ?? "nil") in \(mailboxPath)"
            )
        }
        return data
    }

    public func store(mailboxPath: String, change: FlagChange) async throws {
        recorder?.recordStore(path: mailboxPath, change: change)
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        recorder?.recordAppend(path: mailboxPath, messageData: messageData, flags: flags)
        return script.appendReturnsUID
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
