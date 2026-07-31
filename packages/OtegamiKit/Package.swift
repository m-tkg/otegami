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
        .library(name: "MicrosoftOAuth", targets: ["MicrosoftOAuth"]),
        .library(name: "PushRelayClient", targets: ["PushRelayClient"]),
        .library(name: "AccountCloudSync", targets: ["AccountCloudSync"]),
        .library(name: "OtegamiTranslation", targets: ["OtegamiTranslation"]),
        .library(name: "OtegamiTranslationFoundationModels", targets: ["OtegamiTranslationFoundationModels"]),
        .library(name: "OtegamiTranslationApple", targets: ["OtegamiTranslationApple"]),
        .library(name: "TranslationEngine", targets: ["TranslationEngine"]),
        .library(name: "BIMI", targets: ["BIMI"]),
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

        // Task #119: pure-logic tests for `MailboxRole.inferred(fromDisplayPath:)`
        // (the SPECIAL-USE-less name-based fallback) — no MailCore2 or real
        // IMAP server needed, unlike MailTransportMailCoreTests below.
        .testTarget(
            name: "MailTransportTests",
            dependencies: ["MailTransport"]
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
        // Depends on OtegamiTranslation (not the FoundationModels-backed
        // target) only for `MessageLanguageDetector` — `BodyFetcher` runs it
        // synchronously right after a body is fetched, so a message's
        // English/Japanese-ness is known before any UI ever asks (see
        // `MessageLanguageDetector`'s doc comment for why this needs no LLM
        // and stays cheap enough to run inline).
        .target(
            name: "SyncEngine",
            dependencies: [
                "OtegamiCore",
                "MailTransport",
                "OtegamiStore",
                "OtegamiTranslation",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // DTOs shared between the app and the push relay server. Linux-compatible.
        .target(
            name: "OtegamiRelayAPI"
        ),

        // Locks the Foundation Codable wire format to the Go relay DTOs in
        // server/otegami-relay-go/internal/api/dto.go.
        .testTarget(
            name: "OtegamiRelayAPITests",
            dependencies: ["OtegamiRelayAPI"]
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
                "OtegamiCore",
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
        // depends only on OtegamiRelayAPI. Task #176 added OtegamiCore too,
        // so `NotificationEnrichment.body(preferences:...)` can reuse
        // `SnippetBuilder.make(from:maxLength:)` (already `public`, already
        // depended on by half this package) for the body-preview snippet's
        // length limit instead of re-deriving that truncation logic here.
        .target(
            name: "PushRelayClient",
            dependencies: ["OtegamiRelayAPI", "OtegamiCore"]
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

        // Task #116 第2段「Outlook.com / Office365 (Microsoft OAuth)」:
        // Outlook.com/Office 365's Authorization Code + PKCE client +
        // `TokenStore`. Deliberately mirrors `GoogleOAuth` above (same
        // Apple-only surface — AuthenticationServices/CryptoKit/Security —
        // and the same "no dependency on any other target in this package"
        // shape) rather than sharing code with it: keeping the two
        // providers fully independent means either one can be dropped, or a
        // third provider added the same way, without touching the other.
        // See `MicrosoftOAuth`'s individual files for the "mirrors
        // GoogleOAuth.X" doc comments that spell out what, if anything,
        // differs from its Google counterpart.
        .target(
            name: "MicrosoftOAuth"
        ),

        // Mirrors `GoogleOAuthTests` — PKCE known-vector test (shared RFC
        // 7636 ground truth), `MicrosoftOAuthEndpoints`/`MicrosoftOAuthClient`
        // URLProtocol-stubbed token-exchange/refresh/id_token-decoding
        // tests, and `TokenStore` expiry/refresh/invalid_grant tests.
        .testTarget(
            name: "MicrosoftOAuthTests",
            dependencies: ["MicrosoftOAuth"]
        ),

        // iCloud account-definition sync (iCloud Keychain already syncs
        // credentials on its own — see KeychainCredentialStore's doc
        // comment; this is the metadata half). Apple-only
        // (`NSUbiquitousKeyValueStore`), like GoogleOAuth/PushRelayClient.
        // Depends on OtegamiStore only for `AccountRecord`/its enums
        // (`CloudAccountSnapshot` mirrors it) — no GRDB access happens in
        // this target itself, only in the app-layer `LocalAccountDirectory`
        // conformer.
        .target(
            name: "AccountCloudSync",
            dependencies: ["OtegamiStore"]
        ),

        // FakeUbiquitousStore/FakeLocalAccountDirectory-driven reconcile
        // scenario tests — no real iCloud KVS or GRDB touched (mirrors
        // GoogleOAuthTests' TokenStoreTests approach).
        .testTarget(
            name: "AccountCloudSyncTests",
            dependencies: ["AccountCloudSync"]
        ),

        // On-device translation, protocol-only (M12: docs/translation.md).
        // Linux-compatible like `MailTransport` — the `TranslationService`
        // protocol, its plain-data types, and `FakeTranslationService` (a
        // deterministic in-memory implementation used by tests and, later,
        // previews) have no Apple-only dependency. `MessageLanguageDetector`
        // is the one exception: it needs `NaturalLanguage`, so its whole
        // file is wrapped in `#if canImport(NaturalLanguage)` rather than
        // splitting it into its own target — `NaturalLanguage` has shipped
        // on every Apple OS version this package targets (unlike
        // `FoundationModels`, which is iOS/macOS 26+ only and gets its own
        // target below), so gating at the file level is enough to keep a
        // Linux `swift build` of this target a no-op-but-successful compile
        // rather than a hard failure.
        .target(
            name: "OtegamiTranslation",
            dependencies: ["OtegamiCore"]
        ),

        .testTarget(
            name: "OtegamiTranslationTests",
            dependencies: ["OtegamiTranslation"]
        ),

        // `FoundationModelsTranslationService`: the real on-device LLM
        // translator, behind the same `TranslationService` protocol.
        // Apple-only (iOS/macOS 26+), like `MailTransportMailCore`/
        // `GoogleOAuth` — never pulled into any Linux-compatible product,
        // and never imported by `OtegamiTranslation` itself (only the other
        // way around), so a `FoundationModels`-less SDK (or a future Linux
        // build) never needs to resolve this target at all.
        //
        // Task #122: also depends on `OtegamiCore` directly (not just
        // transitively via `OtegamiTranslation`) so `summarize` can call
        // `SummaryOutputSanitizer` — an explicit dependency rather than
        // relying on SwiftPM's transitive module visibility.
        .target(
            name: "OtegamiTranslationFoundationModels",
            dependencies: ["OtegamiTranslation", "OtegamiCore"]
        ),

        // Opt-in like `MailTransportMailCoreTests`: exercises the real
        // on-device model when `SystemLanguageModel.default.isAvailable`,
        // skips (not fails) otherwise — see the test file's doc comment and
        // docs/translation.md for what "available" requires (Apple
        // Intelligence-eligible hardware, the feature turned on, and the
        // on-device model already downloaded).
        .testTarget(
            name: "OtegamiTranslationFoundationModelsTests",
            dependencies: ["OtegamiTranslationFoundationModels", "OtegamiTranslation"]
        ),

        // Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT
        // へ切替): `AppleTranslationService`, backed by `Translation
        // .TranslationSession` — mirrors `OtegamiTranslationFoundationModels`'
        // own doc comment shape (Apple-only, iOS 18+/macOS 15+ here since
        // that's this framework's actual floor, never imported by
        // `OtegamiTranslation` itself). Depends on `OtegamiTranslation` only
        // for the `TranslationOnlyService`/`TranslationLanguage`/
        // `TranslationServiceError` types it conforms to/throws — summarize
        // methods live on `FoundationModelsTranslationService` unchanged,
        // recombined via `OtegamiTranslation`'s own `HybridTranslationService`
        // (not this target, since that composition needs no Apple-only
        // dependency at all).
        .target(
            name: "OtegamiTranslationApple",
            dependencies: ["OtegamiTranslation"]
        ),

        // Task #159: `TranslationLanguage.locale` mapping only — the actual
        // engine needs a live `TranslationSession`, obtainable only via a
        // hosting SwiftUI view's `.translationTask`, which no plain
        // `swift test` process can provide (see the test file's own doc
        // comment for the full reasoning, mirroring
        // `OtegamiTranslationFoundationModelsTests`' real-device gating).
        .testTarget(
            name: "OtegamiTranslationAppleTests",
            dependencies: ["OtegamiTranslationApple", "OtegamiTranslation"]
        ),

        // Cache-aware orchestration that ties `TranslationService` to
        // persistence: `MessageTranslator` (checks `messageTranslation`
        // before calling the engine, writes the result back) and
        // `MessageTranslationState` (the `translationState[messageID]`
        // model the design handoff describes — owned here, not in the app
        // target, so the eventual UI phase only has to observe it). Mirrors
        // `SyncEngine`'s role of gluing a protocol-only target
        // (`MailTransport`) to `OtegamiStore`.
        .target(
            name: "TranslationEngine",
            dependencies: [
                "OtegamiCore",
                "OtegamiStore",
                "OtegamiTranslation",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // `FakeTranslationService`-driven cache/state-transition tests —
        // mirrors `SyncEngineTests`' FakeIMAPSession approach, no real
        // model touched.
        .testTarget(
            name: "TranslationEngineTests",
            dependencies: ["TranslationEngine", "OtegamiStore", "OtegamiTranslation"]
        ),

        // Task #42, point 4「BIMI 対応」: DNS-over-HTTPS BIMI record lookup +
        // safe-subset SVG validation/parsing. Linux-compatible (plain
        // `URLSession`/`Foundation`, no `CoreGraphics`) — like `GoogleOAuth`,
        // this keeps the network/parsing logic unit-testable without a
        // Simulator; the actual pixel rasterization is app-layer-only
        // (`apps/Otegami/Sources/Support/BIMISVGRenderer.swift`, `CoreGraphics`).
        .target(
            name: "BIMI"
        ),

        // `URLProtocol`-stubbed DoH lookup tests, TXT-record/multi-segment
        // reassembly parsing, SVG safety-rejection cases, and the path-data/
        // transform/color parser's pure-function tests. No real DNS or HTTP
        // touched.
        .testTarget(
            name: "BIMITests",
            dependencies: ["BIMI"]
        ),
    ]
)
