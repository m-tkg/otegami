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
    enum IMAPClientError: Error, CustomStringConvertible {
        case notConnected
        case connectionClosed
        case timedOut
        case commandFailed(tag: String, response: String)
        case unexpectedResponse(String)

        var description: String {
            switch self {
            case .notConnected: "IMAP client is not connected"
            case .connectionClosed: "IMAP connection closed unexpectedly"
            case .timedOut: "IMAP command timed out"
            case .commandFailed(let tag, let response): "IMAP command \(tag) failed: \(response)"
            case .unexpectedResponse(let line): "unexpected IMAP response: \(line)"
            }
        }
    }

    struct SelectResult {
        var exists: Int
        var uidNext: Int?
    }

    private let eventLoopGroup: any EventLoopGroup
    private var channel: (any Channel)?
    private var iterator: AsyncStream<String>.AsyncIterator?
    private var tagCounter = 0

    init(eventLoopGroup: any EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Connection

    func connect(host: String, port: Int, useTLS: Bool, timeoutSeconds: Int64 = 15) async throws {
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
                    handlers.append(ByteToMessageHandler(LineBasedFrameDecoder()))
                    handlers.append(LineCollectorHandler(continuation: continuation))
                    return channel.pipeline.addHandlers(handlers)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        self.channel = channel
        self.iterator = stream.makeAsyncIterator()

        // Consume the server's untagged greeting ("* OK ... ready").
        _ = try await nextLine(timeoutSeconds: timeoutSeconds)
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
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

    private func nextLine(timeoutSeconds: Int64) async throws -> String {
        guard iterator != nil else { throw IMAPClientError.notConnected }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [self] in
                guard var iter = self.iterator else { throw IMAPClientError.notConnected }
                guard let line = await iter.next() else { throw IMAPClientError.connectionClosed }
                self.iterator = iter
                return line
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw IMAPClientError.timedOut
            }
            guard let result = try await group.next() else { throw IMAPClientError.timedOut }
            group.cancelAll()
            return result
        }
    }

    /// Reads lines until a tagged response for `tag` arrives, collecting
    /// every untagged (`*`) line seen along the way. Throws
    /// `.commandFailed` if the tagged response isn't `OK`.
    private func readUntilTagged(_ tag: String, timeoutSeconds: Int64 = 35) async throws -> [String] {
        var untagged: [String] = []
        while true {
            let line = try await nextLine(timeoutSeconds: timeoutSeconds)
            if line.hasPrefix("\(tag) ") {
                guard line.hasPrefix("\(tag) OK") else {
                    throw IMAPClientError.commandFailed(tag: tag, response: line)
                }
                return untagged
            }
            untagged.append(line)
        }
    }

    func login(username: String, password: String) async throws {
        let tag = nextTag()
        // v1 supports password auth only (plan: "LOGIN/XOAUTH2 なし可: password
        // のみ v1") — quoted-string literals with embedded `"`/`\` are
        // escaped per RFC 3501 §9.
        try await write("\(tag) LOGIN \(Self.quoted(username)) \(Self.quoted(password))")
        _ = try await readUntilTagged(tag)
    }

    @discardableResult
    func select(mailbox: String) async throws -> SelectResult {
        let tag = nextTag()
        try await write("\(tag) SELECT \(Self.quoted(mailbox))")
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
        try await write("\(tag) STATUS \(Self.quoted(mailbox)) (UIDNEXT)")
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
                // Other untagged chatter (EXPUNGE, FETCH flag updates, ...)
                // during IDLE is ignored — this watcher only cares about
                // new-mail arrival.
            } catch IMAPClientError.timedOut {
                break
            }
        }

        try await write("DONE")
        _ = try await readUntilTagged(tag)
        return sawExists
    }

    func logout() async throws {
        let tag = nextTag()
        try await write("\(tag) LOGOUT")
        _ = try? await readUntilTagged(tag, timeoutSeconds: 5)
    }

    // MARK: - Helpers

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
/// NIO's callback world into `MinimalIMAPClient`'s async/await API.
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
