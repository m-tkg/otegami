// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "otegami-relay",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.25.1"),
    ],
    targets: [
        .executableTarget(
            name: "OtegamiRelay",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "OtegamiRelayTests",
            dependencies: [
                "OtegamiRelay",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
