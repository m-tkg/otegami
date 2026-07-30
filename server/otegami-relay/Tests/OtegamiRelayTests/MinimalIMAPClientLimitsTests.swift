import NIOCore
import NIOPosix
import Testing

@testable import OtegamiRelay

/// CLAUDE-SECURITY F4/F8: `MinimalIMAPClient` used to accumulate untagged
/// response lines and buffer decoded/undecoded bytes with no limit at all,
/// so a malicious or misbehaving IMAP endpoint (any host/port a watch
/// names — see `RelayNetworkPolicyTests` for who can choose that) could
/// grow the relay process's memory without bound. These tests drive a
/// deliberately misbehaving fake peer (`FloodingIMAPServer`, distinct from
/// `FakeIMAPServer`'s well-behaved protocol subset) against the two bounds
/// added to fix that: `readUntilTagged`'s per-command untagged-line/byte
/// cap, and the frame decoder's `maximumBufferSize`.
@Suite("MinimalIMAPClient response-size limits (CLAUDE-SECURITY F4/F8)")
struct MinimalIMAPClientLimitsTests {
    @Test("a peer that floods untagged lines without ever completing the command trips the per-command bound")
    func floodingUntaggedLinesTripsBound() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let server = FloodingIMAPServer(eventLoopGroup: eventLoopGroup, mode: .untaggedLineFlood)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let client = MinimalIMAPClient(eventLoopGroup: eventLoopGroup)
        try await client.connect(host: "127.0.0.1", port: port, useTLS: false, networkPolicy: .permissiveForTesting)

        await #expect(throws: MinimalIMAPClient.IMAPClientError.responseTooLarge) {
            try await client.login(username: "user", password: "pw")
        }
        await client.close()
    }

    @Test("a peer that sends an oversized, unterminated line trips the frame-length bound and the connection is torn down")
    func oversizedLineTripsFrameLengthBound() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        let server = FloodingIMAPServer(eventLoopGroup: eventLoopGroup, mode: .oversizedLine)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let client = MinimalIMAPClient(eventLoopGroup: eventLoopGroup)
        // The oversized, never-terminated "line" is sent as soon as the
        // connection is established, so `connect` itself (which waits for
        // the untagged greeting) is what should observe the fallout: the
        // frame decoder throws `PayloadTooLargeError`, which tears the
        // connection down, which surfaces here as `.connectionClosed`.
        await #expect(throws: MinimalIMAPClient.IMAPClientError.connectionClosed) {
            try await client.connect(host: "127.0.0.1", port: port, useTLS: false, networkPolicy: .permissiveForTesting)
        }
    }
}

/// A raw, deliberately misbehaving fake IMAP-shaped TCP server used only by
/// `MinimalIMAPClientLimitsTests`. Unlike `FakeIMAPServer` (a well-behaved
/// subset of the real protocol, used by `WatcherPoolTests`), this one
/// exists purely to violate the two size bounds CLAUDE-SECURITY F4/F8
/// added to `MinimalIMAPClient`.
final class FloodingIMAPServer: @unchecked Sendable {
    enum Mode: Equatable {
        /// Sends a normal greeting, then on the first line received from
        /// the client (assumed to be `LOGIN`), floods untagged `* junk`
        /// lines forever without ever sending a tagged completion —
        /// exercises `readUntilTagged`'s per-command line-count/byte bound.
        case untaggedLineFlood
        /// Sends a single ~20KB blob with no CRLF anywhere in it, as soon
        /// as the connection opens — the frame decoder can never find a
        /// line boundary, so its cumulation buffer just keeps growing past
        /// `maximumBufferSize`. Exercises the frame-length bound.
        case oversizedLine
    }

    private let eventLoopGroup: any EventLoopGroup
    private let mode: Mode
    private var serverChannel: (any Channel)?

    init(eventLoopGroup: any EventLoopGroup, mode: Mode) {
        self.eventLoopGroup = eventLoopGroup
        self.mode = mode
    }

    func start() async throws -> Int {
        let mode = self.mode
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(FloodingIMAPConnectionHandler(mode: mode))
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        serverChannel = channel
        guard let port = channel.localAddress?.port else {
            throw FloodingIMAPServerError.noPort
        }
        return port
    }

    func stop() async {
        try? await serverChannel?.close().get()
    }

    enum FloodingIMAPServerError: Error {
        case noPort
    }
}

private final class FloodingIMAPConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let mode: FloodingIMAPServer.Mode
    private var startedFlooding = false

    init(mode: FloodingIMAPServer.Mode) {
        self.mode = mode
    }

    func channelActive(context: ChannelHandlerContext) {
        switch mode {
        case .untaggedLineFlood:
            writeLine(context: context, "* OK fake IMAP ready")
        case .oversizedLine:
            var buffer = context.channel.allocator.buffer(capacity: 20_000)
            buffer.writeString(String(repeating: "A", count: 20_000))
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard mode == .untaggedLineFlood, !startedFlooding else { return }
        startedFlooding = true
        // Comfortably past `MinimalIMAPClient`'s 500-line/256KB bound so
        // the test isn't racing the exact threshold.
        for _ in 0..<2000 {
            writeLine(context: context, "* junk untagged response line", flush: false)
        }
        context.flush()
    }

    private func writeLine(context: ChannelHandlerContext, _ line: String, flush: Bool = true) {
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count + 2)
        buffer.writeString(line)
        buffer.writeString("\r\n")
        if flush {
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        } else {
            context.write(wrapOutboundOut(buffer), promise: nil)
        }
    }
}
