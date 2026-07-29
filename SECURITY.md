# Security Policy

otegami is a mail client: it handles IMAP/SMTP credentials, OAuth tokens,
and renders HTML mail from arbitrary senders, so security reports are
taken seriously even though this is a solo/experimental project (see
[README.md](README.md#ステータス)).

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, use GitHub's private vulnerability reporting for this
repository: go to the **Security** tab → **Report a vulnerability** (or
open <https://github.com/m-tkg/otegami/security/advisories/new>
directly). This opens a private draft advisory visible only to you and
the maintainer, and lets us discuss and fix the issue before any public
disclosure.

If you're unable to use GitHub's reporting flow for some reason, opening
a regular issue with as few technical details as possible (just "I think
I found a security issue, how should I share details?") is a reasonable
fallback — a private channel can be arranged from there.

There's no bug bounty program; this is an unfunded side project. Credit
in the fix's changelog/commit is the extent of what can be offered.

## Scope and threat model

Rough areas where a vulnerability report is most relevant, and what's
already been considered:

- **Account credentials at rest**: IMAP/SMTP passwords and OAuth refresh
  tokens are stored in the platform Keychain (`KeychainCredentialStore`),
  not in the SQLite database or in plaintext files. iCloud Keychain
  syncing (opt-in, see [docs/icloud-sync.md](docs/icloud-sync.md)) is the
  only cross-device credential transport; there is no server-side
  credential store on the app side.
- **The optional push relay** (`server/otegami-relay`): if you self-host
  it, it holds your IMAP watch credentials (encrypted at rest with
  `RELAY_MASTER_KEY`, see
  [docs/relay-deployment.md](docs/relay-deployment.md)) so it can IDLE on
  your INBOX and tell APNs when new mail arrives. It's designed to never
  see message subject/body (only `accountId`/`uidNext` cross the wire —
  the app fetches the real content itself). Anyone considering
  self-hosting it should still treat it as a service holding live mail
  credentials and deploy it behind HTTPS, per the deployment doc.
- **HTML mail rendering**: HTML messages render in a sandboxed
  `WKWebView` with JavaScript disabled, specifically to reduce the attack
  surface of rendering untrusted HTML from arbitrary senders. Embedded
  images (inline `cid:`/image attachments) default off; remote images
  default on (with an in-Settings note about the read-receipt tradeoff) —
  both are configurable in Settings and have a one-tap "show images"
  banner as a per-message override. A bug that let mail content execute
  script, exfiltrate data, or otherwise escape the `WKWebView` sandbox is
  a high-priority report.
- **OAuth (Gmail)**: uses Authorization Code + PKCE via
  `ASWebAuthenticationSession`, no client secret embedded in the app (see
  [docs/oauth-setup.md](docs/oauth-setup.md)). Issues with token storage,
  refresh, or the PKCE flow itself are in scope.
- **Local data**: the SQLite database (message bodies, metadata, full-text
  index) is unencrypted at rest, relying on the OS's standard file
  protection — this is a known, accepted trade-off for a local-first mail
  client rather than an oversight, but reports pointing out a way to
  access it that bypasses normal OS protections are still welcome.

Reports about the dev-only tooling (`dev/mailstack`, its throwaway
`otegami.test` credentials, or `scripts/verify-*.sh`) are out of scope —
none of that ships in the app or is reachable outside a local checkout.
