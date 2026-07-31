# otegami

[![ci-app](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-app.yml)
[![ci-server](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml/badge.svg)](https://github.com/m-tkg/otegami/actions/workflows/ci-server.yml)

An offline-first, open-source mail client for iOS and macOS. Otegami
connects to Gmail, iCloud, Yahoo! Mail (including Yahoo! Mail JAPAN),
Outlook.com/Office365, and any other IMAP/SMTP account through a single
sync engine, stores everything locally in SQLite (GRDB) with full-text
search, translates and summarizes English mail on-device, and can
optionally run its own self-hosted push notification relay.

iOS 26+ / macOS 26+, a single SwiftUI codebase. 日本語版 README:
[README_ja.md](README_ja.md).

> **Status: in development, experimental.** Read [Status](#status) below
> before trusting it with real mail.

<p align="center">
  <img src="docs/assets/screenshot-ios-inbox-light.png" width="32%" alt="Unified inbox, light mode (iOS)">
  <img src="docs/assets/screenshot-ios-inbox-dark.png" width="32%" alt="Unified inbox, dark mode (iOS)">
  <img src="docs/assets/screenshot-ios-compose.png" width="32%" alt="Composer with sender picker (iOS)">
</p>
<p align="center">
  <img src="docs/assets/screenshot-mac-inbox.png" width="49%" alt="Unified inbox with unread badges (macOS)">
  <img src="docs/assets/screenshot-mac-thread.png" width="49%" alt="Thread view and reply (macOS)">
</p>

## What otegami focuses on

Ahead of the feature list, two things this app is built around:

1. **Multiple accounts in one inbox.** Every supported account type runs
   on the same sync engine and lands in one unified inbox, sorted by
   date. Tap a chip to filter down to a single account, or use the
   per-account digest view to see everything at once.
2. **On-device translation and summarization.** English mail is
   translated to Japanese and summarized on-device via Apple's Foundation
   Models framework (replies can be translated back to English too). See
   [AI summary & translation](#ai-summary--translation) below.

## Supported accounts

- **Gmail** — OAuth2 (Authorization Code + PKCE)
- **iCloud** — app-specific password
- **Yahoo! Mail / Yahoo! Mail JAPAN** — a dedicated setup form with
  host/port/security pre-filled
- **Outlook.com / Office365** — Microsoft OAuth2 (Authorization Code +
  PKCE)
- **Exchange** — preset on top of the generic IMAP form
- **Any other IMAP/SMTP provider**

Gmail and Outlook/Office365 each require you to register your own OAuth
Client ID (the button is simply disabled if it's not configured — every
other feature works fine without it). See
[docs/oauth-setup.md](docs/oauth-setup.md).

## Features

- **Unified inbox**: an "All" chip mixes every account's mail by date,
  plus per-account filter chips. Account-color accents and per-mailbox /
  unified unread badges. An "unread only" toggle. The "Group by account"
  button switches to a digest view (one row per account: color stripe,
  display name, unread/count badge, a preview of the 2-3 most recent
  messages; tap to filter to that account, swipe for bulk actions).
  Account colors are auto-assigned or can be overridden from a fixed
  8-color palette, and sync to other devices via iCloud.
- **Offline-first**: message, thread, and flag changes land in local
  SQLite first. The app works with no network and replays queued
  operations (read/unread, delete, archive, send) automatically on
  reconnect. Archive behavior is tuned per provider (Gmail just removes
  the label; everyone else moves the message to an Archive mailbox).
- **Avatars**: per-sender avatars, resolved in order from device contact
  photos, external image sources, sender-domain logos, then initials.
  Sources that make network requests can be disabled individually in
  Settings → "Message List".
- **Full-text search**: SQLite FTS5 for queries of 3+ characters (shorter
  queries fall back to `LIKE`). Supports `from:`/`to:`/`cc:`/`subject:`
  search operators, account filter chips, recent search history, and
  **saved searches** (a search screen with History/Saved tabs).
- **Threading**: Gmail uses `X-GM-THRID`; everyone else uses
  `References`/`In-Reply-To` JWZ-style union-find plus a subject
  fallback. The message view is an accordion (every message in the
  thread listed chronologically, only the latest expanded, tap a header
  to expand a different one) shared by iOS and macOS. The list shows a
  count badge on multi-message threads.
- **Collapsible quote history**: plain-text replies break quoted
  history into individual per-message cards, toggleable with "Show/hide
  history" (shown by default; HTML mail is out of scope).
- **AI summary & translation**: see [below](#ai-summary--translation).
- **HTML mail**: rendered in a sandboxed `WKWebView` (JavaScript
  disabled). Fixed-width marketing/notification tables are scaled to fit
  the screen, with a one-tap "HTML" badge to switch to plain text.
  Embedded images are off by default, remote images on by default, both
  overridable per-message with a "Show images" banner. In-body links can
  open in an in-app browser (default, iOS only) or the system default
  browser.
- **View source**: fetch and cache the raw RFC822 source of a message
  on demand, for inspecting mail that renders incorrectly.
- **Attachments**: send/receive, QuickLook preview, inline `cid:`
  images, RFC 2047/2231 filename decoding (including Japanese
  filenames).
- **Calendar invites**: detects `text/calendar; method=REQUEST` and
  shows an invite card (title, time, location, organizer); Accept/
  Decline/Tentative sends a standard iTIP `METHOD:REPLY` back to the
  organizer. See [docs/calendar-invites.md](docs/calendar-invites.md).
- **Compose/reply/forward**: sender selection is required, plain-text
  quoting, an offline-capable Outbox, draft save/discard confirmation
  with two-way IMAP sync. iOS sends go through the Outbox immediately
  with a configurable 5s/10s/none grace period and an undo button.
  Templates (canned body text) and signature templates (a default
  signature per account) are both managed from Settings.
- **Swipe actions, bulk select, pin**: each of the four swipe directions
  (short/long × left/right) can be assigned read/unread, archive, spam,
  pin, or delete independently. Delete and spam always require a tap to
  confirm. Long-press enters bulk-select mode with a bottom action bar;
  delete/archive/spam show an undo toast. Pins default to local-only but
  can be linked to the IMAP `\Flagged` flag. macOS uses a row context
  menu instead of swipes.
- **Message footer toolbar**: reply/forward/search/info/more (mute, pin,
  archive, spam, delete, summarize, translate, view source, and more —
  14 actions total), with visibility and order customizable in Settings.
- **Display language**: Japanese/English are localized (String
  Catalog). Language switching is delegated to iOS's standard Settings →
  This App → Language (there is no in-app picker). See
  [docs/localization.md](docs/localization.md).
- **Settings**: organized into four categories — Accounts, Message
  Viewer, Message List, Compose — plus About. Full item list in
  [docs/settings.md](docs/settings.md).
- **Push notifications**: an optional, self-hostable relay server
  (`server/otegami-relay-go`) watches IMAP `INBOX` over IDLE and sends
  privacy-conscious APNs pushes that carry no subject/body (actual
  content is fetched by the Notification Service Extension over its own
  IMAP connection). Fully opt-in — the app works the same without it. See
  [docs/relay-deployment.md](docs/relay-deployment.md). The app icon can
  also show an unread badge, toggleable in Settings.
- **iCloud account sync**: accounts added on one device automatically
  appear on other devices signed into the same Apple ID and start
  syncing right away (mail bodies themselves are synced independently by
  each device over its own IMAP connection — iCloud only syncs
  credentials and account metadata). See
  [docs/icloud-sync.md](docs/icloud-sync.md); opt-out available in
  Settings.
- **macOS**: right-click context menus (message list rows, thread
  messages, drafts), native menu bar commands (⌘N new, ⌘R reply, ⇧⌘R
  reply all, ⇧⌘F forward, ⌘E archive, ⇧⌘U toggle read/unread, ⌘⌫
  delete, ⌘F focus search, ⌘]/⌘[ switch mailbox), a native Settings
  scene, a standalone compose window, and a 3-pane
  `NavigationSplitView` layout.
- **Performance**: validated against a synthetic 100k-message mailbox —
  see [docs/performance.md](docs/performance.md).

## Design

The UI is a from-scratch design: flat, zero corner radius, 2pt borders,
Archivo for Latin text / system font for Japanese, a pale-blue-tinted
light theme with a matching dark theme. See
[`docs/design-system.md`](docs/design-system.md) for the adopted
information architecture and how design tokens are used.

- **iOS (compact width, iPhone)**: a single persistent screen — unified
  inbox, account filter chips, and an unread-only toggle. A top-left
  hamburger menu (drawer) handles folder switching and Settings, a
  bottom-left floating search button opens Search, and a fixed footer
  toolbar on the message screen handles reply/forward/etc. There is no
  bottom tab bar.
- **iOS (regular width, iPad, etc.)**: 2-pane — list on the left, detail
  on the right (`MailScreenView`'s size-class branch).
- **macOS**: the classic 3-pane `NavigationSplitView`.

<p align="center">
  <img src="docs/assets/screenshot-ios-search.png" width="32%" alt="Cross-account search, filter chips, and search operators (iOS)">
  <img src="docs/assets/screenshot-ios-thread-toolbar.png" width="32%" alt="Message footer toolbar: reply, forward, search, info, more (iOS)">
  <img src="docs/assets/screenshot-ios-settings.png" width="32%" alt="Settings: accounts, swipe actions, translation (iOS)">
</p>

## AI summary & translation

Summarization and translation run on-device via Apple's Foundation
Models framework (`LanguageModelSession`) — iOS/macOS 26+, requires a
device with Apple Intelligence enabled. The related UI collapses
automatically on unsupported devices.

- **AI summary**: a one-tap, per-message summary structured as
  Summary / What they want / Action items. Reply mail excludes quoted
  history from the summary target, covering only the new body text. A
  "summarize in more detail" option regenerates a longer version.
- **Translation**: a translate button on English mail (always tappable
  once the body has loaded). Auto-translate is off by default; even when
  enabled it only fires on high-confidence English mail. One tap returns
  to the original while a translation is shown. Plain text can be
  checked paragraph-by-paragraph against the original; HTML mail keeps
  its tables/images/layout and translates only the text. Paragraph-level
  caching means re-translating is instant.

Engine design, supported languages, and known limitations (calling
Foundation Models from an iOS Simulator `.app` process fails with
`FoundationModels.LanguageModelError -1`, while the same call from a
`swift test` process on the same machine succeeds — a
Simulator/toolchain limitation, not an app bug) are documented in
[`docs/translation.md`](docs/translation.md).

## Usage

For a walkthrough of adding accounts, using the viewer, search, and
settings, see [docs/usage.md](docs/usage.md).

## Status

This is a personal, AI-assisted side project developed while keeping the
automated test/verification suite (`make test`, the `scripts/verify-*.sh`
checkpoints) green. It hasn't been published on the App Store or used as
anyone's daily driver for an extended period yet. Some behavior (real
account sign-in, two-device iCloud account sync round-trips, etc.) can't
be fully exercised by simulator-based automated tests and needs
confirmation on real accounts/devices — known limitations for each
feature are documented in the relevant `docs/*.md`. See
[docs/roadmap.md](docs/roadmap.md) for planned work.

## Getting started

```sh
brew install xcodegen   # needed to generate the Xcode project
make mac                 # macOS app (debug build)
make ios                 # iOS Simulator build
make test                # OtegamiKit unit tests
```

Requires Xcode (iOS 26 / macOS 26 SDK, Xcode 26+). For device builds,
Gmail/Outlook OAuth, the dev mail stack (Dovecot + Mailpit), and
screenshot-based screen verification via `scripts/verify-screen.sh`, see
[docs/development-setup.md](docs/development-setup.md).

## Testing / verification

```sh
make test               # OtegamiKit unit tests (fast, no simulator)
scripts/verify-screen.sh <scenario> [output.png]  # tap-free screenshots
scripts/verify-relay.sh                            # otegami-relay E2E check
```

See [docs/verify.md](docs/verify.md) for what each checkpoint covers and
known simulator instabilities, and `.claude/skills/verify/SKILL.md` for
the automated-verification approach used in this project.

## Architecture

- `apps/Otegami/` — the SwiftUI app (iOS + macOS), XcodeGen
  `project.yml`.
- `packages/OtegamiKit/` — platform-independent core: `OtegamiCore`
  (models, threading), `MailTransport`/`MailTransportMailCore`
  (IMAP/SMTP, MailCore2 adapter), `OtegamiStore` (GRDB schema/queries/
  FTS), `SyncEngine` (sync + offline operation queue),
  `GoogleOAuth`/`MicrosoftOAuth`, `PushRelayClient`, `OtegamiRelayAPI`
  (DTOs shared with the server), `OtegamiTranslation`/
  `OtegamiTranslationFoundationModels`/`TranslationEngine` (the
  on-device translation/summarization stack).
- `server/otegami-relay-go/` — the push relay (Go).
- `dev/mailstack/` — the Dovecot + Mailpit development stack.

For module dependency direction, sync engine design, and known pitfalls,
see [docs/architecture.md](docs/architecture.md); for how the MailCore2
dependency is vendored, see
[docs/build-mailcore2.md](docs/build-mailcore2.md); for performance
testing, see [docs/performance.md](docs/performance.md).

## Documentation

**Usage & features**
- [docs/usage.md](docs/usage.md) — feature-by-feature usage guide
- [docs/architecture.md](docs/architecture.md) — monorepo layout, sync engine design, known pitfalls
- [docs/design-system.md](docs/design-system.md) — the UI design system
- [docs/settings.md](docs/settings.md) — full settings reference
- [docs/translation.md](docs/translation.md) — on-device translation/summarization engine design
- [docs/calendar-invites.md](docs/calendar-invites.md) — calendar invite handling
- [docs/icloud-sync.md](docs/icloud-sync.md) — iCloud account settings sync
- [docs/default-mail-app.md](docs/default-mail-app.md) — default mail app support
- [docs/roadmap.md](docs/roadmap.md) — planned work

**Development**
- [docs/development-setup.md](docs/development-setup.md) — dev environment setup
- [docs/dev-mailstack.md](docs/dev-mailstack.md) — the dev mail stack (Dovecot + Mailpit)
- [docs/build-mailcore2.md](docs/build-mailcore2.md) — how the MailCore2 dependency is sourced
- [docs/localization.md](docs/localization.md) — app UI localization
- [docs/performance.md](docs/performance.md) — performance testing
- [docs/verify.md](docs/verify.md) — verification steps and known simulator instabilities
- [docs/ci.md](docs/ci.md) — CI (GitHub Actions) setup and known pitfalls

**Auth & distribution**
- [docs/oauth-setup.md](docs/oauth-setup.md) — Gmail/Microsoft OAuth setup
- [docs/relay-deployment.md](docs/relay-deployment.md) — deploying the push relay
- [docs/release.md](docs/release.md) — release via git tag push (TestFlight/GitHub Release)
- [docs/xcode-cloud.md](docs/xcode-cloud.md) — Xcode Cloud / TestFlight distribution
- [docs/ota-deploy.md](docs/ota-deploy.md) — OTA (Ad Hoc) distribution

## Contributing

Issues and pull requests are welcome — bug reports, questions, and small
fixes especially. See [CONTRIBUTING.md](CONTRIBUTING.md) for dev
environment setup, how to run tests, and commit/PR conventions. Report
security vulnerabilities through [SECURITY.md](SECURITY.md) rather than
a public issue.

## License

MIT — see [LICENSE](LICENSE).

### Third-party licenses

Otegami depends on several third-party open-source packages via Swift
Package Manager (GRDB.swift, a MailCore2 fork and its C dependencies),
and Go modules for the push relay, and bundles the Archivo font (SIL Open
Font License). See [NOTICE](NOTICE) for license and copyright notices, and
[`server/otegami-relay-go/go.mod`](server/otegami-relay-go/go.mod) for the
relay module list and versions.
