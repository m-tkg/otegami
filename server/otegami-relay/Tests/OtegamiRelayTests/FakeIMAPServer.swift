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

    init(eventLoopGroup: any EventLoopGroup, initialExists: Int = 5, initialUidNext: Int = 6, supportsIdle: Bool = true) {
        self.eventLoopGroup = eventLoopGroup
        self.exists = initialExists
        self.uidNext = initialUidNext
        self.supportsIdle = supportsIdle
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
            write(context: context, "\(tag) OK LOGIN completed")

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

    private func write(context: ChannelHandlerContext, _ line: String) {
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
