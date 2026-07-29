# Contributing to otegami

This is currently a solo side project without a formal contribution
process, but issues and pull requests are welcome — bug reports,
questions, and small fixes especially. For anything larger (a new
feature, a change to sync/threading behavior, a new account type), please
open an issue to discuss the approach first before spending time on an
implementation.

## Development environment

See [docs/development-setup.md](docs/development-setup.md) for the full
prerequisites and build commands (Xcode, XcodeGen, `make mac`/`make ios`/
`make ios-device`, `Local.xcconfig`).

Most day-to-day work happens against the local dev mail stack, so you
don't need a real Gmail/iCloud account:

```sh
make mailstack-up     # start Dovecot (IMAP) + Mailpit (SMTP + web UI)
make mailstack-seed   # load sample messages (Japanese + English fixtures)
```

See [docs/dev-mailstack.md](docs/dev-mailstack.md) for test account
credentials and ports. `make mailstack-down` stops the stack.

If you're working on Gmail OAuth or the push relay, see
[docs/oauth-setup.md](docs/oauth-setup.md) and
[docs/relay-deployment.md](docs/relay-deployment.md) — both are optional,
opt-in pieces that the rest of the app works fine without.

## Running tests

```sh
make test                      # OtegamiKit unit tests (fast, no simulator)
make mac                       # macOS build
make ios                       # iOS Simulator build
```

`make test`, `make mac`, and `make ios` should all stay green — this is
what CI (`ci-app.yml`/`ci-server.yml`) checks on every pull request. For
changes to the push relay:

```sh
make server-test               # otegami-relay unit tests
```

For app-level behavior changes (sync, threading, UI flows), the
`scripts/verify-*.sh` scripts drive the real app against the dev mail
stack via XCUITest and are the closest thing this project has to an
integration test suite — see [docs/verify.md](docs/verify.md) for what
each one covers. They're not required for every PR, but are worth running
if you're touching account setup, sync, or the push notification flow.

### A note on SwiftUI views and CI

`make mac`/`make ios` passing locally is not a guarantee that `ci-app`
will pass, and — this is the sharper version of the lesson — **neither is
a clean run of the diagnostic flags below on your own machine**. This
project hit both: `ci-app` failed with `error: the compiler is unable to
type-check this expression in reasonable time` on a SwiftUI expression
that built cleanly locally even with `-warn-long-expression-type-checking`
turned down to a strict threshold, because the local dev machine ran a
newer Xcode/Swift toolchain than `ci-app`'s runner — the type-checker
itself behaves differently across versions, not just at different speeds.
See [docs/ci.md](docs/ci.md#既知の落とし穴-swiftui-ビューの型チェックタイムアウト-2026-07-25)
for the full incident, including why the first fix attempt (extracting a
row into its own `View`) wasn't enough on its own and what the second
pass had to do differently.

A `ForEach`/`Button`/`HStack`/conditional/modifier-chain combo folded
into one giant expression is the classic trigger. Keep SwiftUI views
small, and go one step further than "extract a row into its own `View`":
also make sure the `ForEach`/`List` closure that *builds* that row is
itself a single trivial function call (hoist an `if let` plus a
multi-argument initializer into a `@ViewBuilder` method), and prefer a
named method reference over an inline closure literal for tap handlers
(`onTap: handleFoo`, not `onTap: { x in ... }`) — closure-literal type
inference at the call site is part of what the type-checker has to solve
jointly with everything else in the same expression. Split a long
modifier chain or a multi-column container like `NavigationSplitView`
into computed properties rather than one continuous expression, too.
`ci-app.yml` builds with `-Xfrontend
-warn-long-expression-type-checking=300 -Xfrontend
-warn-long-function-bodies=300` so slow expressions show up as build
warnings before they become a hard failure — useful for finding
*candidates* worth a look, but (per the incident above) a clean result
locally doesn't prove a matching shape is safe on CI's own toolchain.
When in doubt, apply the split anyway if the code matches the risky
shape, rather than trusting a local zero-warning result.

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`, ...), with a
short imperative subject and, where it's not obvious from the subject
alone, a body explaining *why* the change was made. `git log` has plenty
of examples.

## Pull requests

- Keep PRs focused — one logical change per PR is easier to review than a
  grab-bag.
- Make sure `make test` (and `make mac`/`make ios` where relevant) pass
  locally before opening the PR.
- Describe what changed and why in the PR description; link the issue it
  addresses if there is one.
- New behavior should come with test coverage (unit tests in
  `packages/OtegamiKit/Tests`, or a `scripts/verify-*.sh` addition for
  end-to-end app behavior) where practical.

## Reporting bugs / security issues

Use the [issue templates](.github/ISSUE_TEMPLATE) for regular bug reports
and feature requests. For anything that looks like a security
vulnerability, please follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.
