# Contributing to otegami

This is currently a solo side project without a formal contribution
process, but issues and pull requests are welcome — bug reports,
questions, and small fixes especially. For anything larger (a new
feature, a change to sync/threading behavior, a new account type), please
open an issue to discuss the approach first before spending time on an
implementation.

## Development environment

See [README.md](README.md#building) for the full prerequisites and build
commands (Xcode, XcodeGen, `make mac`/`make ios`/`make ios-device`).

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
