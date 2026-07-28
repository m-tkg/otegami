// swift-tools-version:6.0
import PackageDescription

// A standalone SwiftPM package for visually verifying `DesignSystem`
// without touching any existing file in `apps/Otegami/` (this whole
// package lives outside `project.yml`'s `sources:` globs — `Sources` and
// `Resources` only — so it's invisible to `xcodegen`/`make ios`/`make
// mac`). See `Sources/DesignSystemCatalogRenderer/main.swift`'s doc
// comment for what it actually does and why this approach was chosen
// over a simulator launch-argument hook.
//
// `Sources/DesignSystem` in this package is a symlink to
// `../Sources/DesignSystem` (the real design system, compiled into the
// Otegami app target too) — not a copy. SwiftPM refuses a target `path`
// that points outside the package root directly, but happily follows a
// symlink that resolves there, so this builds the *exact* same source
// files as the app does, with no duplication to drift out of sync.
let package = Package(
    name: "DesignSystemCatalog",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DesignSystem", path: "Sources/DesignSystem"),
        .executableTarget(
            name: "DesignSystemCatalogRenderer",
            dependencies: ["DesignSystem"]
        ),
        // Task #72: pure-logic tests for `DesignSystem` code that has no
        // XCTest target anywhere else (the app target only has
        // `OtegamiUITests`, which needs a Simulator). Not wired into
        // `make test` (that only runs `packages/OtegamiKit`) or CI
        // (`ci-app.yml` doesn't touch this package) — run manually with
        // `swift test` from this directory. See
        // `docs/design-system.md`'s "Task #72" section for why this gap
        // exists rather than adding a real Xcode unit-test target.
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"]
        ),
    ]
)
