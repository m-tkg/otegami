import Foundation
import MailCore
import MailTransport
import OtegamiCore
import os

/// `IMAPSessionProtocol` backed by MailCore2 (via the `MailCore` Swift
/// package). One instance wraps one `MCOIMAPSession` (one physical
/// connection); the `actor` isolation serializes access the same way a
/// single IMAP connection would need to be serialized regardless.
///
/// MailCore2's own API is callback-based (`operation.start { error, result in
/// ... }`); every method here bridges that to `async`/`await` via
/// `withCheckedThrowingContinuation`, converting MailCore2's model objects
/// (`MCOIMAPFolder`, `MCOIMAPMessage`, ...) into this package's `Sendable`
/// `MailTransport` value types *inside* the completion closure, before the
/// result crosses back into the calling `Task`. That keeps every value that
/// actually crosses an isolation boundary `Sendable`, without needing
/// MailCore2's (non-`Sendable`) classes to be `Sendable` themselves.
public actor MailCoreIMAPSession: IMAPSessionProtocol {
    // `nonisolated(unsafe)`: every other access to this property stays
    // actor-isolated as normal; the only nonisolated access is `deinit`
    // below, which by construction runs after the last strong reference
    // (so no other isolation domain can be touching `session`
    // concurrently) but still needs to read it from a nonisolated
    // context to hand it to `SessionLingerBox`.
    private nonisolated(unsafe) let session: MCOIMAPSession
    private var connected = false

    /// Whether the server advertised `X-GM-EXT-1` at connect time.
    /// `fetchEnvelopesBatch` only requests the `X-GM-THRID`/`X-GM-MSGID`
    /// FETCH attributes when this is `true` — libetpan/MailCore2 send
    /// those attributes verbatim regardless of server support, and a
    /// non-Gmail server (e.g. the dev mailstack's Dovecot) replies `BAD
    /// Unknown parameter: X-GM-THRID` to the *entire* FETCH command if
    /// asked for them.
    private var gmailExtensionsSupported = false

    /// The server's advertised capabilities, captured once at `connect`
    /// time (M3) — `capabilities()` returns this cached snapshot rather
    /// than issuing a fresh `CAPABILITY` round trip on every call, and
    /// `move`/`fetchEnvelopes(changedSince:)` consult it directly to decide
    /// between `MOVE`/`COPY`+`STORE`+`EXPUNGE` and CONDSTORE/full-refetch.
    private var cachedCapabilities: Set<IMAPCapability> = []

    /// Phase 2 IMAP-roundtrip instrumentation: elapsed time + counts for
    /// `connect`/`select`/`fetchEnvelopes`/`fetchFlags`/`fetchBody`, the
    /// operations that dominate a sync pass's network cost. Same
    /// subsystem/category-per-type convention as `MailboxSyncer.logger`
    /// (`docs/architecture.md`'s existing OSLog precedent) — `.public` on
    /// every interpolated value below is safe *only* because each one is a
    /// count, a UID/byte number, an elapsed duration, or a mailbox path
    /// (already logged `.public` elsewhere, e.g. `MailboxSyncer.logger`'s
    /// call sites) — never a credential, message body, or subject.
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "IMAPSession")

    /// Milliseconds elapsed since `startedAt`, rounded to the nearest whole
    /// millisecond — every instrumentation call site above measures a
    /// round trip that's expected to take anywhere from single-digit
    /// milliseconds (a cheap `STATUS`) to several seconds (a large `FETCH`),
    /// so sub-millisecond precision isn't useful and a plain `Int` keeps
    /// the log line readable.
    private static func elapsedMs(since startedAt: Date) -> Int {
        Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
    }

    public init(config: IMAPConfig) {
        let session = MCOIMAPSession()
        session.hostname = config.host
        session.port = UInt32(config.port)
        session.connectionType = Self.connectionType(for: config.security)
        session.isCheckCertificateEnabled = !config.allowsInsecureTLS
        // MailCore2 defaults to the legacy CFStream "VoIP socket" mode
        // (mVoIPEnabled = true in MCIMAPSession.cpp), a pre-PushKit background
        // hack. On physical iOS 26 devices CFNetwork traps (EXC_BREAKPOINT in
        // spd_checkin_socket via SocketStream::checkInVoIPSocket) the moment
        // such a socket connects; the simulator never exercises this path.
        session.isVoIPEnabled = false
        self.session = session
    }

    /// MailCore2 finishes tearing down a session's internal
    /// `OperationQueue` asynchronously — `OperationQueue
    /// ::stoppedOnMainThread` is a `dispatch_async` back to the main
    /// queue, not something `disconnectOperation()`'s completion handler
    /// waits on. Every call site here connects a throwaway session and
    /// disconnects it in a fire-and-forget `Task` (e.g. `SyncCoordinator
    /// .withIMAPSession`'s `defer { Task { await session.disconnect() } }`),
    /// so this actor — and the `MCOIMAPSession` it owns — can be
    /// deallocated the instant that `Task` finishes, before MailCore2's
    /// own teardown callback lands. When that happens, MailCore2 touches
    /// freed memory from `queueStartRunning`/`stoppedOnMainThread` and
    /// crashes with SIGSEGV (seen in production TestFlight crash
    /// reports). Keeping a strong reference to `session` alive for a few
    /// seconds past this actor's own deinit gives that callback somewhere
    /// live to land instead of a freed C++ object.
    deinit {
        Self.lingerBox.linger(session)
    }

    private static let lingerBox = SessionLingerBox()

    // MARK: - Connection

    public func connect(auth: MailAuth) async throws {
        let startedAt = Date()
        Self.apply(auth, to: session)
        do {
            try await runVoid(session.checkAccountOperation())
        } catch {
            Self.logger.notice(
                "connect: failed elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
            )
            throw error
        }
        connected = true
        cachedCapabilities = try await fetchCapabilities()
        gmailExtensionsSupported = cachedCapabilities.contains(.gmailExtensions)
        let capabilityCount = cachedCapabilities.count
        Self.logger.notice(
            "connect: succeeded capabilities=\(capabilityCount, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
        )
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        try? await runVoid(session.disconnectOperation())
    }

    /// Bridges a `MCOIMAPOperation`-shaped (`(Error?) -> Void` completion)
    /// operation to `async`/`await`. An actor-isolated instance method
    /// (not `static`) on purpose: it's called with a live MailCore2
    /// operation object, and staying on the actor's isolation for the
    /// duration of the call means that non-`Sendable` object never needs to
    /// cross an isolation boundary — only the `Void`/`Error` result of
    /// `continuation.resume` does, once the operation's completion block
    /// fires on MailCore2's own thread.
    private func runVoid(_ operation: MCOIMAPOperation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.start { error in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func capabilities() async throws -> Set<IMAPCapability> {
        cachedCapabilities
    }

    private func fetchCapabilities() async throws -> Set<IMAPCapability> {
        try await withCheckedThrowingContinuation { continuation in
            session.capabilityOperation().start { error, capabilities in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                continuation.resume(returning: Self.capabilities(from: capabilities))
            }
        }
    }

    // MARK: - Mailboxes

    public func listMailboxes() async throws -> [MailboxInfo] {
        try await withCheckedThrowingContinuation { continuation in
            session.fetchAllFoldersOperation().start { error, folders in
                if let error {
                    continuation.resume(throwing: Self.mapError(error))
                    return
                }
                continuation.resume(returning: (folders ?? []).map(Self.mailboxInfo(from:)))
            }
        }
    }

    public func select(_ mailboxPath: String) async throws -> MailboxStatus {
        try await status(mailboxPath)
    }

    /// `CREATE` then a best-effort `SUBSCRIBE` — a server that rejects the
    /// `SUBSCRIBE` (already auto-subscribed, or simply doesn't require one)
    /// must not fail the whole operation, since the `CREATE` — the part
    /// that actually matters for `OpQueueProcessor`'s delete-op replay to
    /// find a destination mailbox on the next `listMailboxes()` — already
    /// succeeded.
    public func createMailbox(path: String) async throws {
        try await runVoid(session.createFolderOperation(folder: path))
        try? await runVoid(session.subscribeFolderOperation(folder: path))
    }

    public func status(_ mailboxPath: String) async throws -> MailboxStatus {
        // Same underlying MailCore2 request `select(_:)` calls — see that
        // method's doc comment — so this one log site covers both; the
        // message says "select/status" rather than picking one name.
        let startedAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            session.folderInfoOperation(folder: mailboxPath).start { error, info in
                if let error {
                    Self.logger.notice(
                        "select/status: \(mailboxPath, privacy: .public) failed elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
                    )
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                guard let info else {
                    continuation.resume(throwing: MailTransportError.malformedResponse(
                        underlyingDescription: "folderInfoOperation returned no info and no error"
                    ))
                    return
                }
                let status = Self.mailboxStatus(from: info)
                Self.logger.notice(
                    "select/status: \(mailboxPath, privacy: .public) messageCount=\(status.messageCount, privacy: .public) uidNext=\(status.uidNext, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
                )
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Envelopes

    public func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        // MailCore2 has no notion of a per-request batch size (one FETCH
        // command per operation); `batchSize` chunks the UID range into
        // multiple sequential operations so a single huge mailbox can't
        // stall on one oversized command or force everything into memory
        // as a single server round trip.
        let startedAt = Date()
        let chunks = Self.chunk(uids, size: max(1, batchSize))
        var result: [FetchedEnvelope] = []
        for chunk in chunks {
            let batch = try await fetchEnvelopesBatch(mailboxPath: mailboxPath, uids: chunk)
            result.append(contentsOf: batch)
        }
        Self.logger.notice(
            "fetchEnvelopes: \(mailboxPath, privacy: .public) uids=\(uids.lowerBound, privacy: .public)-\(uids.upperBound.map(String.init) ?? "*", privacy: .public) chunks=\(chunks.count, privacy: .public) fetched=\(result.count, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
        )
        return result
    }

    private func fetchEnvelopesBatch(mailboxPath: String, uids: UIDRange) async throws -> [FetchedEnvelope] {
        try await fetchEnvelopesBatch(mailboxPath: mailboxPath, indexSet: Self.indexSet(for: uids))
    }

    /// Task #194 follow-up (unknown-UID reconciliation): the `UIDSet`
    /// counterpart of `fetchEnvelopes(mailboxPath:uids: UIDRange:
    /// batchSize:)` — see `IMAPSessionProtocol.fetchEnvelopes(mailboxPath:
    /// uids: UIDSet)`'s doc comment. One underlying `FETCH` per call, no
    /// internal chunking (same contract as `fetchFlags(mailboxPath:uids:
    /// UIDSet)`); the caller (`MailboxSyncer
    /// .applyFlagsDiffAndReconcileUnknown`) is expected to have already
    /// chunked a larger unknown-UID set into caller-sized pieces.
    public func fetchEnvelopes(mailboxPath: String, uids: UIDSet) async throws -> [FetchedEnvelope] {
        guard !uids.uids.isEmpty else { return [] }
        let startedAt = Date()
        let result = try await fetchEnvelopesBatch(mailboxPath: mailboxPath, indexSet: Self.indexSet(for: uids))
        Self.logger.notice(
            "fetchEnvelopes: \(mailboxPath, privacy: .public) uids=\(uids.uids.count, privacy: .public) (set) fetched=\(result.count, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
        )
        return result
    }

    /// Shared by both `fetchEnvelopesBatch(mailboxPath:uids: UIDRange)`
    /// (dense-range chunks, the initial-sync/new-mail paths) and
    /// `fetchEnvelopes(mailboxPath:uids: UIDSet)` (a possibly sparse,
    /// caller-chunked set) — `MCOIndexSet` already represents both shapes
    /// uniformly (see `Self.indexSet(for:)`'s two overloads), so the actual
    /// `fetchMessagesByUid` call only needs to be written once.
    private func fetchEnvelopesBatch(mailboxPath: String, indexSet: MCOIndexSet) async throws -> [FetchedEnvelope] {
        var kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .structure, .internalDate, .size]
        if gmailExtensionsSupported {
            kind.formUnion([.gmailThreadID, .gmailMessageID])
        }
        // Captured once for the whole batch (not per-message inside the
        // completion block): `EnvelopeDateSentinel`'s reference moment for
        // Task #193's sentinel-date detection — see
        // `MailCoreIMAPSession+Mapping.envelope(from:fetchedAt:)`'s doc
        // comment.
        let fetchedAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            session.fetchMessagesByUid(folder: mailboxPath, kind: kind, uids: indexSet).start { error, messages, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: (messages ?? []).map { Self.envelope(from: $0, fetchedAt: fetchedAt) })
            }
        }
    }

    /// Sequence-number counterpart of `fetchEnvelopes(mailboxPath:uids:
    /// batchSize:)` — see `IMAPSessionProtocol.fetchRecentEnvelopes`'s doc
    /// comment for why `AccountSyncer`/`MailboxSyncer` use this one for the
    /// initial-sync window instead.
    public func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope] {
        guard count > 0 else { return [] }
        // This used to re-derive `status` from its own fresh
        // `STATUS`-equivalent round trip (`status(mailboxPath)`) rather than
        // trusting the caller's — both `AccountSyncer.performInitialSync`
        // and `MailboxSyncer.performWindowedResync` call this immediately
        // after their own `select(_:)`/`status(_:)`, so that extra
        // `folderInfoOperation` was a pure duplicate. See this method's doc
        // comment on `IMAPSessionProtocol` for the full reasoning.
        guard status.messageCount > 0 else { return [] }
        let upper = UInt32(status.messageCount)
        let lower = upper > UInt32(count) ? upper - UInt32(count) + 1 : 1
        // Reuses `UIDRange`'s chunking/`MCOIndexSet` conversion for what are
        // semantically *sequence* numbers here, not UIDs — `MCOIndexSet`
        // itself has no notion of which one a given index set represents;
        // that's purely which `fetchMessages...Operation` variant it's
        // handed to (`fetchMessagesByNumber` below vs. `fetchMessagesByUid`
        // above).
        let sequenceRange = UIDRange(lowerBound: lower, upperBound: upper)

        var result: [FetchedEnvelope] = []
        for chunk in Self.chunk(sequenceRange, size: max(1, batchSize)) {
            let batch = try await fetchEnvelopesByNumberBatch(mailboxPath: mailboxPath, numbers: chunk)
            result.append(contentsOf: batch)
        }
        return result
    }

    private func fetchEnvelopesByNumberBatch(mailboxPath: String, numbers: UIDRange) async throws -> [FetchedEnvelope] {
        var kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .structure, .internalDate, .size]
        if gmailExtensionsSupported {
            kind.formUnion([.gmailThreadID, .gmailMessageID])
        }
        let indexSet = Self.indexSet(for: numbers)
        let fetchedAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            session.fetchMessagesByNumber(folder: mailboxPath, kind: kind, numbers: indexSet).start { error, messages, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: (messages ?? []).map { Self.envelope(from: $0, fetchedAt: fetchedAt) })
            }
        }
    }

    /// Task #194: see `IMAPSessionProtocol.fetchFlags(mailboxPath:uids:)`'s
    /// doc comment — a single `UID FETCH ... (FLAGS)` command for `uids`
    /// (the caller, `MailboxSyncer`, is expected to have already chunked a
    /// larger range into caller-sized pieces; unlike `fetchEnvelopes`/
    /// `fetchRecentEnvelopes` above, this method issues exactly one
    /// underlying operation per call rather than looping internally, so the
    /// caller can check `Task.checkCancellation()`/report progress between
    /// calls). Requests only `.flags` (not `.headers`/`.structure`/
    /// `.internalDate`/`.size`) — the whole point of this method over
    /// `fetchEnvelopes` is a much smaller `FETCH` response per message.
    public func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        try await fetchFlagsBatch(mailboxPath: mailboxPath, indexSet: Self.indexSet(for: uids))
    }

    /// `IMAPSessionProtocol.fetchFlags(mailboxPath:uids:)`'s `UIDSet`
    /// overload — see that method's doc comment. `Self.indexSet(for:
    /// UIDSet)` already exists for `store`/`move`'s discrete-UID targets;
    /// `MCOIndexSet` coalesces whatever contiguous runs `uids` happens to
    /// contain into IMAP range syntax on the wire regardless of which
    /// overload built it, so this is exactly as cheap as the `UIDRange`
    /// overload for a dense chunk.
    public func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags] {
        guard !uids.uids.isEmpty else { return [:] }
        return try await fetchFlagsBatch(mailboxPath: mailboxPath, indexSet: Self.indexSet(for: uids))
    }

    private func fetchFlagsBatch(mailboxPath: String, indexSet: MCOIndexSet) async throws -> [UInt32: MessageFlags] {
        let startedAt = Date()
        let requested = indexSet.count()
        return try await withCheckedThrowingContinuation { continuation in
            session.fetchMessagesByUid(folder: mailboxPath, kind: .flags, uids: indexSet).start { error, messages, _ in
                if let error {
                    Self.logger.notice(
                        "fetchFlags: \(mailboxPath, privacy: .public) requested=\(requested, privacy: .public) failed elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
                    )
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                var result: [UInt32: MessageFlags] = [:]
                for message in messages ?? [] {
                    result[message.uid] = Self.messageFlags(from: message.flags)
                }
                Self.logger.notice(
                    "fetchFlags: \(mailboxPath, privacy: .public) requested=\(requested, privacy: .public) fetched=\(result.count, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// `CONDSTORE`-based flag-change fetch (RFC 7162 §3.1, `syncMessages`
    /// bridging `session.syncMessagesByUIDOperation`): messages whose
    /// metadata changed since `modSeq`, covering the whole mailbox
    /// (`UIDRange.all`) since CONDSTORE reports changes irrespective of
    /// UID — the caller (`MailboxSyncer`) is expected to have already
    /// checked `capabilities()` contains `.condstore` before calling this;
    /// a non-CONDSTORE server rejects the underlying `FETCH ... (CHANGEDSINCE
    /// ...)` with a tagged `BAD`/`NO`, surfaced here as `.serverError`.
    ///
    /// Vanished (expunged) UIDs: MailCore2's underlying `syncMessages`
    /// operation also surfaces these (its completion block's third
    /// argument, previously discarded here) whenever the server additionally
    /// supports `QRESYNC` — confirmed against the pinned mailcore2 revision
    /// (`MCIMAPSession.cpp`'s `fetchMessages`: `IMAPSyncResult
    /// .vanishedMessages()` is only ever non-`nil` when `mQResyncEnabled &&
    /// modseq != 0`, i.e. the server both advertised `QRESYNC` and this call
    /// passed a real `modSeq`). Most servers don't support `QRESYNC` — Gmail
    /// notably advertises `CONDSTORE` but never `QRESYNC` — so
    /// `ChangedSinceResult.vanishedUIDs` is `nil` there, and
    /// `MailboxSyncer`'s CONDSTORE path falls back to `searchExistingUIDs`
    /// to detect deletions instead (Task #79).
    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        guard cachedCapabilities.contains(.condstore) else {
            throw MailTransportError.serverError(underlyingDescription: "Server does not support CONDSTORE")
        }
        var kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .structure, .internalDate, .size]
        if gmailExtensionsSupported {
            kind.formUnion([.gmailThreadID, .gmailMessageID])
        }
        let indexSet = Self.indexSet(for: .all)
        let fetchedAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            session.syncMessages(folder: mailboxPath, kind: kind, uids: indexSet, modSeq: modSeq).start { error, messages, vanished in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: ChangedSinceResult(
                    envelopes: (messages ?? []).map { Self.envelope(from: $0, fetchedAt: fetchedAt) },
                    vanishedUIDs: Self.vanishedUIDs(from: vanished)
                ))
            }
        }
    }

    /// `IMAPSessionProtocol.fetchFlags(mailboxPath:changedSince:)` — same
    /// `syncMessages` operation as `fetchEnvelopes(mailboxPath:changedSince:)`
    /// just above, requesting only `.flags` instead of the full `ENVELOPE`/
    /// `BODYSTRUCTURE`/size `kind` set. Vanished-UID reporting is identical
    /// (same operation, same `QRESYNC` precondition — see that method's doc
    /// comment).
    public func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult {
        guard cachedCapabilities.contains(.condstore) else {
            throw MailTransportError.serverError(underlyingDescription: "Server does not support CONDSTORE")
        }
        let indexSet = Self.indexSet(for: .all)
        return try await withCheckedThrowingContinuation { continuation in
            session.syncMessages(folder: mailboxPath, kind: .flags, uids: indexSet, modSeq: modSeq).start { error, messages, vanished in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                var flagsByUID: [UInt32: MessageFlags] = [:]
                for message in messages ?? [] {
                    flagsByUID[message.uid] = Self.messageFlags(from: message.flags)
                }
                continuation.resume(returning: ChangedSinceFlagsResult(
                    flagsByUID: flagsByUID,
                    vanishedUIDs: Self.vanishedUIDs(from: vanished)
                ))
            }
        }
    }

    /// `UID SEARCH UID <uids>` (`MCOIMAPSearchExpression.searchUIDs`) — the
    /// subset of `uids` the server currently still has, with no envelope
    /// data fetched at all. Task #79's CONDSTORE-path fallback for
    /// detecting server-side `EXPUNGE`s on servers (Gmail among them) that
    /// don't support `QRESYNC`'s `VANISHED` reporting; see
    /// `IMAPSessionProtocol.searchExistingUIDs`'s doc comment.
    public func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        let expression = MCOIMAPSearchExpression.searchUIDs(Self.indexSet(for: uids))
        return try await withCheckedThrowingContinuation { continuation in
            session.searchExpressionOperation(folder: mailboxPath, expression: expression).start { error, result in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                do {
                    continuation.resume(returning: try Self.uidSet(from: result))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `SEARCH (OR SUBJECT <query> OR FROM <query> BODY <query>)` —
    /// `IMAPSessionProtocol.searchMessages`'s doc comment. `MCOIMAPSearchExpression`
    /// has no native 3-way `OR`, so this nests two 2-way `searchOr`s the
    /// same way `MCOIMAPSearchExpression`'s own header doc example chains
    /// them. `searchBody` (not `searchContent`) deliberately excludes
    /// headers — `searchSubject`/`searchFrom` already cover those, and
    /// including headers in the body term too would just make `SUBJECT`/
    /// `FROM` redundant without adding coverage.
    public func searchMessages(mailboxPath: String, query: String) async throws -> Set<UInt32> {
        let subjectOrFrom = MCOIMAPSearchExpression.searchOr(
            MCOIMAPSearchExpression.searchSubject(query),
            other: MCOIMAPSearchExpression.searchFrom(query)
        )
        let expression = MCOIMAPSearchExpression.searchOr(
            subjectOrFrom,
            other: MCOIMAPSearchExpression.searchBody(query)
        )
        return try await withCheckedThrowingContinuation { continuation in
            session.searchExpressionOperation(folder: mailboxPath, expression: expression).start { error, result in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                do {
                    continuation.resume(returning: try Self.uidSet(from: result))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Body (M2)

    /// Downloads the message's full RFC 822 content and parses it with
    /// MailCore2's `MCOMessageParser` in one operation
    /// (`fetchParsedMessageOperation`) — the "RFC822 全体 fetch → parse"
    /// approach the M2 plan explicitly allows in place of driving
    /// `BODYSTRUCTURE` + per-part fetches by hand: `MCOMessageParser`
    /// already handles charset conversion (including ISO-2022-JP and
    /// friends), `Content-Transfer-Encoding`, and `multipart/alternative`
    /// part selection, so re-deriving any of that here would just be a
    /// worse copy of what the library already does well.
    public func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        let startedAt = Date()
        let content: MessageBodyContent = try await withCheckedThrowingContinuation { continuation in
            session.fetchParsedMessageOperation(folder: mailboxPath, uid: uid).start { error, parser in
                if let error {
                    Self.logger.notice(
                        "fetchBody: \(mailboxPath, privacy: .public) uid=\(uid, privacy: .public) failed elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
                    )
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                guard let parser else {
                    continuation.resume(throwing: MailTransportError.malformedResponse(
                        underlyingDescription: "fetchParsedMessageOperation returned no parser and no error"
                    ))
                    return
                }
                continuation.resume(returning: Self.bodyContent(from: parser))
            }
        }
        // Byte counts, never the content itself: `plainText`/`html`
        // character counts and the sum of `parts`' own reported `size` —
        // enough to see "this fetch was unusually large/slow" from a
        // Console pull without exposing message content.
        let approxBytes = (content.plainText?.utf8.count ?? 0) + (content.html?.utf8.count ?? 0) + content.parts.reduce(0) { $0 + $1.size }
        Self.logger.notice(
            "fetchBody: \(mailboxPath, privacy: .public) uid=\(uid, privacy: .public) parts=\(content.parts.count, privacy: .public) approxBytes=\(approxBytes, privacy: .public) elapsed=\(Self.elapsedMs(since: startedAt), privacy: .public)ms"
        )

        // RFC 2231 fallback (docs/roadmap.md): the pinned mailcore2
        // revision's `MCOMessageParser` only understands RFC 2047
        // encoded-word filenames, never RFC 2231's `filename*=`/
        // `filename*0*=` extended-parameter form, so an attachment sent
        // that way comes back with `filename == nil`. Only pay for the
        // extra "fetch the whole raw message again" round trip when that
        // gap is actually observed on *this* message — the overwhelmingly
        // common case (no attachments, or attachments mailcore2 already
        // named) never takes it.
        guard content.parts.contains(where: { $0.isAttachment && $0.filename == nil }) else {
            return content
        }
        guard let rawMessage = try? await fetchMessageBody(mailboxPath: mailboxPath, uid: uid, partId: nil) else {
            // Best-effort: if the extra fetch itself fails, the message
            // still has a body — just without a recovered filename for
            // whichever attachment(s) triggered the fallback. Don't turn a
            // filename-decoding gap into a body-fetch failure.
            return content
        }
        return Self.applyRFC2231FilenameFallback(to: content, rawMessage: rawMessage)
    }

    // MARK: - Attachment data (M8)

    /// Downloads one attachment/inline part's raw bytes, or the whole
    /// message's raw RFC 822 bytes when `partId` is `nil`.
    ///
    /// `partId` here is always an `AttachmentRecord.partId` — the
    /// `MCOMessageParser` `uniqueID` `MailCoreIMAPSession+Mapping.parts(from:)`
    /// stamped onto it when the message's body was first fetched (M2's
    /// `fetchBody`, which parses via `MCOMessageParser` rather than driving
    /// `BODYSTRUCTURE` + per-part IMAP fetches by hand — see that method's
    /// doc comment). It is *not* a `BODY[<partId>]` IMAP part specifier, so
    /// `session.fetchMessageAttachmentOperation(folder:uid:partId:...)`
    /// (which does expect a real IMAP part specifier) isn't usable here.
    /// Instead this re-fetches+re-parses the whole message exactly like
    /// `fetchBody` does (`fetchParsedMessageOperation`), then resolves
    /// `partId` back to a part on the fresh parser via `partForUniqueID` —
    /// safe because mailcore2's uniqueID assignment is a deterministic,
    /// structure-only walk of the MIME tree (see `partData(from:uniqueID:)`'s
    /// doc comment), so the same bytes reparsed always yield the same
    /// uniqueIDs. This is the "全体 fetch 済みなら MCOMessageParser から part
    /// データ取り出し" approach the M8 plan explicitly allows over a real
    /// per-part IMAP round trip — simpler, and it reuses `MCOMessageParser`'s
    /// own `Content-Transfer-Encoding` decoding rather than re-deriving it.
    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        guard let partId else {
            return try await withCheckedThrowingContinuation { continuation in
                session.fetchMessageOperation(folder: mailboxPath, uid: uid).start { error, data in
                    if let error {
                        continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                        return
                    }
                    continuation.resume(returning: data ?? Data())
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.fetchParsedMessageOperation(folder: mailboxPath, uid: uid).start { error, parser in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                guard let parser else {
                    continuation.resume(throwing: MailTransportError.malformedResponse(
                        underlyingDescription: "fetchParsedMessageOperation returned no parser and no error"
                    ))
                    return
                }
                guard let data = Self.partData(from: parser, uniqueID: partId) else {
                    continuation.resume(throwing: MailTransportError.malformedResponse(
                        underlyingDescription: "No MIME part with uniqueID \(partId) found in message uid \(uid)"
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// `APPEND`s `messageData` to `mailboxPath` (M5: `OpQueueProcessor`'s
    /// `.send` op replay uses this to leave a copy in the account's Sent
    /// mailbox after a successful SMTP send). Returns the new message's UID
    /// when the server supports `UIDPLUS` (reports a non-zero `createdUID`),
    /// `nil` otherwise — a `MailboxSyncer` differential sync of Sent will
    /// still pick the message up either way.
    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        let mcoFlags = Self.mcoMessageFlag(from: flags)
        return try await withCheckedThrowingContinuation { continuation in
            session.appendMessageOperation(folder: mailboxPath, messageData: messageData, flags: mcoFlags).start { error, createdUID in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: createdUID == 0 ? nil : createdUID)
            }
        }
    }

    // MARK: - Flags / move / expunge (M3)

    /// `STORE`s `change.flags` onto `change.uids` (RFC 3501 §6.4.6).
    /// `change.uidValidity` is not consulted here — staleness checking
    /// against a mailbox's *current* `uidValidity` is `OpQueueProcessor`'s
    /// job (it has the local `MailboxRecord` to compare against), not
    /// something this transport-only method can evaluate on its own.
    public func store(mailboxPath: String, change: FlagChange) async throws {
        guard !change.uids.uids.isEmpty else { return }
        let indexSet = Self.indexSet(for: change.uids)
        let kind = Self.storeFlagsRequestKind(for: change.op)
        let flags = Self.mcoMessageFlag(from: change.flags)
        try await runVoid(session.storeFlagsOperation(folder: mailboxPath, uids: indexSet, kind: kind, flags: flags))
    }

    /// Moves `uids` from `mailboxPath` to `destinationPath`: `MOVE`
    /// (RFC 6851) when the server advertised the `MOVE` capability at
    /// connect time, else the classic `COPY` + `STORE +FLAGS \Deleted` +
    /// `EXPUNGE` sequence every IMAP server supports.
    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        guard !uids.uids.isEmpty else { return }
        let indexSet = Self.indexSet(for: uids)

        if cachedCapabilities.contains(.move) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.moveMessagesOperation(folder: mailboxPath, uids: indexSet, destFolder: destinationPath).start { error, _ in
                    if let error {
                        continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    } else {
                        continuation.resume()
                    }
                }
            }
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.copyMessagesOperation(folder: mailboxPath, uids: indexSet, destFolder: destinationPath).start { error, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                } else {
                    continuation.resume()
                }
            }
        }
        try await store(
            mailboxPath: mailboxPath,
            change: FlagChange(uids: uids, op: .add, flags: .deleted, uidValidity: 0)
        )
        try await expunge(mailboxPath: mailboxPath)
    }

    public func expunge(mailboxPath: String) async throws {
        try await runVoid(session.expungeOperation(folder: mailboxPath))
    }

    /// Task #87 (1): a plain `COPY`, no `STORE +FLAGS \Deleted`/`EXPUNGE`
    /// afterward — see `IMAPSessionProtocol.copy(mailboxPath:uids:to:)`'s
    /// doc comment for why this must leave `mailboxPath` untouched, unlike
    /// `move(mailboxPath:uids:to:)`'s non-`MOVE`-capability fallback above
    /// (which reuses the same `copyMessagesOperation` call but always
    /// follows it with the delete+expunge that turns it into a move).
    public func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        guard !uids.uids.isEmpty else { return }
        let indexSet = Self.indexSet(for: uids)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.copyMessagesOperation(folder: mailboxPath, uids: indexSet, destFolder: destinationPath).start { error, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - IDLE (M3)

    /// How long a single `IDLE` round is allowed to run before this session
    /// proactively sends `DONE` and reissues it, per RFC 2177's
    /// recommendation to re-issue within 29 minutes (many servers drop the
    /// connection at the 30-minute `IMAPIDLETIMEOUT` mark).
    static let idleReissueInterval: Duration = .seconds(29 * 60)

    /// Runs `IDLE` on `mailboxPath` continuously: each round is one
    /// `MCOIMAPIdleOperation`, reissued immediately after it completes
    /// (whether that's because the server pushed an update, the
    /// `idleReissueInterval` proactive-reissue timer fired, or the
    /// stream's consuming `Task` was cancelled) until that `Task`
    /// cancellation is observed, at which point the stream finishes
    /// cleanly. A genuine connection/protocol error finishes the stream by
    /// throwing instead.
    ///
    /// MailCore2's completion signature (`(Error?) -> Void`) does not
    /// distinguish "the server pushed new data" from "we ourselves called
    /// `interruptIdle()`" — both complete with a `nil` error at the
    /// libetpan level (`IMAPSession::idle`'s timeout/interrupt branch still
    /// sets `ErrorNone`). This method tracks whether *it* requested the
    /// interrupt (proactive reissue timer, or external cancellation) via
    /// `InterruptFlag`, and only yields `.interrupted` for those; any
    /// completion the operation reaches on its own is reported as
    /// `.newData` — safe even if what completed it was actually libetpan's
    /// own internal socket-level timeout handling (a spurious `.newData`
    /// just costs `MailboxSyncer` one incremental sync pass that finds
    /// nothing new).
    public nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runIdleLoop(mailboxPath: mailboxPath, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runIdleLoop(
        mailboxPath: String,
        continuation: AsyncThrowingStream<IdleEvent, Error>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                let event = try await performOneIdleRound(mailboxPath: mailboxPath)
                guard !Task.isCancelled else { break }
                continuation.yield(event)
            } catch {
                continuation.finish(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                return
            }
        }
        continuation.finish()
    }

    private func performOneIdleRound(mailboxPath: String) async throws -> IdleEvent {
        let operationBox = IdleOperationBox(session.idleOperation(folder: mailboxPath, lastKnownUID: 0))
        let interruptFlag = InterruptFlag()

        let timeoutTask = Task {
            try? await Task.sleep(for: Self.idleReissueInterval)
            guard !Task.isCancelled else { return }
            interruptFlag.set()
            operationBox.operation.interruptIdle()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operationBox.operation.start { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            interruptFlag.set()
            operationBox.operation.interruptIdle()
        }

        return interruptFlag.get() ? .interrupted : .newData
    }

    /// Wraps a non-`Sendable` `MCOIMAPIdleOperation` so it can be captured
    /// by the `@Sendable` closures `Task { ... }`/`withTaskCancellationHandler`
    /// require: MailCore2's own internal locking (see `IMAPSession
    /// ::interruptIdle()`'s `LOCK()`/`UNLOCK()`) already makes calling
    /// `interruptIdle()`/`start(completionBlock:)` from different threads
    /// safe in practice, which Swift's checker just can't see through a
    /// non-`Sendable` Objective-C-bridged class.
    private final class IdleOperationBox: @unchecked Sendable {
        let operation: MCOIMAPIdleOperation
        init(_ operation: MCOIMAPIdleOperation) { self.operation = operation }
    }

    /// Thread-safe one-shot flag: `MCOIMAPOperation` completion blocks fire
    /// on MailCore2's own internal thread, and `withTaskCancellationHandler`'s
    /// `onCancel` closure can run concurrently with that from an arbitrary
    /// thread too, so a plain `var` isn't safe here.
    private final class InterruptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flagged = false

        func set() {
            lock.lock()
            flagged = true
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return flagged
        }
    }
}

/// Thread-safe holder for `MCOIMAPSession`s kept alive briefly after their
/// owning `MailCoreIMAPSession` actor deinits — see that `deinit`'s doc
/// comment for why.
private final class SessionLingerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: MCOIMAPSession] = [:]

    func linger(_ session: MCOIMAPSession) {
        let key = ObjectIdentifier(session)
        lock.lock()
        sessions[key] = session
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.release(key)
        }
    }

    private func release(_ key: ObjectIdentifier) {
        lock.lock()
        sessions.removeValue(forKey: key)
        lock.unlock()
    }
}
