import Foundation
import MailCore
import MailTransport
import OtegamiCore

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
    private let session: MCOIMAPSession
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

    public init(config: IMAPConfig) {
        let session = MCOIMAPSession()
        session.hostname = config.host
        session.port = UInt32(config.port)
        session.connectionType = Self.connectionType(for: config.security)
        session.isCheckCertificateEnabled = !config.allowsInsecureTLS
        self.session = session
    }

    // MARK: - Connection

    public func connect(auth: MailAuth) async throws {
        Self.apply(auth, to: session)
        try await runVoid(session.checkAccountOperation())
        connected = true
        cachedCapabilities = try await fetchCapabilities()
        gmailExtensionsSupported = cachedCapabilities.contains(.gmailExtensions)
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

    public func status(_ mailboxPath: String) async throws -> MailboxStatus {
        try await withCheckedThrowingContinuation { continuation in
            session.folderInfoOperation(folder: mailboxPath).start { error, info in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                guard let info else {
                    continuation.resume(throwing: MailTransportError.malformedResponse(
                        underlyingDescription: "folderInfoOperation returned no info and no error"
                    ))
                    return
                }
                continuation.resume(returning: Self.mailboxStatus(from: info))
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
        var result: [FetchedEnvelope] = []
        for chunk in Self.chunk(uids, size: max(1, batchSize)) {
            let batch = try await fetchEnvelopesBatch(mailboxPath: mailboxPath, uids: chunk)
            result.append(contentsOf: batch)
        }
        return result
    }

    private func fetchEnvelopesBatch(mailboxPath: String, uids: UIDRange) async throws -> [FetchedEnvelope] {
        var kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .structure, .internalDate, .size]
        if gmailExtensionsSupported {
            kind.formUnion([.gmailThreadID, .gmailMessageID])
        }
        let indexSet = Self.indexSet(for: uids)
        return try await withCheckedThrowingContinuation { continuation in
            session.fetchMessagesByUid(folder: mailboxPath, kind: kind, uids: indexSet).start { error, messages, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: (messages ?? []).map(Self.envelope(from:)))
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
    /// Vanished (expunged) UIDs are not reported even when the server also
    /// supports QRESYNC — `MailboxSyncer`'s CONDSTORE path only tracks new
    /// mail and flag changes; deletion detection is the non-CONDSTORE
    /// full-window-refetch path's job (see its doc comment).
    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope] {
        guard cachedCapabilities.contains(.condstore) else {
            throw MailTransportError.serverError(underlyingDescription: "Server does not support CONDSTORE")
        }
        var kind: MCOIMAPMessagesRequestKind = [.headers, .flags, .structure, .internalDate, .size]
        if gmailExtensionsSupported {
            kind.formUnion([.gmailThreadID, .gmailMessageID])
        }
        let indexSet = Self.indexSet(for: .all)
        return try await withCheckedThrowingContinuation { continuation in
            session.syncMessages(folder: mailboxPath, kind: kind, uids: indexSet, modSeq: modSeq).start { error, messages, _ in
                if let error {
                    continuation.resume(throwing: Self.mapError(error, mailboxPath: mailboxPath))
                    return
                }
                continuation.resume(returning: (messages ?? []).map(Self.envelope(from:)))
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
        try await withCheckedThrowingContinuation { continuation in
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
                continuation.resume(returning: Self.bodyContent(from: parser))
            }
        }
    }

    // MARK: - Not yet implemented (M8/M5)

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        throw MailTransportError.notImplemented("fetchMessageBody — raw per-part attachment fetch lands in M8")
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
