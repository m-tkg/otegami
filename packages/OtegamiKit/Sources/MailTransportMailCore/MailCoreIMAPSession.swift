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
        gmailExtensionsSupported = try await capabilities().contains(.gmailExtensions)
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

    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> [FetchedEnvelope] {
        throw MailTransportError.notImplemented("fetchEnvelopes(changedSince:) — CONDSTORE support lands in M3")
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

    // MARK: - Not yet implemented (M3+)

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        throw MailTransportError.notImplemented("fetchMessageBody — raw per-part attachment fetch lands in M8")
    }

    public func store(mailboxPath: String, change: FlagChange) async throws {
        throw MailTransportError.notImplemented("store — flag sync lands in M3")
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        throw MailTransportError.notImplemented("append — Sent APPEND lands in M5")
    }

    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        throw MailTransportError.notImplemented("move — lands in M5")
    }

    public func expunge(mailboxPath: String) async throws {
        throw MailTransportError.notImplemented("expunge — lands in M3")
    }

    public nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MailTransportError.notImplemented("idle — IDLE support lands in M3"))
        }
    }
}
