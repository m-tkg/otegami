---
name: verify
description: Steps for building, running, and driving Otegami (iOS/macOS SwiftUI mail app) against the dev mailstack to verify behavior against the real app.
---

# Verifying Otegami against the real app

## Dev mail server

```bash
make mailstack-up      # Dovecot (IMAP :1143 plain / :1993 TLS) + Mailpit (SMTP :1025, web UI :8025)
make mailstack-seed     # loads dev/mailstack/seed/fixtures/*.eml (NOT idempotent — reseeding adds duplicates)
make mailstack-down
```

- Accounts: `test1@otegami.test` / `test1234` (4 seeded messages), `test2@otegami.test` / `test1234` (1 seeded message).
- The simulator shares the host's network namespace, so `localhost:1143` from
  the app in-simulator really does reach the host's Docker-published port.
- Seed data lives under `dev/mailstack/data/` (gitignored, bind-mounted into
  the Dovecot container). It's *not* reset by `mailstack-down`/`mailstack-up`
  — only removing that directory does, and that's a destructive operation
  outside normal permissions; don't rely on a clean mailbox across runs.
  Re-seeding on top of old data legitimately produces duplicate rows —
  that's expected, not a bug, and how `MailCoreIMAPSessionIntegrationTests`
  already asserts (`>=`, not `==`, counts).

## Building and running

```bash
make mac      # macOS xcodebuild build
make ios      # iOS Simulator xcodebuild build (IOS_SIMULATOR ?= iPhone 17 Pro Max)
make test     # OtegamiKit swift test (unit + FakeIMAPSession-driven SyncEngine tests)
```

`app-project` (`xcodegen generate`) always runs first via the Makefile; if
you edit `project.yml` directly, regenerate before building from Xcode too.

## Driving the iOS app: XCUITest, not simctl alone

`simctl` can boot/install/launch/screenshot, but it cannot type into fields
or tap by accessibility identifier — there's no simctl "UI automation"
primitive. Every interactive UI element in the app has an
`accessibilityIdentifier` (see `Sources/Features/**`) specifically so an
XCUITest target (`apps/Otegami/UITests/`, scheme target `OtegamiUITests`)
can drive it reliably:

```bash
xcodebuild -project apps/Otegami/Otegami.xcodeproj -scheme Otegami \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:OtegamiUITests test
```

`scripts/verify-ios-m1.sh` wraps the full M1 flow (uninstall for a clean
local DB, build-for-testing, run the UITest, screenshot online, stop the
mailstack, screenshot again to confirm offline persistence, restore the
mailstack). Run it directly rather than reassembling the steps by hand.

## Screenshots (after the UITest, not during it)

The UI test process runs inside the simulator's sandbox — it can't write
PNGs to an arbitrary host path. Don't try to capture screenshots *from
inside* the XCUITest. Instead, after the test run completes (app state —
Keychain password, GRDB database — persists on the simulator regardless of
whether the app process is still alive), drive screenshots from the host
shell:

```bash
xcrun simctl launch --terminate-running-process booted com.m-tkg.otegami
sleep 3   # give the ValueObservation-backed views a moment to render
xcrun simctl io booted screenshot /tmp/otegami-verify/out.png
```

A cold relaunch re-selects the first INBOX automatically (`SidebarView`'s
mailbox observation claims it as the initial selection), so no further
taps are needed just to see the message list.

## Offline verification pattern

Stopping the mail server between two otherwise-identical
launch+screenshot pairs is the whole test: `AppDatabase` never talks to the
network to render a list, only `SyncCoordinator.syncAccount` does, so a
relaunch with `make mailstack-down` already run should produce a
byte-for-byte-identical message list to the "online" screenshot. If it
doesn't, something in a view's `.task` is (incorrectly) blocking initial
render on a network call rather than just reading GRDB.

## Common pitfalls hit while building this skill

- SwiftUI `Picker` inside a `Form` defaults to a push-navigation style on
  iOS; add `.pickerStyle(.menu)` for anything an XCUITest needs to select
  in one tap-tap, no "back" step.
- `XCUIApplication.launch()` always starts a fresh process, but GRDB state
  on disk persists across it — use `xcrun simctl uninstall` before a run if
  you want a truly empty account list, not just a fresh process.
- A `TextField`'s default value (e.g. a port field preset to `"993"`) needs
  explicit clearing in XCUITest (`XCUIKeyboardKey.delete.rawValue` repeated
  per character) before `typeText` — otherwise the typed text is appended,
  not replacing the default.
