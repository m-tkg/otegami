// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OtegamiKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "OtegamiCore", targets: ["OtegamiCore"]),
        .library(name: "MailTransport", targets: ["MailTransport"]),
        .library(name: "OtegamiStore", targets: ["OtegamiStore"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "OtegamiRelayAPI", targets: ["OtegamiRelayAPI"]),
        .library(name: "MailTransportMailCore", targets: ["MailTransportMailCore"]),
        .library(name: "GoogleOAuth", targets: ["GoogleOAuth"]),
        .library(name: "PushRelayClient", targets: ["PushRelayClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),

        // MailCore2, source-built via Swift Package Manager. See
        // docs/build-mailcore2.md for why this fork/branch was chosen over
        // hand-rolling an XCFramework build script. Pinned to an exact
        // revision (rather than tracking the branch) for reproducibility;
        // bump deliberately and re-verify against dev/mailstack.
        .package(url: "https://github.com/readdle/mailcore2.git", revision: "44c63329df67e9a0d597627edbebe65002d3fcd8"),
    ],
    targets: [
        // Linux-compatible model & pure-logic layer. No dependencies.
        .target(
            name: "OtegamiCore"
        ),

        // Protocol-only abstraction over IMAP/SMTP transport. Linux-compatible;
        // concrete implementations (e.g. MailCore2) live behind this.
        .target(
            name: "MailTransport",
            dependencies: ["OtegamiCore"]
        ),

        // GRDB-backed local store (schema, DAOs, FTS indexer).
        .target(
            name: "OtegamiStore",
            dependencies: [
                "OtegamiCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Sync orchestration: SyncCoordinator / AccountSyncer / MailboxSyncer / opQueue.
        .target(
            name: "SyncEngine",
            dependencies: [
                "OtegamiCore",
                "MailTransport",
                "OtegamiStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // DTOs shared between the app and the push relay server. Linux-compatible.
        .target(
            name: "OtegamiRelayAPI",
            dependencies: ["OtegamiCore"]
        ),

        // MailCore2-backed adapter for MailTransport. Apple-only; MailCore2
        // itself (and its C/C++ dependencies) are only ever pulled in via
        // this target, so building any *other* single target/product (e.g.
        // `swift build --target OtegamiCore`) doesn't need it. A bare
        // `swift test` still builds every test target including
        // MailTransportMailCoreTests, so it remains macOS/iOS-only; see
        // docs/build-mailcore2.md for the current CI implications.
        .target(
            name: "MailTransportMailCore",
            dependencies: [
                "MailTransport",
                .product(name: "MailCore", package: "mailcore2"),
            ]
        ),

        .testTarget(
            name: "OtegamiCoreTests",
            dependencies: ["OtegamiCore"]
        ),

        // In-memory GRDB migration + envelope-persistence + query tests.
        .testTarget(
            name: "OtegamiStoreTests",
            dependencies: ["OtegamiStore"]
        ),

        // FakeIMAPSession-driven SyncEngine scenario tests (initial sync,
        // idempotent resync, >500-message windowing).
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine", "MailTransport", "OtegamiStore"]
        ),

        // Integration tests against a real IMAP server (the dev mailstack's
        // Dovecot by default). Opt-in: skipped unless
        // OTEGAMI_TEST_IMAP_HOST is set. See Tests/MailTransportMailCoreTests.
        // Depends on SyncEngine too (M3): SyncEngineIntegrationTests drives
        // AccountSyncer.performIncrementalSync against the real
        // MailCoreIMAPSession, with `doveadm` (via `docker compose exec`)
        // standing in for another client's concurrent changes.
        .testTarget(
            name: "MailTransportMailCoreTests",
            dependencies: ["MailTransportMailCore", "SyncEngine", "OtegamiStore"]
        ),

        // M9: HTTP client for the app<->otegami-relay push relay API.
        // Apple-only by convention (see the target's own doc comment) —
        // depends only on OtegamiRelayAPI.
        .target(
            name: "PushRelayClient",
            dependencies: ["OtegamiRelayAPI"]
        ),

        // `URLProtocol`-stubbed request/response and error-mapping tests —
        // no real relay server touched. Mirrors GoogleOAuthClientTests'
        // approach.
        .testTarget(
            name: "PushRelayClientTests",
            dependencies: ["PushRelayClient", "OtegamiRelayAPI"]
        ),

        // Gmail OAuth2 (Authorization Code + PKCE) client + `TokenStore`
        // (M6). Apple-only (AuthenticationServices, CryptoKit, Security) —
        // like MailTransportMailCore, this is never pulled into any
        // Linux-compatible target. Has no dependency on any other target in
        // this package (not even `MailTransport`): it only ever produces
        // `MailAuth.xoauth2`'s two raw associated values (username, access
        // token) as plain strings, letting the app layer construct the
        // actual `MailAuth` — keeps this package's own dependency graph
        // acyclic and this target trivially unit-testable in isolation.
        .target(
            name: "GoogleOAuth"
        ),

        // PKCE known-vector tests, `GoogleOAuthClient` token-exchange/
        // refresh tests (`URLProtocol` HTTP stub + `FakeAuthorizationFlow`),
        // and `TokenStore` expiry/refresh/invalid_grant tests (clock +
        // `RefreshTokenStoring` both injected — no real Keychain or network
        // touched).
        .testTarget(
            name: "GoogleOAuthTests",
            dependencies: ["GoogleOAuth"]
        ),
    ]
)
