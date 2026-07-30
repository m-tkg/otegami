import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL

/// A deliberately tiny IMAP client covering exactly what `IdleWatcher`
/// needs: `LOGIN`, `SELECT`, `STATUS (UIDNEXT)`, `IDLE`/`DONE`, `LOGOUT`.
///
/// **Why hand-rolled instead of swift-nio-imap** (plan §7 explicitly
/// allows this fallback, with a reasoning requirement): swift-nio-imap is
/// a low-level, actively-evolving parser/encoder for the *entire* IMAP
/// grammar (literals, MIME BODYSTRUCTURE, SEARCH query trees, ...), tuned
/// for full mail clients. Pulling it in for a component that only ever
/// needs to notice "did EXISTS/UIDNEXT advance" would mean carrying a large
///, low-level API surface (and its own Swift 6 concurrency posture, which
/// hadn't been re-verified against this toolchain) for a handful of
/// request/response shapes that are trivial line-oriented text in
/// practice. None of the commands this client issues, nor the responses it
/// parses, ever involve IMAP literals (`{123}`-prefixed byte-counted
/// strings) — mailbox names and status data-items are always sent/received
/// as plain atoms/quoted-strings — so a `LineBasedFrameDecoder` splitting
/// on CRLF is sufficient and the full literal-aware parser swift-nio-imap
/// provides isn't needed here. If a future watch needs literal-bearing
/// responses (e.g. FETCH), that's the point to revisit this decision.
final class MinimalIMAPClient: @unchecked Sendable {
    enum IMAPClientError: Error, CustomStringConvertible, Equatable {
        case notConnected
        case connectionClosed
        case timedOut
        case commandFailed(tag: String, response: String)
        case unexpectedResponse(String)
        /// CLAUDE-SECURITY F3: a value destined for an IMAP command line
        /// (username, password, mailbox) contained a CR, LF, NUL, or other
        /// control character — thrown instead of escaping it, since
        /// `quoted-string` per RFC 3501 §9 cannot carry CR/LF at all.
        case invalidControlCharacters(field: String)
        /// CLAUDE-SECURITY F4/F8: a single command's untagged-line
        /// response (count or total bytes) exceeded its bound, or the
        /// underlying line buffer overflowed — the connection is
        /// considered poisoned and torn down rather than let a malicious
        /// or misbehaving peer grow the relay's memory without limit.
        case responseTooLarge

        var description: String {
            switch self {
            case .notConnected: "IMAP client is not connected"
            case .connectionClosed: "IMAP connection closed unexpectedly"
            case .timedOut: "IMAP command timed out"
            case .commandFailed(let tag, let response): "IMAP command \(tag) failed: \(response)"
            case .unexpectedResponse(let line): "unexpected IMAP response: \(line)"
            case .invalidControlCharacters(let field): "\(field) contains a CR, LF, NUL, or other control character"
            case .responseTooLarge: "IMAP response exceeded the relay's size/line-count limit"
            }
        }
    }

    struct SelectResult {
        var exists: Int
        var uidNext: Int?
    }

    private let eventLoopGroup: any EventLoopGroup
    private var channel: (any Channel)?
    private let lineBuffer = LineBuffer()
    /// Persistently pumps decoded lines from the NIO channel into
    /// `lineBuffer`, for the whole lifetime of the connection. Deliberately
    /// never cancelled by a per-command timeout — see `LineBuffer`'s doc
    /// comment for why racing this pump directly against a timeout (the
    /// previous design) silently killed the connection on every ordinary
    /// IDLE timeout.
    private var pumpTask: Task<Void, Never>?
    private var tagCounter = 0

    /// CLAUDE-SECURITY F8: max bytes for a single decoded line (frame
    /// decoder) — see `connect`'s `ByteToMessageHandler` setup.
    private static let maxLineLength = 8192
    /// CLAUDE-SECURITY F4: max untagged (`*`) lines collected for one
    /// command before `readUntilTagged` gives up on the response as
    /// oversized.
    private static let maxUntaggedLinesPerCommand = 500
    /// CLAUDE-SECURITY F4: max total bytes across those untagged lines.
    private static let maxUntaggedBytesPerCommand = 262_144

    init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Connection

