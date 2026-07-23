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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
            dependencies: ["MailTransport", "OtegamiStore"]
        ),

        // DTOs shared between the app and the push relay server. Linux-compatible.
        .target(
            name: "OtegamiRelayAPI",
            dependencies: ["OtegamiCore"]
        ),

        // MailCore2-backed adapter for MailTransport. Apple-only. MailCore2 is
        // not wired in yet (M0 placeholder); see scripts/build-mailcore2.sh.
        .target(
            name: "MailTransportMailCore",
            dependencies: ["MailTransport"]
        ),

        .testTarget(
            name: "OtegamiCoreTests",
            dependencies: ["OtegamiCore"]
        ),
    ]
)
