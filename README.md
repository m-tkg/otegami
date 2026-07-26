# otegami

[![ci-app](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml)
[![ci-server](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml)

**[日本語版 README はこちら / Japanese README](README_ja.md)**

An open-source, offline-first mail client for iOS and macOS. Connects to
your existing Gmail, iCloud, or generic IMAP/SMTP account with a single
sync engine, stores everything locally in SQLite (GRDB) with full-text
search, translates English mail on-device, and can optionally run its own
self-hosted push notification relay.

> **Status: work in progress / experimental.** See the [Status](#status)
> section below before relying on this for real mail.

<p align="center">
  <img src="docs/assets/screenshot-ios-inbox-light.png" width="32%" alt="Unified inbox across two accounts, light mode (iOS)">
  <img src="docs/assets/screenshot-ios-inbox-dark.png" width="32%" alt="Unified inbox, dark mode (iOS)">
  <img src="docs/assets/screenshot-ios-compose.png" width="32%" alt="Composer with per-account sender picker (iOS)">
</p>
<p align="center">
  <img src="docs/assets/screenshot-mac-inbox.png" width="49%" alt="Unified inbox with unread badges (macOS)">
  <img src="docs/assets/screenshot-mac-thread.png" width="49%" alt="Thread view with reply (macOS)">
</p>

## Why otegami

Two things this app is built around, more than any single feature list:

1. **Multiple accounts, one inbox.** Gmail, iCloud, and any IMAP/SMTP
   provider sync through the same engine and show up interleaved in one
   unified inbox, with a tap to filter down to a single account.
2. **On-device translation.** English mail gets translated to Japanese
   (and back, for replies) entirely on-device via Apple's Foundation
   Models framework — no server round-trip, no third-party translation
   API ever sees your mail. See [Translation](#translation) below.

## Features

- **Accounts**: Gmail (OAuth2 + PKCE), iCloud (app-specific password), and
  any generic IMAP/SMTP provider — one unified sync engine underneath.
- **Offline-first**: every message, thread, and flag change lives in a
  local SQLite database first; the app is fully usable with no network,
  and reconnects replay a queue of pending changes (read/unread, delete,
  archive, send) once back online.
- **On-device translation** (Apple Foundation Models, iOS/macOS 26+): an
  inline translation bar on English messages, defaulting to the Japanese
  translation with a one-tap toggle back to the original; long-press a
  single paragraph to peek at just its source text. "Draft a reply in
  English" opens the composer with translate-on-send already armed, and
  the composer itself has an "translate to English before sending"
  toggle that rewrites your Japanese draft in place before it goes out.
  Auto-translate can be turned off in Settings. Nothing leaves the
  device — see [`docs/translation.md`](docs/translation.md) for the
  engine design and its one known Simulator-only limitation.
  Translation is proven working end-to-end (2–5s per call) against the
  real on-device model.
- **Threading**: Gmail `X-GM-THRID` when available, otherwise a JWZ-style
  `References`/`In-Reply-To` union-find with a subject-based fallback,
  batched for fast bulk (re-)threading (100k-message dataset: ~1.4s, see
  [`docs/performance.md`](docs/performance.md)).
- **Unified inbox with account filter chips**: every account's inbox
  interleaved by date behind a "everything" chip, with per-account chips
  to filter down; account color accents and per-mailbox/unified
  unread-count badges throughout.
- **Full-text search**: SQLite FTS5 (trigram tokenizer) for 3+ character
  queries, with a `LIKE` fallback for shorter queries — works for Japanese
  and other scripts with no dictionary/segmenter dependency. Filter chips
  (attachments / unread / English) and People vs. Mail result sections.
- **HTML mail**: rendered in a sandboxed `WKWebView` (JavaScript disabled;
  re-verified against real script-injection fixtures — `<script>` DOM
  rewrites, `onerror` handlers, `iframe`s, `javascript:` links — all
  confirmed inert). A subtle "HTML" badge marks HTML messages, with a
  one-tap switch to a plain-text rendering (or "always show as text" in
  Settings). Messages with no content at all show a subtle "no content"
  placeholder instead of a blank pane. Embedded images (inline `cid:` /
  image attachments) default off; remote images default on with an
  in-Settings note about the read-receipt tradeoff — both have their own
  one-tap "show images" banner as a per-message override. Links can open in
  an in-app browser (default, iOS only) or the system default browser,
  configurable in Settings.
- **Attachments**: send and receive, with QuickLook preview, inline
  `cid:` image support, and RFC 2047/2231-aware filename decoding
  (including Japanese filenames).
- **Compose/reply**: a required sender picker to avoid cross-account
  mistakes, plain-text quoting, an Outbox for offline sends, local draft
  saving (with a save/discard confirmation on both platforms), and
  drafts that sync both ways over IMAP. On iOS, sending is durable and
  cancellable: the message is queued to the local Outbox the instant you
  tap Send (so it's never lost even if the app is killed), then held for
  a configurable 5s/10s/no-delay window behind a countdown bar with a
  "送信を取り消す" (undo send) button — leaving the app finalizes the send
  immediately instead of continuing to count down in the background. See
  [docs/settings.md](docs/settings.md).
- **Templates**: reusable compose snippets, managed in Settings, each
  optionally scoped to one account (unscoped ones are available from
  every account). Insertable from the Composer's "テンプレートを挿入" menu —
  fills both subject and body when starting a blank message, or appends
  to the body otherwise (signature-style).
- **Swipe actions & bulk select**: both left and right swipes have
  independently configurable short/long actions (read/unread toggle,
  archive, mark as junk, pin, delete), a deliberately tap-only delete/junk
  to avoid accidental swipes, long-press multi-select with a bottom
  action bar, and Undo toasts on delete/archive/junk. macOS (no swipe
  gesture) exposes every action via the row's context menu instead.
- **Pinning**: pin a message or thread to keep it at the top of the list,
  local-only by default with an opt-in to mirror IMAP `\Flagged` so it
  stays in sync with other clients.
- **List display**: conversation threading you can switch off (giving a
  flat, one-row-per-message list), a per-account-colored initials avatar next to each
  row and each message's header (generated locally — no third-party
  avatar service is ever contacted), and a configurable body-preview
  line count.
- **Push notifications**: an optional, self-hostable relay server
  (`server/otegami-relay`) watches your IMAP `INBOX` over IDLE and sends a
  privacy-preserving APNs push (no subject/body on the wire — the app's
  Notification Service Extension fetches the real content itself). Fully
  opt-in; the app works identically without one configured. **Verified
  end-to-end on a physical iPhone** — real APNs delivery, correct
  sender/subject after the Notification Service Extension rewrite, and
  clean teardown when disabled — see
  [`docs/relay-deployment.md`](docs/relay-deployment.md).
- **macOS**: native menu bar commands (⌘N new message, ⌘R reply, ⌘⌫
  delete, ⌘⇧F focus search, ⌘]/⌘[ switch mailboxes), a native Settings
  scene, its own compose windows (with the same save/discard-on-close
  confirmation as iOS, including when closed from the titlebar button),
  and the original three-pane `NavigationSplitView` layout.
- **iCloud account sync**: add an account on one device (iOS/macOS, same
  Apple ID) and it appears ready-to-sync on the others — credentials ride
  iCloud Keychain, account metadata (including edits) syncs via
  `NSUbiquitousKeyValueStore`; see
  [docs/icloud-sync.md](docs/icloud-sync.md). Opt-out toggle in Settings.
  Accounts are matched by email/IMAP host/username, not just their internal
  id, so two devices adding "the same" mailbox never produce a duplicate —
  and a device that already has a stale duplicate from before this fix
  self-heals it automatically on next launch, without losing any local
  mail, drafts, or templates.
- **Performance**: tested against a 100k-message synthetic mailbox — see
  [docs/performance.md](docs/performance.md).

## Design

The UI follows a from-scratch design pass (see
[`design_handoff_ios_mail/README.md`](design_handoff_ios_mail/README.md)
for the original wireframe options and
[`docs/design-system.md`](docs/design-system.md) for the resulting token
system): flat, zero-corner-radius, 2pt rules, Archivo for Latin text with
system fonts for Japanese, a pale-blue-on-white palette with a matching
dark theme. iOS uses a bottom tab bar (Mail / Search / Settings) with a
unified inbox, account filter chips, and a folder sheet reached from the
nav title; macOS keeps its three-pane `NavigationSplitView` — the compact
layout doesn't fit the wider screen. Full component/token reference in
[`docs/design-system.md`](docs/design-system.md).

<p align="center">
  <img src="docs/assets/screenshot-ios-search.png" width="32%" alt="Cross-account search with filter chips (iOS)">
  <img src="docs/assets/screenshot-ios-settings.png" width="32%" alt="Settings: accounts, swipe actions, translation (iOS)">
</p>

## Translation

otegami translates English mail to Japanese entirely on-device using
Apple's Foundation Models framework (`LanguageModelSession`) — the same
on-device model behind Apple Intelligence, so no mail content is ever
sent to a translation API or any server. Highlights:

- Per-message translation bar, defaulting to the translated text, with a
  segmented control back to the original and per-paragraph long-press to
  peek at just that paragraph's source.
- "Draft a reply in English" and a composer-side "translate to English
  before sending" toggle that translates your own draft in place (so you
  can see and edit the result before sending, never a silent background
  translation).
- Paragraph-level caching keyed by an engine identifier, so re-opening a
  translated message doesn't re-run the model.
- Requires iOS/macOS 26+ with Apple Intelligence enabled. On unsupported
  devices/OS versions the translation UI degrades gracefully and the
  app is otherwise unaffected.

Engine design, the 23 supported languages, context-window limits, and one
known limitation (translation calls made from inside the iOS Simulator's
sandboxed `.app` process reliably fail with
`FoundationModels.LanguageModelError -1`, while the identical code
succeeds every time from a plain `swift test` process on the same
machine — a Simulator/toolchain quirk, not a code bug; real-device
confirmation is the outstanding item in
[PENDING.md](PENDING.md)) are documented in
[`docs/translation.md`](docs/translation.md).

## Status

Feature-complete through the M11 milestone (accounts, sync, threading,
search, attachments, compose/reply/drafts, push relay, iCloud account
sync, macOS polish, performance work) plus a full design refresh and
on-device translation, with an automated test/verification suite
(`make test`, the `scripts/verify-*.sh` checkpoints) that's green. Push
notifications have been verified end-to-end against a physical iPhone
(real APNs delivery via a self-hosted relay). That said, this is a solo,
AI-assisted side project, not yet published to the App Store or used as
anyone's daily driver for an extended period — treat it as experimental:

- A few things are only verified against unit tests, mocks, the local dev
  mail stack, or a single simulator so far, not fully against real
  accounts/devices: real-account Gmail and iCloud sign-in end to end, a
  real two-physical-device iCloud account sync round trip, and on-device
  translation driven through the iOS Simulator's app UI (works from a
  plain process on the same machine; see [Translation](#translation)
  above). See [PENDING.md](PENDING.md) for exactly what's unverified,
  why, and the steps to verify it with your own credentials/devices.
- [docs/roadmap.md](docs/roadmap.md) covers planned future work.

## Platforms

iOS 26+ and macOS 26+, single SwiftUI codebase (`apps/Otegami`, a
multiplatform Xcode target). Swift 6, strict concurrency throughout.

## Building

Requires Xcode with the iOS 26 / macOS 26 SDKs (Xcode 26 or later), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode
project — install the latter first:

```sh
brew install xcodegen
```

```sh
make mac          # macOS app, debug build (xcodebuild)
make mac-app       # macOS app, Release build bundled to dist/Otegami.app
make ios           # iOS Simulator build (IOS_SIMULATOR ?= "iPhone 17 Pro Max")
make ios-device    # iOS device build, signed with the registered team
make test          # OtegamiKit unit tests (packages/OtegamiKit)
```

Opening `apps/Otegami/Otegami.xcodeproj` in Xcode after `xcodegen generate`
(run automatically by every `make` target above) also works for day-to-day
development.

### Signing

`apps/Otegami/Config/Signing.xcconfig` ships with no `DEVELOPMENT_TEAM` (an
OSS repo can't commit the author's). `make ios` (Simulator) and `make mac`
build fine as-is — Simulator doesn't enforce provisioning, and `make mac`
falls back to an unsigned build when there's no `Local.xcconfig`, same as
CI. For `make ios-device` (a real device), a fully signed `make mac` (App
Group/Keychain sharing with the Notification Service Extension actually
working), or push notifications, copy `Config/Local.xcconfig.sample` to the
untracked `Config/Local.xcconfig` and set your own `DEVELOPMENT_TEAM`
there. You only need to also override `OTEGAMI_BUNDLE_ID` if the default
`com.mtkg.otegami` is already registered as an App ID under someone
else's team (Apple doesn't allow two teams to register the same explicit
App ID) — see the comments in `Config/Local.xcconfig.sample`.

### Gmail OAuth

The OSS build ships with no Google OAuth Client ID (it can't be
committed). Without one, the "Gmail" account-type button is disabled but
everything else works. See [docs/oauth-setup.md](docs/oauth-setup.md) to
issue your own (no Google review needed for personal/dev use).

## Development mail stack

A local Dovecot (IMAP) + Mailpit (SMTP + web UI) stack is included (via
Docker Compose — install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
or another Docker Compose-compatible runtime first), so you don't need a
real mail account to work on sync/send code:

```sh
make mailstack-up     # start Dovecot + Mailpit
make mailstack-seed   # load sample messages (Japanese + English fixtures)
make mailstack-down   # stop the stack
```

Test accounts: `test1@otegami.test` / `test1234` and `test2@otegami.test` /
`test1234` on `localhost:1143` (plain IMAP) / `localhost:1025` (plain
SMTP, via [Mailpit](https://github.com/axllent/mailpit)'s web UI at
`http://localhost:8025`). See [docs/dev-mailstack.md](docs/dev-mailstack.md).

## Testing / verification

```sh
make test                      # OtegamiKit unit tests (fast, no simulator)
scripts/verify-ios-m1.sh       # ...through verify-ios-m9.sh, plus
                                # verify-ios-icloud.sh / -account-edit.sh /
                                # -drafts-sync.sh / -push-simulated.sh /
                                # verify-macos-qa.sh / verify-qa-sweep-offline.sh:
                                # automated XCUITest checkpoints per
                                # milestone/feature, driven against the dev
                                # mail stack
scripts/verify-relay.sh        # otegami-relay end-to-end (real IMAP IDLE
                                # → push) verification
```

See [docs/verify.md](docs/verify.md) for what each checkpoint covers and
`.claude/skills/verify/SKILL.md` for the automated-verification approach
this project follows (screenshots + XCUITest, judged by an agent, not a
human in the loop).

## Push notification relay (optional)

`server/otegami-relay` is a self-hostable Swift/Hummingbird 2 server that
watches your IMAP `INBOX` over IDLE and forwards new-mail events to APNs.
It never sees your mail's subject or body — only `accountId`/`uidNext`
cross the wire; the app's Notification Service Extension fetches the real
sender/subject itself over your own IMAP connection.

```sh
make server        # build otegami-relay
make server-test    # run its test suite
make relay-docker   # build the Docker image
```

See [docs/relay-deployment.md](docs/relay-deployment.md) for deployment
(Docker Compose, APNs `.p8` key, HTTPS termination, including a
private-CA/home-server example) and the app-side opt-in flow.

## Architecture

- `apps/Otegami/` — the SwiftUI app (iOS + macOS), XcodeGen `project.yml`.
- `packages/OtegamiKit/` — a Swift package with the platform-independent
  core: `OtegamiCore` (models, threading), `MailTransport` (protocol
  abstraction over IMAP/SMTP), `MailTransportMailCore` (the MailCore2
  adapter), `OtegamiStore` (GRDB schema/queries/FTS), `SyncEngine` (sync
  coordination, offline op queue), `GoogleOAuth`, `PushRelayClient`,
  `OtegamiRelayAPI` (DTOs shared with the server), `OtegamiTranslation` /
  `OtegamiTranslationFoundationModels` / `TranslationEngine` (the
  on-device translation stack — protocol, Apple implementation, and
  cache/orchestration layers, kept separate so the server and non-Apple
  targets never pull in `FoundationModels`).
- `server/otegami-relay/` — the push relay (Hummingbird 2, Linux-friendly).
- `dev/mailstack/` — the Dovecot + Mailpit dev stack.

See [docs/build-mailcore2.md](docs/build-mailcore2.md) for how the
MailCore2 dependency is vendored, and [docs/performance.md](docs/performance.md)
for the 100k-message performance pass (query indexes, pagination, measured
numbers).

## Contributing

Issues and pull requests are welcome — bug reports, questions, and small
fixes especially. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, how to run tests, and commit/PR conventions. For
security vulnerabilities, see [SECURITY.md](SECURITY.md) instead of
opening a public issue.

## License

MIT — see [LICENSE](LICENSE).

### Third-party licenses

Otegami depends on several third-party open source packages via Swift
Package Manager (GRDB.swift, a MailCore2 fork and its own C dependencies,
Hummingbird, SwiftNIO, swift-crypto, and others) and bundles the Archivo
typeface (SIL Open Font License) — see [NOTICE](NOTICE) for the full
list, license types, and copyright attributions.