    /// - Parameter networkPolicy: CLAUDE-SECURITY F2 — resolved and
    ///   re-validated on *every* call (every reconnect, not just the
    ///   first), and the connection is dialed to that exact resolved
    ///   address rather than letting NIO re-resolve `host`/`port`
    ///   internally. See `RelayNetworkPolicy`'s doc comment for why this
    ///   is what closes the DNS-rebinding gap. Defaults to `.strict`
    ///   (rejects private/loopback/link-local targets) — callers that
    ///   intentionally dial loopback (tests) must pass `.permissiveForTesting`
    ///   explicitly.
    func connect(
        host: String,
        port: Int,
        useTLS: Bool,
        timeoutSeconds: Int64 = 15,
        networkPolicy: RelayNetworkPolicy = .strict
    ) async throws {
        let resolvedAddress = try networkPolicy.resolveAndValidate(host: host, port: port)

        var mutableContinuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { mutableContinuation = $0 }
        // `AsyncStream.Continuation` is itself `Sendable`; only the `var`
        // binding above isn't safe to capture in the `@Sendable`
        // `channelInitializer` closure below. Snapshotting it into a `let`
        // first (the stream's init closure already ran synchronously, so
        // it's guaranteed non-nil here) avoids that without needing any
        // unchecked-Sendable escape hatch.
        let continuation = mutableContinuation!

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(timeoutSeconds))
            .channelInitializer { channel in
                do {
                    var handlers: [any ChannelHandler] = []
                    if useTLS {
                        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                        handlers.append(sslHandler)
                    }
                    // CLAUDE-SECURITY F8: bound the frame decoder's
                    // cumulation buffer — without `maximumBufferSize`, a
                    // peer that never sends a line terminator can grow it
                    // without limit. `Self.maxLineLength` comfortably fits
                    // any real IMAP response line this client parses
                    // (tagged/untagged status replies); exceeding it
                    // throws `ByteToMessageDecoderError.PayloadTooLargeError`,
                    // which `LineCollectorHandler.errorCaught` already
                    // turns into closing the connection.
                    handlers.append(
                        ByteToMessageHandler(LineBasedFrameDecoder(), maximumBufferSize: Self.maxLineLength)
                    )
                    handlers.append(LineCollectorHandler(continuation: continuation))
                    return channel.pipeline.addHandlers(handlers)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        // Connect to the exact address `networkPolicy` already validated
        // above, not `.connect(host:port:)` (which would re-resolve `host`
        // internally, reopening the DNS-rebinding window between check and
        // use). `host` is still passed to `NIOSSLClientHandler` above for
        // SNI/certificate hostname verification — that must stay the
        // original hostname, not the resolved IP.
        let channel = try await bootstrap.connect(to: resolvedAddress).get()
        self.channel = channel

        // The pump is the *only* consumer of `stream`, ever, for the whole
        // connection lifetime, and is never cancelled by a timeout race
        // (only by `close()`, where the connection is being torn down
        // anyway). It just forwards each line into `lineBuffer`, which is
        // what `nextLine` actually waits on with a real, safely-cancellable
        // timeout.
        let lineBuffer = self.lineBuffer
        pumpTask = Task {
            var iterator = stream.makeAsyncIterator()
            while let line = await iterator.next() {
                await lineBuffer.push(line)
            }
            await lineBuffer.finish()
        }

        // Consume the server's untagged greeting ("* OK ... ready").
        _ = try await nextLine(timeoutSeconds: timeoutSeconds)
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
        pumpTask?.cancel()
        pumpTask = nil
    }

    // MARK: - Commands

    @discardableResult
    private func nextTag() -> String {
        tagCounter += 1
        return "A\(tagCounter)"
    }

    private func write(_ line: String) async throws {
        guard let channel else { throw IMAPClientError.notConnected }
        var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        try await channel.writeAndFlush(buffer).get()
    }

    /// Waits up to `timeoutSeconds` for the next already-decoded line.
    ///
    /// This delegates entirely to `lineBuffer`, which is fed by the single
    /// long-lived `pumpTask` — `nextLine` itself never touches the
    /// underlying `AsyncStream` or cancels anything that reads from the
    /// wire, so a losing timeout race here can never disrupt the
    /// connection (see `LineBuffer`'s doc comment for the bug this
    /// replaced).
    private func nextLine(timeoutSeconds: Int64) async throws -> String {
        guard channel != nil else { throw IMAPClientError.notConnected }
        return try await lineBuffer.next(timeoutSeconds: timeoutSeconds)
    }

    /// Reads lines until a tagged response for `tag` arrives, collecting
    /// every untagged (`*`) line seen along the way. Throws
    /// `.commandFailed` if the tagged response isn't `OK`.
    ///
    /// CLAUDE-SECURITY F4: bounded three ways so a peer that streams
    /// untagged chatter without ever completing the command can't grow the
    /// relay's memory without limit or hang it indefinitely: a cap on the
    /// number of untagged lines collected, a cap on their total byte size,
    /// and an overall wall-clock deadline for the whole command (on top of
    /// `nextLine`'s existing per-line timeout, which alone doesn't help —
    /// it resets on every line a peer sends, however small). Any of the
    /// three throws and the caller (`WatcherPool.runWatchLoop`) tears the
    /// connection down like any other command failure.
    private func readUntilTagged(
        _ tag: String,
        timeoutSeconds: Int64 = 35,
        overallDeadlineSeconds: Int64 = 90
    ) async throws -> [String] {
        var untagged: [String] = []
        var totalBytes = 0
        let deadline = Date().addingTimeInterval(TimeInterval(overallDeadlineSeconds))
        while true {
            if Date() >= deadline {
                throw IMAPClientError.timedOut
            }
            let remaining = max(1, min(timeoutSeconds, Int64(deadline.timeIntervalSinceNow)))
            let line = try await nextLine(timeoutSeconds: remaining)
            if line.hasPrefix("\(tag) ") {
                guard line.hasPrefix("\(tag) OK") else {
                    throw IMAPClientError.commandFailed(tag: tag, response: line)
                }
                return untagged
            }
            untagged.append(line)
            totalBytes += line.utf8.count
            if untagged.count > Self.maxUntaggedLinesPerCommand || totalBytes > Self.maxUntaggedBytesPerCommand {
                throw IMAPClientError.responseTooLarge
            }
        }
    }

    func login(username: String, password: String) async throws {
        let tag = nextTag()
        // v1 supports password auth only (plan: "LOGIN/XOAUTH2 なし可: password
        // のみ v1") — quoted-string literals with embedded `"`/`\` are
        // escaped per RFC 3501 §9. `Self.quoted` throws rather than
        // escaping a CR/LF/NUL (CLAUDE-SECURITY F3) — RFC 3501's
        // quoted-string grammar simply cannot carry one.
        let quotedUsername = try Self.quoted(username)
        let quotedPassword = try Self.quoted(password)
        try await write("\(tag) LOGIN \(quotedUsername) \(quotedPassword)")
        _ = try await readUntilTagged(tag)
    }

    @discardableResult
    func select(mailbox: String) async throws -> SelectResult {
        let tag = nextTag()
        try await write("\(tag) SELECT \(try Self.quoted(mailbox))")
        let untagged = try await readUntilTagged(tag)
        var exists = 0
        var uidNext: Int?
        for line in untagged {
            if let match = Self.firstMatch(in: line, pattern: #"^\* (\d+) EXISTS"#), let value = Int(match) {
                exists = value
            }
            if let match = Self.firstMatch(in: line, pattern: #"UIDNEXT (\d+)"#), let value = Int(match) {
                uidNext = value
            }
        }
        return SelectResult(exists: exists, uidNext: uidNext)
    }

    /// `STATUS mailbox (UIDNEXT)` — the polling fallback for servers
    /// without `IDLE` support, and also used as `IdleWatcher`'s belt-and-
    /// suspenders re-check after every `IDLE` wake.
    func statusUIDNext(mailbox: String) async throws -> Int {
        let tag = nextTag()
        try await write("\(tag) STATUS \(try Self.quoted(mailbox)) (UIDNEXT)")
        let untagged = try await readUntilTagged(tag)
        for line in untagged {
            if let match = Self.firstMatch(in: line, pattern: #"UIDNEXT (\d+)"#), let value = Int(match) {
                return value
            }
        }
        throw IMAPClientError.unexpectedResponse(untagged.joined(separator: " | "))
    }

    func capabilitiesIncludeIdle() async throws -> Bool {
        let tag = nextTag()
        try await write("\(tag) CAPABILITY")
        let untagged = try await readUntilTagged(tag)
        return untagged.contains { $0.uppercased().contains(" IDLE") || $0.uppercased().hasSuffix("IDLE") }
    }

    /// Starts `IDLE`, then blocks until either an untagged `EXISTS` arrives
    /// or `maxWaitSeconds` elapses (RFC 2177 recommends re-issuing `IDLE`
    /// at least every 29 minutes; the caller passes that as the cap).
    /// Always sends `DONE` before returning, whichever way it exits, so the
    /// connection is left ready for the next command.
    ///
    /// Timing out here (no new mail within `maxWaitSeconds`) is the
    /// *normal*, expected outcome for a quiet mailbox — RFC 2177 requires
    /// reissuing `IDLE` periodically regardless of whether anything
    /// happened. It must not disrupt the connection; see `LineBuffer`'s doc
    /// comment for a bug where an earlier implementation got this wrong.
    func idle(mailbox: String, maxWaitSeconds: Int64) async throws -> Bool {
        let tag = nextTag()
        try await write("\(tag) IDLE")
        // The server should reply with a continuation ("+ idling") before
        // any untagged data.
        let continuationLine = try await nextLine(timeoutSeconds: 35)
        guard continuationLine.hasPrefix("+") else {
            throw IMAPClientError.unexpectedResponse(continuationLine)
        }

        var sawExists = false
        let deadline = Date().addingTimeInterval(TimeInterval(maxWaitSeconds))
        while Date() < deadline {
            let remaining = max(1, Int64(deadline.timeIntervalSinceNow))
            do {
                let line = try await nextLine(timeoutSeconds: remaining)
                if Self.firstMatch(in: line, pattern: #"^\* (\d+) EXISTS"#) != nil {
                    sawExists = true
                    break
                }
                // Other untagged chatter (EXPUNGE, FETCH flag updates,
                // "* 0 RECENT", ...) during IDLE is ignored — this watcher
                // only cares about new-mail arrival. Real Dovecot sends
                // `* N EXISTS` and `* 0 RECENT` as two separate untagged
                // lines on new mail (`FakeIMAPServer` only ever sends the
                // former — see docs/verify.md); looping back around to read
                // the next line here is what makes either order work.
            } catch IMAPClientError.timedOut {
                break
            }
        }

        try await write("DONE")
        // If an `EXISTS` slips in right around the `DONE`/tagged-completion
        // handshake (the server is free to send it at any point before the
        // tagged response - RFC 3501 doesn't reserve that window), it must
        // still count: the wait loop above only watches for `EXISTS` while
        // it's still actively looping, and the caller only re-checks
        // `STATUS` when `idle()` reports `sawExists == true` (see
        // `WatcherPool.runWatchLoop`'s `guard gotExists else { continue }`)
        // — so silently dropping it here would mean this specific new-mail
        // event is never checked for at all, not even on the next cycle.
        let doneUntagged = try await readUntilTagged(tag)
        if !sawExists {
            sawExists = doneUntagged.contains { Self.firstMatch(in: $0, pattern: #"^\* (\d+) EXISTS"#) != nil }
        }
        return sawExists
    }

    func logout() async throws {
        let tag = nextTag()
        try await write("\(tag) LOGOUT")
        _ = try? await readUntilTagged(tag, timeoutSeconds: 5)
    }

    // MARK: - Helpers

    /// CLAUDE-SECURITY F3: previously escaped only `\` and `"`, letting a
    /// CR/LF embedded in `username`/`password`/`mailbox` pass straight
    /// through into the raw bytes `write(_:)` sends — terminating this
    /// IMAP command line early and smuggling attacker-chosen bytes as
    /// additional protocol lines to whatever `imapHost`/`imapPort` the
    /// watch was created with. RFC 3501 §9's `quoted-string` grammar
    /// (`QUOTED-CHAR = <any TEXT-CHAR except quoted-specials> / "\"
    /// quoted-specials`, `TEXT-CHAR = <any CHAR except CR and LF>`) simply
    /// cannot carry a CR/LF at all, so there's no valid escaping — this
    /// throws instead. `validateNoControlCharacters` is the same check
    /// `WatchRoutes` runs at watch-creation time (before anything is even
    /// persisted); this call is the defense-in-depth backstop for every
    /// value that reaches here by any path.
    private static func quoted(_ value: String) throws -> String {
        try validateNoControlCharacters(value, field: "IMAP command argument")
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Rejects any C0 control character (0x00–0x1F) or DEL (0x7F) — CR/LF
    /// (the injection vector) plus NUL and everything else RFC 3501
    /// disallows in a `quoted-string`/atom. Not `private` so `WatchRoutes`
    /// can run the identical check at `POST /v1/watches` time, before the
    /// value is ever persisted (CLAUDE-SECURITY F3's fix asks for both).
    static func validateNoControlCharacters(_ value: String, field: String) throws {
        for scalar in value.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw IMAPClientError.invalidControlCharacters(field: field)
        }
    }

    private static func firstMatch(in line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[swiftRange])
    }
}

/// Forwards every decoded line (CRLF already stripped by
/// `LineBasedFrameDecoder`) to an `AsyncStream` continuation, bridging
/// NIO's callback world into `MinimalIMAPClient`'s async/await API. The
/// stream's sole consumer is `MinimalIMAPClient`'s long-lived `pumpTask`.
private final class LineCollectorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<String>.Continuation

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let line = buffer.readString(length: buffer.readableBytes) ?? ""
        continuation.yield(line)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

/// Buffers lines pumped in from the wire (in order, via `push`) and lets
/// callers wait for the next one with a real, safely-cancellable timeout
/// (`next(timeoutSeconds:)`).
///
/// This replaces an earlier `MinimalIMAPClient.nextLine` implementation
/// that raced `AsyncStream.AsyncIterator.next()` directly against a
/// `Task.sleep` timeout inside a `withThrowingTaskGroup`, cancelling
/// whichever lost. That looked like a standard "race with timeout"
/// pattern, but was silently wrong for two independent reasons, both
/// confirmed against a real Dovecot server (`FakeIMAPServer` never
/// exercised either — see docs/verify.md):
///
/// 1. `withThrowingTaskGroup` is *structured* concurrency: when its body
///    throws (the timeout task winning), the group must still await every
///    other child task to actually finish before the throwing call can
///    return to its caller — cancellation alone doesn't exempt a child
///    from this wait. So "cancel the loser and move on" does not hold for
///    a task-group race in general; it only works if the loser reliably
///    unblocks *itself* promptly once cancelled.
/// 2. `AsyncStream.AsyncIterator.next()` doesn't unblock quietly on its own
///    task's cancellation the way e.g. `Task.sleep` does: cancelling a task
///    suspended inside it makes the call return `nil`, but because the
///    stream is a single shared reference (`AsyncStream` only supports one
///    logical reader), that also permanently finishes the *whole* stream —
///    every future `next()` call, from any task, returns `nil` from then
///    on.
///
/// Combined, every ordinary IDLE timeout (RFC 2177's "no new mail within
/// the window, reissue IDLE" — the *expected* outcome for a quiet mailbox,
/// not an error) permanently killed the connection's read side. The very
/// next read (waiting for `DONE`'s tagged response) then failed with
/// `.connectionClosed`, forcing `WatcherPool` into a full reconnect. Worse,
/// a reconnect re-baselines `UIDNEXT` from a fresh `SELECT`, so any mail
/// that arrived during the reconnect gap was silently folded into the new
/// baseline instead of firing a push — in practice this meant a watch
/// could go from "connected" to "never notices new mail again" the first
/// time its mailbox went quiet for a full IDLE window.
///
/// `LineBuffer` fixes this by fully decoupling "read from the wire" (the
/// single, persistent, never-cancelled `pumpTask` that only ever calls
/// `push`) from "wait up to N seconds for the next line" (`next`, whose
/// cancellation-on-timeout only ever touches its own local waiter
/// registration below — never the underlying feed).
private actor LineBuffer {
    /// CLAUDE-SECURITY F8: `push` is fed by the persistent `pumpTask`,
    /// which keeps running for the whole connection lifetime independent
    /// of whether anything is currently calling `next` — e.g. the ~5-minute
    /// `Task.sleep` between STATUS polls (`WatcherPool`'s non-`IDLE`
    /// fallback) is a window where nobody drains this at all. Without a
    /// bound, a peer that streams short lines continuously during that
    /// window grows `buffered` without limit. These two caps mirror
    /// `MinimalIMAPClient.maxUntaggedLinesPerCommand`/
    /// `maxUntaggedBytesPerCommand` but apply to the raw, not-yet-consumed
    /// feed rather than one command's collected untagged lines — both
    /// layers matter, since this one is what actually protects the idle
    /// gap between commands.
    private static let maxBufferedLines = 2000
    private static let maxBufferedBytes = 1_000_000

    private var buffered: [String] = []
    private var bufferedByteCount = 0
    private var finished = false
    /// Set once `maxBufferedLines`/`maxBufferedBytes` is exceeded — from
    /// then on `push` drops further lines (already over budget, no point
    /// buffering more) and every `next` call throws `.responseTooLarge`
    /// until the connection is torn down by the caller.
    private var overflowed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var waiterTimeoutTask: Task<Void, Never>?

    func push(_ line: String) {
        guard !overflowed else { return }
        buffered.append(line)
        bufferedByteCount += line.utf8.count
        if buffered.count > Self.maxBufferedLines || bufferedByteCount > Self.maxBufferedBytes {
            overflowed = true
            // Free what's already buffered immediately rather than waiting
            // for the next `next()` call to notice `overflowed` — the
            // whole point is bounding peak memory, not just eventually
            // erroring out.
            buffered.removeAll()
            bufferedByteCount = 0
        }
        wake()
    }

    func finish() {
        finished = true
        wake()
    }

    /// Returns the next buffered line, waiting for one to arrive (or the
    /// stream to finish) if none is buffered yet, up to `timeoutSeconds`.
    func next(timeoutSeconds: Int64) async throws -> String {
        while true {
            if overflowed {
                throw MinimalIMAPClient.IMAPClientError.responseTooLarge
            }
            if !buffered.isEmpty {
                let line = buffered.removeFirst()
                bufferedByteCount -= line.utf8.count
                return line
            }
            if finished {
                throw MinimalIMAPClient.IMAPClientError.connectionClosed
            }
            let sawActivity = await waitForActivity(timeoutSeconds: timeoutSeconds)
            if !sawActivity {
                throw MinimalIMAPClient.IMAPClientError.timedOut
            }
            // Otherwise loop back around and re-check `buffered`/`finished`
            // — `waitForActivity` returning `true` just means "something
            // happened, go look", not specifically "a line is ready".
        }
    }

    /// Suspends until `push`/`finish` is called or `timeoutSeconds`
    /// elapses, returning whether it was the former. Cancelling the
    /// *caller's* task (e.g. the caller itself being torn down) also
    /// resolves this promptly via `withTaskCancellationHandler` — safely,
    /// since all it does is clear this actor's own `waiter`/timer state.
    private func waitForActivity(timeoutSeconds: Int64) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !buffered.isEmpty || finished {
                    continuation.resume()
                    return
                }
                waiter = continuation
                waiterTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    } catch {
                        // Cancelled by `wake()` (real activity arrived, or the
                        // caller's task was itself cancelled) - that call
                        // already resumed the waiter. Returning here without
                        // also calling `wake()` again is required, not just
                        // an optimization: this task's identity isn't tied to
                        // any particular `next(timeoutSeconds:)` call, so a
                        // stray post-cancellation `wake()` here would
                        // spuriously resume a *later*, unrelated wait that
                        // had genuinely started waiting again in the
                        // meantime - observed as `nextLine` timing out almost
                        // immediately, well before its real deadline.
                        return
                    }
                    await self?.wake()
                }
            }
        } onCancel: {
            Task { await self.wake() }
        }
        return !buffered.isEmpty || finished
    }

    private func wake() {
        waiterTimeoutTask?.cancel()
        waiterTimeoutTask = nil
        waiter?.resume()
        waiter = nil
    }
}
