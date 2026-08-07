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
        /// Task #194: when set, every `fetchFlags(mailboxPath:uids:)` call
        /// throws this instead of consulting `envelopesByPath` — scripts a
        /// dropped/timed-out flags-only `FETCH`, for `refetchAndDiffFlags`'s
        /// non-destructive-on-failure guard the same way `failFetchEnvelopes`
        /// does for the old full-envelope path.
        public var failFetchFlags: MailTransportError?
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
        /// Task #79: `fetchEnvelopes(changedSince:)`'s scripted
        /// `ChangedSinceResult.vanishedUIDs`, per mailbox path — models a
        /// QRESYNC-capable server directly reporting expunged UIDs. Absent
        /// for a path (the default) means "not scripted", which
        /// `fetchEnvelopes(changedSince:)` maps to `nil` (no QRESYNC info —
        /// matching every CONDSTORE test written before Task #79, which
        /// don't opt into this and shouldn't need to) rather than an empty
        /// set (which would instead assert "QRESYNC active, confirmed
        /// nothing vanished").
        public var qresyncVanishedUIDsByPath: [String: Set<UInt32>]
        /// Task #79: `searchExistingUIDs(mailboxPath:uids:)`'s scripted
        /// result, per mailbox path — models the CONDSTORE-without-QRESYNC
        /// fallback's `UID SEARCH` (Gmail's case). Absent for a path (the
        /// default) makes `searchExistingUIDs` report an empty result,
        /// which — combined with `MailboxSyncer.detectAndRemoveVanishedByUIDSearch`'s
        /// own "empty search + mailbox still reports messages" guard —
        /// keeps every existing CONDSTORE test (which predates this fallback
        /// and never scripts it) from spuriously mass-deleting, as long as
        /// its scripted `MailboxStatus.messageCount` is non-zero (true of
        /// every one of them).
        public var existingUIDsByPath: [String: Set<UInt32>]
        /// When set, `searchExistingUIDs(mailboxPath:uids:)` throws this
        /// instead — scripts a dropped/timed-out `UID SEARCH` round trip, to
        /// confirm the CONDSTORE-path fallback stays as non-destructive as
        /// the non-CONDSTORE path's own thrown-error case.
        public var failSearchExistingUIDs: MailTransportError?
        /// `searchMessages(mailboxPath:query:)`'s scripted result, per
        /// mailbox path — `ServerSearchService`'s IMAP `SEARCH` fallback
        /// (「サーバーで検索」). The query text itself isn't consulted (a test
        /// only ever needs one "what the server found" answer per mailbox,
        /// same simplification `changedSinceEnvelopesByPath` makes).
        public var searchMessagesByPath: [String: Set<UInt32>]
        /// When set, `searchMessages(mailboxPath:query:)` throws this
        /// instead — scripts a dropped/timed-out `SEARCH`, so
        /// `ServerSearchService`/`SyncCoordinator.serverSearch`'s per-account
        /// failure tolerance can be exercised without a real server.
        public var failSearchMessages: MailTransportError?
        /// A one-shot async gate (see `AsyncCallGate`'s doc comment) that,
        /// when set, `searchMessages(mailboxPath:query:)` awaits *before*
        /// returning its scripted result — models a `SEARCH` that never
        /// completes (a hung/unreachable server), for
        /// `SyncCoordinator.serverSearch`'s overall-timeout tests. Left
        /// ungated (`nil`, the default) for every other test.
        public var searchMessagesGate: AsyncCallGate?
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

        /// Task #69 (`AccountSyncer` automatic-retry): a mailbox-level retry
        /// (unlike `connect()`'s) reuses the *same* `FakeIMAPSession`
        /// instance across every in-process attempt rather than asking
        /// `sessionFactory` for a fresh one each time (see
        /// `AccountSyncer.syncMailboxWithRetry`'s doc comment for why) — so
        /// a plain `failFetchEnvelopes` (thrown unconditionally, forever)
        /// can't script "fails N times then succeeds" the way varying the
        /// session factory's returned script per call already does for
        /// `connectFailureSchedule`. This is that same "fail-then-succeed"
        /// knob, scoped to `fetchRecentEnvelopes` — the call
        /// `AccountSyncerTests`' mailbox-level retry scenarios exercise via
        /// `performInitialSync`. `nil` (default): no failure injected.
        public var flakyFetchRecentEnvelopes: FlakyCallController?
        /// When set, every `store` call pauses after announcing that it
        /// reached the server boundary, until the test opens the gate.
        /// Used to deterministically overlap two op-queue replay calls.
        public var storeGate: AsyncCallGate?
        /// Task #221: same idea as `storeGate`, for `fetchBody` — pauses
        /// every call after announcing it reached the server boundary,
        /// until the test opens the gate. Lets `BodyFetcherTests`
        /// deterministically overlap `BodyFetcher.prefetchRecent`'s
        /// in-loop fetch of one candidate with a separate, independent
        /// `fetchBody` call for a *different* candidate finishing first —
        /// exactly the race `prefetchRecent`'s fresh already-fetched
        /// recheck guards against.
        public var fetchBodyGate: AsyncCallGate?
        /// Task (opqueue スタック修正): same idea as `storeGate`, for
        /// `connect(auth:)` — a gate that's never `open()`ed models a
        /// permanently-hung `connect()` call (the exact real-device failure
        /// mode `OpQueueProcessor.replayPass`'s `connectTimeout` now guards
        /// against), letting `OpQueueProcessorTests`'s timeout/stale-in-
        /// flight-takeover tests reproduce it deterministically instead of
        /// needing a real dead socket.
        public var connectGate: AsyncCallGate?

        public init(
            mailboxes: [MailboxInfo] = [],
            envelopesByPath: [String: [FetchedEnvelope]] = [:],
            statusByPath: [String: MailboxStatus] = [:],
            bodiesByPath: [String: [UInt32: MessageBodyContent]] = [:],
            attachmentDataByPath: [String: [UInt32: [String: Data]]] = [:],
            failAttachmentFetch: MailTransportError? = nil,
            failFetchBody: [String: [UInt32: MailTransportError]] = [:],
            failFetchEnvelopes: MailTransportError? = nil,
            failFetchFlags: MailTransportError? = nil,
            failConnection: MailTransportError? = nil,
            capabilitiesToReport: Set<IMAPCapability> = [],
            changedSinceEnvelopesByPath: [String: [FetchedEnvelope]] = [:],
            failChangedSince: MailTransportError? = nil,
            qresyncVanishedUIDsByPath: [String: Set<UInt32>] = [:],
            existingUIDsByPath: [String: Set<UInt32>] = [:],
            failSearchExistingUIDs: MailTransportError? = nil,
            searchMessagesByPath: [String: Set<UInt32>] = [:],
            failSearchMessages: MailTransportError? = nil,
            searchMessagesGate: AsyncCallGate? = nil,
            idleEvents: [IdleEvent] = [],
            failIdle: MailTransportError? = nil,
            failCreateMailbox: MailTransportError? = nil,
            mailboxRevealedAfterCreate: MailboxInfo? = nil,
            appendReturnsUID: UInt32? = nil,
            flakyFetchRecentEnvelopes: FlakyCallController? = nil,
            storeGate: AsyncCallGate? = nil,
            fetchBodyGate: AsyncCallGate? = nil,
            connectGate: AsyncCallGate? = nil
        ) {
            self.mailboxes = mailboxes
            self.envelopesByPath = envelopesByPath
            self.statusByPath = statusByPath
            self.bodiesByPath = bodiesByPath
            self.attachmentDataByPath = attachmentDataByPath
            self.failAttachmentFetch = failAttachmentFetch
            self.failFetchBody = failFetchBody
            self.failFetchEnvelopes = failFetchEnvelopes
            self.failFetchFlags = failFetchFlags
            self.failConnection = failConnection
            self.capabilitiesToReport = capabilitiesToReport
            self.changedSinceEnvelopesByPath = changedSinceEnvelopesByPath
            self.failChangedSince = failChangedSince
            self.qresyncVanishedUIDsByPath = qresyncVanishedUIDsByPath
            self.existingUIDsByPath = existingUIDsByPath
            self.failSearchExistingUIDs = failSearchExistingUIDs
            self.searchMessagesByPath = searchMessagesByPath
            self.failSearchMessages = failSearchMessages
            self.searchMessagesGate = searchMessagesGate
            self.idleEvents = idleEvents
            self.failIdle = failIdle
            self.failCreateMailbox = failCreateMailbox
            self.mailboxRevealedAfterCreate = mailboxRevealedAfterCreate
            self.appendReturnsUID = appendReturnsUID
            self.flakyFetchRecentEnvelopes = flakyFetchRecentEnvelopes
            self.storeGate = storeGate
            self.fetchBodyGate = fetchBodyGate
            self.connectGate = connectGate
        }
    }

    /// A one-shot async gate for deterministic overlap tests. `wait()`
    /// first wakes `waitUntilEntered()`, then suspends until `open()`.
    public actor AsyncCallGate {
        private var isOpen = false
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        public init() {}

        public func wait() async {
            entered = true
            let currentEntryWaiters = entryWaiters
            entryWaiters.removeAll()
            currentEntryWaiters.forEach { $0.resume() }
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        public func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        public func open() {
            isOpen = true
            let currentOpenWaiters = openWaiters
            openWaiters.removeAll()
            currentOpenWaiters.forEach { $0.resume() }
        }
    }

    /// Task #69: see `Script.flakyFetchRecentEnvelopes`'s doc comment.
    /// `@unchecked Sendable` + `NSLock`, same shape as `CallRecorder` above
    /// — needs synchronous mutation from a `@Sendable` context (this is
    /// consulted from `fetchRecentEnvelopes`, itself called from
    /// `AccountSyncer`'s actor-isolated retry loop, but the type must still
    /// be safely shareable across the several `FakeIMAPSession` instances
    /// one retrying test's session factory creates).
    public final class FlakyCallController: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        private let error: MailTransportError

        public init(failCount: Int, error: MailTransportError) {
            self.remainingFailures = failCount
            self.error = error
        }

        /// Consumes one "remaining failure" and returns the scripted error,
        /// or `nil` once `failCount` calls have already failed (every call
        /// from then on should succeed).
        func nextResult() -> MailTransportError? {
            lock.lock()
            defer { lock.unlock() }
            guard remainingFailures > 0 else { return nil }
            remainingFailures -= 1
            return error
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
        /// Task #87 (1): `copy(mailboxPath:uids:to:)` calls — kept separate
        /// from `_moveCalls` so a test can assert "this was a COPY, the
        /// source mailbox was never touched" (Gmail's アーカイブ解除 replay)
        /// as distinct from a real move.
        private var _copyCalls: [(path: String, uids: [UInt32], destination: String)] = []
        private var _expungeCalls: [String] = []
        /// M5: `append(mailboxPath:messageData:flags:)` calls (`OpQueueProcessor
        /// .send`'s best-effort Sent-mailbox copy), in call order.
        private var _appendCalls: [(path: String, messageData: Data, flags: MessageFlags)] = []
        /// `createMailbox(path:)` calls, in call order — lets a test assert
        /// the Trash auto-create fallback actually asked the server to
        /// create the mailbox it then retried the move against.
        private var _createMailboxCalls: [String] = []
        /// How many times `listMailboxes()` was actually called across
        /// every `FakeIMAPSession` instance sharing this recorder — a fresh
        /// `FakeIMAPSession` is built per `connect()` (see this type's own
        /// doc comment), so `AccountSyncer.cachedMailboxListing`'s TTL cache
        /// can only be observed from the outside by sharing one recorder
        /// across the several sessions a multi-pass test's session factory
        /// creates, the same way `_storeCalls`/etc. already are.
        private var _listMailboxesCallCount = 0
        /// Phase 3 (IMAP 接続の再利用): every `connect(auth:)` call across
        /// every `FakeIMAPSession` instance sharing this recorder, in call
        /// order — lets `PooledIMAPSessionFactory` tests assert exactly how
        /// many *real* connections the underlying factory actually made
        /// (as opposed to how many `PooledIMAPSession` wrapper `connect`
        /// calls happened, which may be more if some were served from the
        /// pool without a real connect).
        private var _connectCalls: [String] = []
        /// Every `disconnect()` call across every instance sharing this
        /// recorder, in call order — same rationale as `_connectCalls`,
        /// for asserting the pool actually tore down (vs. kept pooling) a
        /// given underlying session.
        private var _disconnectCallCount = 0

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

        func recordCopy(path: String, uids: [UInt32], destination: String) {
            lock.lock()
            _copyCalls.append((path, uids, destination))
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

        func recordListMailboxes() {
            lock.lock()
            _listMailboxesCallCount += 1
            lock.unlock()
        }

        func recordConnect(username: String) {
            lock.lock()
            _connectCalls.append(username)
            lock.unlock()
        }

        func recordDisconnect() {
            lock.lock()
            _disconnectCallCount += 1
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

        public var copyCalls: [(path: String, uids: [UInt32], destination: String)] {
            lock.lock()
            defer { lock.unlock() }
            return _copyCalls
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

        public var listMailboxesCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _listMailboxesCallCount
        }

        /// Phase 3: every `connect(auth:)` call's username, in call order.
        public var connectCalls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _connectCalls
        }

        public var connectCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _connectCalls.count
        }

        public var disconnectCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _disconnectCallCount
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
    /// Task #194: every `fetchFlags(mailboxPath:uids:)` call's requested
    /// range, in call order — same shape as `fetchedRanges` above, for
    /// tests asserting `refetchAndDiffFlags` chunks its requests instead of
    /// asking for the whole locally-synced window in one call.
    public private(set) var fetchFlagsCalls: [(path: String, lowerBound: UInt32, upperBound: UInt32?)] = []
    /// Every `fetchFlags(mailboxPath:uids: UIDSet)` call's exact requested
    /// UID list, in call order — unlike `fetchFlagsCalls` (which records
    /// this overload's calls too, as min/max bounds for backward
    /// compatibility with range-based assertions), this preserves the full,
    /// possibly-sparse set so a test can assert *which* UIDs were actually
    /// requested per chunk, not just the span they fall within.
    public private(set) var fetchFlagsSetCalls: [(path: String, uids: [UInt32])] = []
    /// Every `fetchEnvelopes(mailboxPath:uids: UIDSet)` call, in call order
    /// — lets a test assert the unknown-UID reconciliation fetch actually
    /// addressed the exact (possibly sparse) UID set it needed, not a
    /// `min...max` range spanning far more of the mailbox than necessary.
    public private(set) var fetchEnvelopesSetCalls: [(path: String, uids: UIDSet)] = []
    /// Every `fetchEnvelopes(mailboxPath:changedSince:)`/`fetchFlags
    /// (mailboxPath:changedSince:)` call, in call order — lets a test
    /// assert whether `MailboxSyncer`'s CONDSTORE baseline guard actually
    /// avoided CHANGEDSINCE (stored `highestModSeq == 0`) or used it with
    /// the expected stored modSeq.
    public private(set) var changedSinceCalls: [(path: String, modSeq: UInt64)] = []
    /// Task #221: every `fetchBody(mailboxPath:uid:)` call, in call order —
    /// lets a test assert `BodyFetcher.prefetchRecent`'s fresh
    /// already-fetched recheck actually skipped a network fetch for a
    /// message another pass beat it to, rather than just asserting on the
    /// (indirect) `successCount` return value.
    public private(set) var fetchBodyCalls: [(path: String, uid: UInt32)] = []
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
        let username: String
        switch auth {
        case .password(let value, _): username = value
        case .xoauth2(let value, _): username = value
        }
        recorder?.recordConnect(username: username)
        if let connectGate = script.connectGate {
            await connectGate.wait()
        }
        if let failConnection = script.failConnection {
            throw failConnection
        }
        connected = true
    }

    public func disconnect() async {
        recorder?.recordDisconnect()
        connected = false
    }

    public func capabilities() async throws -> Set<IMAPCapability> {
        script.capabilitiesToReport
    }

    public func listMailboxes() async throws -> [MailboxInfo] {
        recorder?.recordListMailboxes()
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

    /// `UIDSet` overload — see `IMAPSessionProtocol.fetchEnvelopes
    /// (mailboxPath:uids: UIDSet)`'s doc comment. Derives its answer from
    /// the same `script.envelopesByPath` the `UIDRange` overload above
    /// reads, filtered to exactly the requested (possibly sparse) set —
    /// `fetchEnvelopesSetCalls` records the exact UIDs asked for, so a test
    /// can assert `MailboxSyncer.applyFlagsDiffAndReconcileUnknown` never
    /// widens an unknown-UID reconciliation into a `min...max` range.
    public func fetchEnvelopes(mailboxPath: String, uids: UIDSet) async throws -> [FetchedEnvelope] {
        if let failFetchEnvelopes = script.failFetchEnvelopes {
            throw failFetchEnvelopes
        }
        fetchEnvelopesSetCalls.append((mailboxPath, uids))
        let uidSet = Set(uids.uids)
        let all = script.envelopesByPath[mailboxPath] ?? []
        return all.filter { uidSet.contains($0.uid) }.sorted { $0.uid < $1.uid }
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
    public func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope] {
        if let flaky = script.flakyFetchRecentEnvelopes, let error = flaky.nextResult() {
            throw error
        }
        guard count > 0 else { return [] }
        let all = (script.envelopesByPath[mailboxPath] ?? []).sorted { $0.uid < $1.uid }
        return Array(all.suffix(count))
    }

    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        changedSinceCalls.append((mailboxPath, modSeq))
        if let failChangedSince = script.failChangedSince {
            throw failChangedSince
        }
        return ChangedSinceResult(
            envelopes: script.changedSinceEnvelopesByPath[mailboxPath] ?? [],
            vanishedUIDs: script.qresyncVanishedUIDsByPath[mailboxPath]
        )
    }

    /// Derives its answer from the same `script.changedSinceEnvelopesByPath`
    /// (and `failChangedSince`/`qresyncVanishedUIDsByPath`) the full-envelope
    /// overload above reads — a script models one "what changed since
    /// modSeq" answer per mailbox, and every existing CONDSTORE-path test
    /// already scripts that shape; duplicating it into a separate
    /// flags-only fixture would risk the two silently drifting apart. A UID
    /// this maps needs a full envelope re-fetch for (this pass's "unknown to
    /// the local snapshot" case) should also appear in `script
    /// .envelopesByPath[mailboxPath]` — the data `fetchEnvelopes(uids:
    /// batchSize:)` actually reads from — the same way it already does for
    /// `refetchAndDiffFlags`'s non-CONDSTORE equivalent.
    public func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult {
        changedSinceCalls.append((mailboxPath, modSeq))
        if let failChangedSince = script.failChangedSince {
            throw failChangedSince
        }
        var flagsByUID: [UInt32: MessageFlags] = [:]
        for envelope in script.changedSinceEnvelopesByPath[mailboxPath] ?? [] {
            flagsByUID[envelope.uid] = envelope.flags
        }
        return ChangedSinceFlagsResult(
            flagsByUID: flagsByUID,
            vanishedUIDs: script.qresyncVanishedUIDsByPath[mailboxPath]
        )
    }

    public func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        if let failSearchExistingUIDs = script.failSearchExistingUIDs {
            throw failSearchExistingUIDs
        }
        let scripted = script.existingUIDsByPath[mailboxPath] ?? []
        return scripted.filter { uids.contains($0) }
    }

    /// Every `searchMessages(mailboxPath:query:)` call, in call order —
    /// `ServerSearchService` tests assert exactly which mailboxes actually
    /// got searched (e.g. a Gmail account's All-Mail-only targeting).
    public private(set) var searchMessagesCalls: [(path: String, query: String)] = []

    public func searchMessages(mailboxPath: String, query: String) async throws -> Set<UInt32> {
        searchMessagesCalls.append((mailboxPath, query))
        if let gate = script.searchMessagesGate {
            await gate.wait()
        }
        if let failSearchMessages = script.failSearchMessages {
            throw failSearchMessages
        }
        return script.searchMessagesByPath[mailboxPath] ?? []
    }

    /// Task #194: derives its answer from `script.envelopesByPath` (the
    /// same "what the server currently has" data `fetchEnvelopes` reads) —
    /// a `FakeIMAPSession` script models one data set per mailbox, and
    /// duplicating it into a separate flags-only fixture would risk the two
    /// silently drifting apart across a test's scenario. `fetchFlagsCalls`
    /// records each call the same way `fetchedRanges` does for
    /// `fetchEnvelopes`, so a test can assert `refetchAndDiffFlags`
    /// actually chunked its request rather than asking for the whole range
    /// in one call.
    public func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        if let failFetchFlags = script.failFetchFlags {
            throw failFetchFlags
        }
        fetchFlagsCalls.append((mailboxPath, uids.lowerBound, uids.upperBound))
        let all = script.envelopesByPath[mailboxPath] ?? []
        var result: [UInt32: MessageFlags] = [:]
        for envelope in all where uids.contains(envelope.uid) {
            result[envelope.uid] = envelope.flags
        }
        return result
    }

    /// `UIDSet` overload (see `IMAPSessionProtocol.fetchFlags(mailboxPath:
    /// uids:)`'s doc comment for the `UIDSet` variant) — records into the
    /// same `fetchFlagsCalls` (as the requested set's min/max, matching what
    /// a real `MCOIndexSet`-backed range chunk would report) so every
    /// existing test asserting on that array keeps working unchanged for a
    /// dense chunk, plus `fetchFlagsSetCalls` for tests that need the exact
    /// (possibly sparse) UID set actually requested.
    public func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags] {
        if let failFetchFlags = script.failFetchFlags {
            throw failFetchFlags
        }
        fetchFlagsSetCalls.append((mailboxPath, uids.uids))
        if let minUID = uids.uids.min(), let maxUID = uids.uids.max() {
            fetchFlagsCalls.append((mailboxPath, minUID, maxUID))
        }
        let uidSet = Set(uids.uids)
        let all = script.envelopesByPath[mailboxPath] ?? []
        var result: [UInt32: MessageFlags] = [:]
        for envelope in all where uidSet.contains(envelope.uid) {
            result[envelope.uid] = envelope.flags
        }
        return result
    }

    public func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        fetchBodyCalls.append((mailboxPath, uid))
        if let fetchBodyGate = script.fetchBodyGate {
            await fetchBodyGate.wait()
        }
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
        if let storeGate = script.storeGate {
            await storeGate.wait()
        }
        recorder?.recordStore(path: mailboxPath, change: change)
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        recorder?.recordAppend(path: mailboxPath, messageData: messageData, flags: flags)
        return script.appendReturnsUID
    }

    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        recorder?.recordMove(path: mailboxPath, uids: uids.uids, destination: destinationPath)
    }

    public func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        recorder?.recordCopy(path: mailboxPath, uids: uids.uids, destination: destinationPath)
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
