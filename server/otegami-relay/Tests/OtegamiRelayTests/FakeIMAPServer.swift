import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOExtras
import NIOPosix

/// A tiny scripted IMAP server for `WatcherPoolTests` / a future
/// `MinimalIMAPClient` test: accepts one connection, answers `LOGIN`,
/// `CAPABILITY`, `SELECT`, `STATUS`, and `IDLE`/`DONE` with plausible
/// responses, and lets the test simulate "new mail arrived" via
/// `deliverNewMail()` — which both bumps the server's own `EXISTS`/
/// `UIDNEXT` counters (so a subsequent `STATUS` reflects it) and, if a
/// client is currently mid-`IDLE`, pushes an unsolicited `* n EXISTS` line
/// down the wire immediately (so the client's `idle()` wakes up
/// immediately rather than only on its own timeout).
final class FakeIMAPServer: @unchecked Sendable {
    private let eventLoopGroup: any EventLoopGroup
    private let lock = NIOLock()
    private var serverChannel: (any Channel)?
    private var clientChannel: (any Channel)?
    private var exists: Int
    private var uidNext: Int
    let supportsIdle: Bool
    /// Task #173 (`WatcherPoolTests`' auth-failure test): when `true`,
    /// `LOGIN` always answers `NO` instead of `OK`, so a test can exercise
    /// `WatcherPool`'s `maxConsecutiveAuthFailures` give-up path against a
    /// real (if fake) IMAP round trip instead of only unit-testing
    /// `RelayStore.recordWatchError` in isolation.
    let rejectsLogin: Bool
    /// Task #175 (`WatcherPoolTests`' OAuth/XOAUTH2 tests): when set,
    /// `AUTHENTICATE XOAUTH2 <base64>` succeeds only if the decoded SASL
    /// response's `auth=Bearer ` segment matches this exact access token —
    /// anything else (including a well-formed request with the wrong
    /// token) gets the RFC 7628 §3.2.2 continuation-then-tagged-failure
    /// dance `MinimalIMAPClient.authenticateXOAuth2` expects a real
    /// Gmail/Outlook server to use. `nil` (the default) accepts any
    /// well-formed XOAUTH2 request — most tests don't care about the
    /// token's exact value, only that XOAUTH2 itself works.
    let expectedXOAuth2AccessToken: String?

    init(
        eventLoopGroup: any EventLoopGroup,
        initialExists: Int = 5,
        initialUidNext: Int = 6,
        supportsIdle: Bool = true,
        rejectsLogin: Bool = false,
        expectedXOAuth2AccessToken: String? = nil
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.exists = initialExists
        self.uidNext = initialUidNext
        self.supportsIdle = supportsIdle
        self.rejectsLogin = rejectsLogin
        self.expectedXOAuth2AccessToken = expectedXOAuth2AccessToken
    }

    /// Starts listening on an ephemeral loopback port, returning it.
    func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
                self.lock.withLock { self.clientChannel = channel }
                return channel.pipeline.addHandlers([
                    ByteToMessageHandler(LineBasedFrameDecoder()),
                    FakeIMAPConnectionHandler(server: self),
                ])
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        lock.withLock { serverChannel = channel }
        guard let port = channel.localAddress?.port else {
            throw FakeIMAPServerError.noPort
        }
        return port
    }

    func stop() async {
        let channel = lock.withLock { serverChannel }
        try? await channel?.close().get()
    }

    /// Simulates new mail arriving: bumps the mailbox state and, if a
    /// client is mid-`IDLE` right now, wakes it immediately.
    ///
    /// Sends `* N EXISTS` followed by a separate `* 0 RECENT` line — real
    /// Dovecot sends both as distinct untagged lines on new mail (confirmed
    /// by manually IDLE-ing against `dev/mailstack` and running
    /// `doveadm save` from another session; see docs/verify.md). An earlier
    /// version of this fake only ever sent the `EXISTS` line, which masked
    /// a real bug in `MinimalIMAPClient.idle`'s read loop for servers that
    /// send extra untagged chatter around the line the client actually
    /// cares about.
    func deliverNewMail() {
        let (newExists, channel) = lock.withLock { () -> (Int, (any Channel)?) in
            exists += 1
            uidNext += 1
            return (exists, clientChannel)
        }
        guard let channel else { return }
        Self.writeLine("* \(newExists) EXISTS", to: channel)
        Self.writeLine("* 0 RECENT", to: channel)
    }

    fileprivate func currentState() -> (exists: Int, uidNext: Int) {
        lock.withLock { (exists, uidNext) }
    }

    fileprivate static func writeLine(_ line: String, to channel: any Channel) {
        var buffer = channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        channel.writeAndFlush(buffer, promise: nil)
    }

    enum FakeIMAPServerError: Error {
        case noPort
    }
}

