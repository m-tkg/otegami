# otegami

An open-source mail client for iOS and macOS that connects to your existing
email accounts (Gmail, iCloud, and generic IMAP/SMTP) with a single offline-first
sync engine.

- **Platforms**: iOS 26+ / macOS 26+, single SwiftUI codebase
- **Storage**: local SQLite (GRDB) with FTS5 full-text search
- **Push notifications**: optional self-hosted relay server (Swift / Hummingbird 2)

## Status

Early scaffold (M0). Not yet usable as a mail client.

## Building

This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate
the Xcode project, so install it first (`brew install xcodegen`).

```sh
make mac    # build the macOS app
make ios    # build for the iOS Simulator
make test   # run the OtegamiKit unit tests
```

Opening `apps/Otegami/Otegami.xcodeproj` in Xcode after `xcodegen generate`
(done automatically by the targets above) also works for day-to-day development.

## Development mail stack

A local Dovecot (IMAP) + Mailpit (SMTP + web UI) stack is included for
development, so you don't need a real mail account to work on sync/send code.

```sh
make mailstack-up     # start Dovecot + Mailpit
make mailstack-seed   # load sample messages into the test IMAP account
make mailstack-down   # stop the stack
```

See [docs/dev-mailstack.md](docs/dev-mailstack.md) for details.

## Server

`server/otegami-relay` is an optional, self-hostable push notification relay
(Swift / Hummingbird 2). See `make server` / `make server-test`.

## License

MIT — see [LICENSE](LICENSE).
