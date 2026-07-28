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
  archive, send) once back online. Archiving is provider-aware: Gmail has
  no real "Archive" folder, so archiving there un-labels the message from
  the source mailbox (Gmail keeps it in "All Mail" automatically) instead
  of moving it; other providers move it to (or auto-create) an Archive
  mailbox.
- **On-device translation and AI summary** (Apple Foundation Models,
  iOS/macOS 26+): an inline translation bar, shown when a message's
  detected language differs from the app's own display language — but
  translation only ever runs when you tap "Translate" (auto-translate
  defaults **off**; turn it back on in Settings). Once translated, a
  one-tap toggle switches back to the original. Plain-text messages let
  you long-press a single paragraph to peek at just its source text; HTML
  messages are translated in place, keeping tables/images/layout intact.
  A separate "AI summary" bar (any message, any language) generates a
  short on-device summary on tap. "Draft a reply in English" opens the
  composer with translate-on-send already armed. Nothing leaves the
  device — see [`docs/translation.md`](docs/translation.md) for the
  engine design and its one known Simulator-only limitation. Translation
  is proven working end-to-end (2–5s per call) against the real
  on-device model.
- **Threading**: Gmail `X-GM-THRID` when available, otherwise a JWZ-style
  `References`/`In-Reply-To` union-find with a subject-based fallback,
  batched for fast bulk (re-)threading (100k-message dataset: ~1.4s, see
  [`docs/performance.md`](docs/performance.md)).
- **Unified inbox with account filter chips**: every account's inbox
  interleaved by date behind a "everything" chip, with per-account chips
  to filter down; account color accents and per-mailbox/unified
  unread-count badges throughout. Each account's color is auto-assigned
  (deterministic per account id) but can be overridden from a fixed
  8-color palette in that account's edit screen — the pick syncs across
  devices via iCloud like the rest of the account's connection settings.
- **App icon badge**: the unified inbox's unread count on the app icon
  (on by default, toggle in Settings), kept live by the same sync/read
  observation the in-app unread counts use; a push notification bumps it
  immediately, self-correcting to the real count on the next sync.
- **Full-text search**: SQLite FTS5 (trigram tokenizer) for 3+ character
  queries, with a `LIKE` fallback for shorter queries — works for Japanese
  and other scripts with no dictionary/segmenter dependency. Filter chips
  (attachments / unread / English) and People vs. Mail result sections.
