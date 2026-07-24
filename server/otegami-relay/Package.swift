// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "otegami-relay",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.1"),
        // Bearer-token secret hashing + AES-GCM credential-at-rest
        // encryption (`CredentialCrypto`) and ES256 JWT signing for the
        // APNs token-based auth (`APNsSender`). Already pulled in
        // transitively by Hummingbird; pinned explicitly since
        // `OtegamiRelay` imports it directly.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        // Raw TCP/TLS for the hand-rolled minimal IMAP client
        // (`Watcher/MinimalIMAPClient`) — see that file's doc comment for
        // why this project doesn't depend on swift-nio-imap.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // `LineBasedFrameDecoder`, used by the hand-rolled IMAP client to
        // split the byte stream into CRLF-terminated lines.
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.4.0"),
        // HTTP/2 client for APNs (`Push/APNsSender`).
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        // SQLite storage for `RelayStore` — chosen over GRDB because GRDB's
        // Linux support is secondary/unofficial, while SQLiteNIO is a
        // Vapor-maintained, NIO-native, Linux-first SQLite driver (this
        // server only ever runs on Linux in production, per
        // docs/relay-deployment.md).
        .package(url: "https://github.com/vapor/sqlite-nio.git", from: "1.7.0"),
        // `Service`/`withGracefulShutdownHandler` for `WatcherPool` — already
        // pulled in transitively by Hummingbird (which re-exports it via
        // `public import`), pinned explicitly since `WatcherPool` imports
        // it directly.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        // Shared DTOs (`OtegamiRelayAPI`, Linux-compatible) — the app and
        // this server both depend on the same request/response types
        // instead of hand-duplicating the wire format. Only this product
        // and its own dependency `OtegamiCore` are used; the rest of
        // OtegamiKit (MailCore2, GRDB, ...) is never pulled into this
        // build graph.
        .package(path: "../../packages/OtegamiKit"),
    ],
    targets: [
        .executableTarget(
            name: "OtegamiRelay",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "SQLiteNIO", package: "sqlite-nio"),
                .product(name: "OtegamiRelayAPI", package: "OtegamiKit"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "OtegamiRelayTests",
            dependencies: [
                "OtegamiRelay",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "OtegamiRelayAPI", package: "OtegamiKit"),
            ]
        ),
    ]
)