private final class FakeIMAPConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private unowned let server: FakeIMAPServer
    private var idling = false
    private var pendingIdleTag = ""
    /// Task #175: set while waiting for the client's empty-line response to
    /// a `+ <base64 error>` XOAUTH2 continuation (see `handleXOAuth2`) —
    /// the very next line read is that empty ack, not a normal tagged
    /// command, regardless of its content.
    private var awaitingXOAuth2FailureAck = false
    private var pendingXOAuth2FailureTag = ""

    init(server: FakeIMAPServer) {
        self.server = server
    }

    func channelActive(context: ChannelHandlerContext) {
        write(context: context, "* OK fake IMAP ready")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let line = buffer.readString(length: buffer.readableBytes) else { return }
        handle(line: line, context: context)
    }

    private func handle(line: String, context: ChannelHandlerContext) {
        if awaitingXOAuth2FailureAck {
            awaitingXOAuth2FailureAck = false
            write(context: context, "\(pendingXOAuth2FailureTag) NO [AUTHENTICATIONFAILED] authentication failed")
            return
        }
        if idling {
            if line.uppercased() == "DONE" {
                idling = false
                write(context: context, "\(pendingIdleTag) OK IDLE terminated")
            }
            return
        }

        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return }
        let tag = parts[0]
        let command = parts[1].uppercased()

        switch command {
        case "LOGIN":
            if server.rejectsLogin {
                write(context: context, "\(tag) NO [AUTHENTICATIONFAILED] authentication failed")
            } else {
                write(context: context, "\(tag) OK LOGIN completed")
            }

        case "AUTHENTICATE":
            // Task #175 (XOAUTH2/SASL-IR): `parts[2]` is `"XOAUTH2
            // <base64>"` as a single string (the `maxSplits: 2` above
            // already stopped splitting after the command word).
            guard parts.count >= 3 else {
                write(context: context, "\(tag) BAD missing AUTHENTICATE argument")
                break
            }
            let mechanismAndPayload = parts[2].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard mechanismAndPayload.count == 2, mechanismAndPayload[0].uppercased() == "XOAUTH2" else {
                write(context: context, "\(tag) BAD unsupported AUTHENTICATE mechanism")
                break
            }
            handleXOAuth2(tag: tag, base64Payload: String(mechanismAndPayload[1]), context: context)

        case "CAPABILITY":
            write(context: context, "* CAPABILITY IMAP4rev1\(server.supportsIdle ? " IDLE" : "")")
            write(context: context, "\(tag) OK CAPABILITY completed")

        case "SELECT":
            let state = server.currentState()
            write(context: context, "* \(state.exists) EXISTS")
            write(context: context, "* OK [UIDNEXT \(state.uidNext)] next uid")
            write(context: context, "\(tag) OK [READ-WRITE] SELECT completed")

        case "STATUS":
            let state = server.currentState()
            write(context: context, "* STATUS INBOX (UIDNEXT \(state.uidNext))")
            write(context: context, "\(tag) OK STATUS completed")

        case "IDLE":
            pendingIdleTag = tag
            idling = true
            write(context: context, "+ idling")

        case "LOGOUT":
            write(context: context, "* BYE logging out")
            write(context: context, "\(tag) OK LOGOUT completed")

        default:
            write(context: context, "\(tag) BAD unknown command")
        }
    }

    /// Task #175: decodes the XOAUTH2 SASL response
    /// (`MinimalIMAPClient.authenticateXOAuth2`'s doc comment has the exact
    /// format) and accepts/rejects per `server.expectedXOAuth2AccessToken`.
    private func handleXOAuth2(tag: String, base64Payload: String, context: ChannelHandlerContext) {
        guard let data = Data(base64Encoded: base64Payload),
              let decoded = String(data: data, encoding: .utf8)
        else {
            write(context: context, "\(tag) BAD invalid XOAUTH2 payload")
            return
        }

        let accepted: Bool
        if let expected = server.expectedXOAuth2AccessToken {
            accepted = decoded.contains("auth=Bearer \(expected)\u{01}")
        } else {
            accepted = decoded.hasPrefix("user=") && decoded.contains("auth=Bearer ")
        }

        if accepted {
            write(context: context, "\(tag) OK AUTHENTICATE completed")
        } else {
            // RFC 7628 §3.2.2: a rejected token gets a `+`-continuation
            // carrying a base64 JSON error challenge, not an immediate
            // tagged failure — the client must answer with an empty line
            // (handled at the top of `handle(line:context:)` via
            // `awaitingXOAuth2FailureAck`) before the tagged `NO` arrives.
            let errorChallenge = Data(#"{"status":"401","schemes":"bearer"}"#.utf8).base64EncodedString()
            write(context: context, "+ \(errorChallenge)")
            pendingXOAuth2FailureTag = tag
            awaitingXOAuth2FailureAck = true
        }
    }

    private func write(context: ChannelHandlerContext, _ line: String) {
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