- **HTML mail**: rendered in a sandboxed `WKWebView` (JavaScript disabled;
  re-verified against real script-injection fixtures — `<script>` DOM
  rewrites, `onerror` handlers, `iframe`s, `javascript:` links — all
  confirmed inert). Fixed-width table layouts (600-800px-class marketing/
  notification mail, e.g. a bank payment notice) are scaled to fit the
  screen width instead of clipping at the right edge or rendering with
  oversized text. A subtle "HTML" badge marks HTML messages, with a
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
- **Calendar invites**: a Google Calendar-style invite email (a
  `text/calendar; method=REQUEST` MIME part) shows an invite card — title,
  time (converted to your device's timezone), location, organizer — with
  Accept/Decline/Maybe buttons. Tapping one sends a standard iTIP
  `METHOD:REPLY` back to the organizer, the same mechanism any calendar
  client uses, so Google Calendar updates your RSVP without needing any
  calendar API access or OAuth scope. See
  [docs/calendar-invites.md](docs/calendar-invites.md).
- **Compose/reply**: a required sender picker to avoid cross-account
  mistakes, plain-text quoting, an Outbox for offline sends, local draft
  saving (with a save/discard confirmation on both platforms), and
  drafts that sync both ways over IMAP. Attachments (files, photos, and —
  on a real iOS device — a camera capture) share a single "Attach" menu.
  On iOS, sending is durable and
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
- **Signature templates**: a separate feature from the templates above —
  each signature can be assigned to *multiple* accounts, and each account
  can have a default signature that's automatically appended when
  composing a brand-new message (not for replies/forwards, to avoid
  racing their own quoted-content prefill). Managed in Settings →
  "署名テンプレート"; the Composer's "署名" picker lets you switch or clear
  it manually at any time, replacing exactly what the previous pick
  inserted.
- **Default sending account**: choose which account the Composer
  preselects for a brand-new message in Settings → "アカウントの設定"
  (replies/forwards always use the original message's own account,
  regardless of this setting).
- **`mailto:` links and default mail app**: otegami registers the
  `mailto` scheme (`CFBundleURLTypes`) on both platforms, so tapping/
  clicking a `mailto:` link opens the Composer prefilled with the
  decoded to/cc/bcc/subject/body (RFC 6068). On macOS this alone makes
  otegami selectable as the default mail reader (Mail.app's own
  Settings → General, or System Settings → Desktop & Dock). On iOS,
  actually becoming the system-wide default additionally requires
  Apple's `com.apple.developer.mail-client` entitlement, which is a
  build-time opt-in flag (off by default so the app builds and archives
  without it) — see [docs/default-mail-app.md](docs/default-mail-app.md).
- **Configurable post-delete/archive behavior**: from the message view's
  "…" menu, deleting/archiving/marking as junk can either return to the
  list (default) or automatically open the next message in the current
  list order — configurable in Settings → "メールビューア".
- **Swipe actions & bulk select**: both left and right swipes have
  independently configurable short/long actions (read/unread toggle,
  archive, mark as junk, pin, delete), a deliberately tap-only delete/junk
  to avoid accidental swipes, long-press multi-select with a bottom
  action bar, and Undo toasts on delete/archive/junk. macOS (no swipe
  gesture) exposes every action via the row's context menu instead.
- **Pinning**: pin a message or thread to keep it at the top of the list,
  local-only by default with an opt-in to mirror IMAP `\Flagged` so it
  stays in sync with other clients.
- **List display**: card-style rows (rounded corners, no outline — just
  the surface color and spacing separate one card from the next) across
  the unified inbox, per-mailbox lists, and search results; timestamps
  read like a typical mail client (time only for today, date + time
  otherwise). Conversation threading you can switch off (giving a flat,
  one-row-per-message list), and a per-sender avatar next to each row and
  each message's header. The avatar prefers, in order: a matching photo
  from your on-device Contacts (looked up via the Contacts framework —
  nothing ever leaves the device), a Gravatar image (looked up by a
  SHA-256 hash of the sender's address sent to gravatar.com), a company
  logo resolved from the sender's domain favicon (free-mail domains like
  Gmail/iCloud are excluded so they never get treated as one company's
  logo), then falls back to initials on a per-account color. Each
  network-touching source can be turned off independently in Settings →
  Mail List. A configurable
  body-preview line count. A thread's collapsed rows show the same
  avatar/preview treatment, styled distinctly (a softer tint, no card
  background) so they read as "inside one thread" rather than the
  top-level list.
- **Thread reading, platform-appropriate**: on iOS, tapping a thread with
  2+ messages opens a selection screen first (one row per message, same
  icon/preview/time treatment as the list) — picking one pushes straight
  to that single message's body, with no accordion/stack on screen at
  all; a 1-message thread skips the selection screen entirely. macOS's
  wider 3-pane layout keeps the original strict accordion instead —
  exactly one message expanded at a time, tapping another message's
  header collapses whatever was open and expands that one instead, with
  the expanded row visually highlighted (an accent-colored rail, like the
  account-color rail in the list). Either way, the message footer
  toolbar's Reply/Forward/Search/Info always act on whichever message is
  currently shown/expanded.
- **Display language**: choose "Match System", Japanese, or English in
  Settings — the app UI itself is localized via a String Catalog, covering
  the great majority of screens (list, message view, compose, search, the
  hamburger menu, every Settings screen including account setup/edit
  forms, templates, signatures, and push notifications). Applying a
  change requires a full quit-and-relaunch, not just returning to the
  Home Screen (backgrounding doesn't restart the process) — the app
  offers a "Quit Now" button right after you pick a language to make that
  unambiguous. See [docs/localization.md](docs/localization.md) for exact
  coverage and the mechanism.
- **Settings, reorganized into five categories**: Account Settings
  (add/remove accounts, default sending account), Mail Viewer (link
  browser, post-delete/archive behavior, AI features on/off), Mail List
  (avatars, preview lines, swipe actions), Signature Templates, and Other
  (everything else — threading, pinning, send-cancel window, images, HTML
  display, language, templates, iCloud sync, push notifications, app icon
  badge, about). Same structure on iOS (hamburger menu → Settings) and
  macOS (native Settings scene).
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
  mail, drafts, or templates. If that merge ever picks a survivor with no
  working credential (e.g. its password ended up orphaned in the Keychain
  under the merged-away account), the app detects and re-attaches it
  automatically too, whenever it's unambiguous which credential belongs to
  which account.
- **Performance**: tested against a 100k-message synthetic mailbox — see
  [docs/performance.md](docs/performance.md).

## Design

The UI follows a from-scratch design pass (see
[`design_handoff_ios_mail/README.md`](design_handoff_ios_mail/README.md)
for the original wireframe options and
[`docs/design-system.md`](docs/design-system.md) for the resulting token
system): flat, zero-corner-radius, 2pt rules, Archivo for Latin text with
system fonts for Japanese, a pale-blue-on-white palette with a matching
dark theme. iOS has a single always-visible mail screen (unified inbox +
account filter chips + an unread-only toggle) with a hamburger-menu drawer
for folder navigation and settings — folders group by category by default
(Inbox/Archive/Sent/Drafts/... sections, each account listed inside, plus
an "all accounts" cross-account row per category), switchable back to the
original per-account tree via a segmented control — a floating search
button (bottom-left)
that opens a dedicated search screen (account chips, `from:`/`to:`/`cc:`/
`subject:` search operators, search history), pull-to-refresh for
resyncing, and a fixed footer toolbar on the message screen (reply/forward/
search-from-sender/message info/more — mute, pin, archive, junk, delete,
toolbar reordering); macOS keeps its three-pane `NavigationSplitView` — the
compact layout doesn't fit the wider screen. Full component/token
reference in [`docs/design-system.md`](docs/design-system.md).

<p align="center">
  <img src="docs/assets/screenshot-ios-search.png" width="32%" alt="Cross-account search with account filter chips and search operators (iOS)">
  <img src="docs/assets/screenshot-ios-thread-toolbar.png" width="32%" alt="Message screen with the footer toolbar: reply, forward, search, info, more (iOS)">
  <img src="docs/assets/screenshot-ios-settings.png" width="32%" alt="Settings: accounts, swipe actions, translation (iOS)">
</p>

## Translation

otegami translates English mail to Japanese entirely on-device using
Apple's Foundation Models framework (`LanguageModelSession`) — the same
on-device model behind Apple Intelligence, so no mail content is ever
sent to a translation API or any server. Highlights:

- Per-message translation bar, shown for English mail but only ever
  translating when you tap "Translate" (auto-translate defaults off —
  flip it back on in Settings). Once translated, a segmented control
  switches back to the original. Plain-text messages support a
  per-paragraph long-press to peek at just that paragraph's source; HTML
  messages translate in place, preserving tables/images/layout instead of
  falling back to a plain-text rendering.
- "Draft a reply in English" opens the composer with translate-on-send
  already armed, translating your own reply draft in place (so you can
  see and edit the English result before it's sent, never a silent
  background translation). This is the only entry point for it — an
  earlier, more general "translate to English before sending" toggle that
  any compose screen exposed was removed in favor of this single,
  intentional entry point.
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
  why, and the steps to verify it with your own credentials/devices —
  or [HUMAN_TASKS.md](HUMAN_TASKS.md) for the same list reorganized as a
  plain action checklist (real-device checks, real-account sign-ins,
  infra upkeep, release prerequisites).
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

`make deploy-ota` builds an Ad Hoc `.ipa` and publishes it for OTA install
on a registered device over your own reverse proxy — see
[docs/ota-deploy.md](docs/ota-deploy.md).

Otegami also builds on Xcode Cloud for TestFlight distribution
(`apps/Otegami/ci_scripts/ci_post_clone.sh` regenerates the XcodeGen
project and injects per-builder config from workflow environment
variables) — see [docs/xcode-cloud.md](docs/xcode-cloud.md) for the setup
steps and known caveats (export compliance, APNs sandbox vs. production,
Google OAuth's unverified-app warning for testers).

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
