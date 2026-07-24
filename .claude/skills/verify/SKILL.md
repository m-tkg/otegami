---
name: verify
description: Steps for building, running, and driving Otegami (iOS/macOS SwiftUI mail app) against the dev mailstack to verify behavior against the real app.
---

# Verifying Otegami against the real app

## Dev mail server

```bash
make mailstack-up      # Dovecot (IMAP :1143 plain / :1993 TLS) + Mailpit (SMTP :1025, web UI :8025)
make mailstack-seed     # loads dev/mailstack/seed/fixtures/*.eml (idempotent since M2 — see below)
make mailstack-down
```

- Accounts: `test1@otegami.test` / `test1234` (6 seeded messages as of M2:
  4 plain + 2 HTML), `test2@otegami.test` / `test1234` (1 seeded message).
- The simulator shares the host's network namespace, so `localhost:1143` from
  the app in-simulator really does reach the host's Docker-published port.
- Seed data lives under `dev/mailstack/data/` (gitignored, bind-mounted into
  the Dovecot container) and is *not* reset by `mailstack-down`/`mailstack-up`
  — only removing that directory does, and that's a destructive operation
  outside normal permissions.
- `seed.sh` is idempotent (M2): it runs `doveadm expunge -u <user> mailbox
  INBOX all` for each seeded user before re-`doveadm save`-ing the fixtures,
  so re-running `make mailstack-seed` reproduces the same fixed set of
  messages rather than accumulating duplicates. `MailCoreIMAPSessionIntegrationTests`
  still asserts `>=` rather than `==` for message counts, since a mailstack
  seeded before this fix (or mid-way through a reseed) can still have extras.

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

## M2: this simulator/toolchain's touch-delivery bugs (read before adding any post-sheet interaction)

Building M2's message-open/tap flow surfaced several environment-level
defects specific to this dev machine's toolchain (Xcode-beta.app running
the iOS 27.0 beta simulator — **not** app bugs; the underlying SwiftUI code
is standard and should behave on a stable/released simulator or a real
device). All were diagnosed the same way: add a `Text` debug readout with
its own `accessibilityIdentifier` bound to the state a tap should have
changed (e.g. `Text("SEL=\(selectedMessageId...)")`), rebuild, tap, then
inspect the readout — far faster than guessing from `xcodebuild test`
output alone. Screenshotting mid-`waitForExistence`-poll (`xcrun simctl io
booted screenshot ...` run from a second shell while the test is still
running) was also decisive for telling "genuinely not rendered yet" apart
from "rendered fine, XCUITest just can't find/tap it."

1. **Every synthesized tap/press computes an invalid `{-1, -1}` hit point
   after `AccountSetupView`'s `.sheet()` dismisses — for *any* element**,
   confirmed with a plain toolbar button, not just `List` rows. `app
   .activate()` does **not** clear it. A full `app.terminate()` +
   `app.launch()` does (the account/mailbox are already in GRDB by then,
   so the relaunch resumes on the same INBOX list with nothing to
   re-enter). See `restartAppToRecoverTouchDelivery(_:)` in
   `UITests/DovecotAccountUITestHelpers.swift` — call it once, right after
   `addDovecotTest1Account`, before any test that taps something beyond
   the account-setup sheet. M1's test never hit this because it never taps
   anything after the sheet dismisses (only asserts `StaticText` existence,
   which needs no hit-testing).
2. **`List(selection:)` never updates the binding on a tap** in this
   environment, even with a correctly-typed non-optional `.tag()`. Use a
   plain `Button` per row setting `@Binding` state directly instead (see
   `MessageListView`) — the same mechanism `AccountSetupView`'s buttons
   already use successfully.
3. **`NavigationSplitView` does not auto-push `content`→`detail` on
   compact width just because a `List`/`Button`-driven selection binding
   changed** — that auto-collapse guarantee only covers `sidebar`→
   `content`. Drive `NavigationSplitView(preferredCompactColumn:)`
   explicitly instead (see `RootView` in `OtegamiApp.swift`): flip it to
   `.content`/`.detail` in the same `onChange` that updates the selection
   state.
4. **`app.buttons["some.identifier"]`/`app.staticTexts["some.identifier"]`
   (identifier-based lookup) can fail to match an element that is plainly
   visible on screen** — confirmed by screenshotting mid-poll while the
   element sat there the whole time. A label-text `NSPredicate` (`label
   CONTAINS %@`) query finds it instead. Seen for both `List` cells (query
   `app.collectionViews["messageList.list"].cells.containing(predicate)`,
   not `app.buttons[id]`/`app.staticTexts[id]`) and a plain `Button`
   outside any list (the "画像を表示" banner).
5. Once an element is actually found, prefer `row.coordinate
   (withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration:
   0.1)` over `.tap()` for `List` rows — `.tap()`'s internal "scroll to
   visible, then compute a hit point" step is what produces the `{-1, -1}`
   in pitfall 1/reproduces flakily elsewhere; a direct coordinate + a
   non-instantaneous press sidesteps it and gives the scroll view's
   tap-vs-scroll gesture disambiguation time to recognize the gesture.

None of this changes what correct SwiftUI code looks like — `List
(selection:)` and automatic compact-width collapsing are the officially
documented patterns and are expected to work normally elsewhere. Re-check
whether these workarounds are still needed the next time this project's
toolchain/simulator moves off a beta OS.

## M3: swipe actions, and why `Process` can't drive `doveadm` from XCUITest

Two things worth recording from building `scripts/verify-ios-m3.sh` /
`OtegamiM3*UITests`:

1. **`Foundation.Process` is unavailable on iOS**, including for code
   compiled into an iOS-platform XCUITest target running against the
   Simulator — it's a compile-time API availability restriction, not a
   runtime sandbox one, so there's no way to shell out to `docker compose
   exec doveadm ...` *from inside* an `OtegamiUITests` test method. Any
   verification step that needs "another IMAP client changed something on
   the server" has to happen from the *wrapping shell script* (a plain
   host `bash` process, where `docker compose`/`doveadm` run fine —
   see `DoveadmHelper.swift` under `Tests/MailTransportMailCoreTests`,
   which *is* allowed `Process` since that's a macOS-only test target),
   interleaved with separate `xcodebuild test -only-testing:...` phases.
   This also means a live "app stays foregrounded, IDLE pushes a change,
   assert it appeared" test isn't achievable as a single continuous
   XCUITest run (the app process isn't reliably kept alive *and*
   simultaneously reachable from a host shell mid-test); `verify-ios-m3.sh`
   instead injects the change first, then does a fresh `app.launch()` and
   relies on `RootView`'s `scenePhase == .active` handler (which runs an
   opQueue replay + incremental sync on every foreground transition,
   including app launch) — the exact same `AccountSyncer
   .performIncrementalSync`/`OpQueueProcessor.replay` code a live
   foreground IDLE push would also trigger, just invoked deterministically
   instead of racing a live push.

2. **`.swipeActions` *does* reveal reliably via `XCUIElement.swipeLeft()`/
   `.swipeRight()`** in this simulator/toolchain — no `{-1, -1}`-style hit
   point bug here, unlike `.tap()`'s post-sheet-dismissal issue above. A
   hand-rolled `coordinate(...).press(forDuration:thenDragTo:)` swipe
   (mimicking the tap workaround's "avoid `.tap()`'s internal machinery"
   approach) reliably *failed* to reveal the action row instead — use the
   built-in convenience methods for row swipes, not a manual drag.
   Revealed swipe-action buttons *do* also match by exact
   `app.buttons["identifier"]` lookup here (confirmed via
   `waitForNonExistence` re-resolving one by its literal identifier
   string in the test log) — the identifier-lookup pitfall from the M2
   section isn't universal, so don't assume it and reach for a `CONTAINS`
   predicate purely defensively; do reach for one when a swipe action's
   *label* is state-dependent (e.g. "既読にする" vs "未読にする" — matching
   the identifier suffix instead of the label sidesteps needing to know
   which state a row is in ahead of time).
3. **A `.containing(predicate)` row lookup can match the wrong row when
   one seeded subject is a substring of another** — "明日の打ち合わせに
   ついて" is also a substring of the seeded reply "Re: 明日の打ち合わせ
   について", which sorts ahead of it (newer) and therefore wins
   `.firstMatch`. Caught by taking a screenshot mid-test (`Thread.sleep`
   inserted after the swipe, `xcrun simctl io ... screenshot` run from a
   second shell during the sleep — the same "screenshot mid-poll" tactic
   from the M2 section) rather than guessing from the assertion failure
   message alone; the fix was picking a collision-free subject for that
   test, not an environment workaround. Worth remembering whenever a test
   subject string could plausibly be any other seeded subject's substring.

## M4: thread-view-specific pitfalls (counting elements, exact identifier lookups, LazyVStack)

Building `OtegamiM4ThreadDetailUITests` (opening a thread and asserting
"only the newest message is expanded") surfaced three more issues, on top
of the ones already logged above — worth checking this list again before
writing any test that counts elements or opens a `LazyVStack`-backed
detail view:

1. **Counting elements via a *container*-level `identifier CONTAINS`
   query over-counts** — querying `app.descendants(matching: .any)
   .matching(identifier CONTAINS "threadDetail.message.")
   .matching(identifier CONTAINS ".body")` to count how many
   `MessageView`s were mounted returned **5** for a single mounted
   instance, not 1. SwiftUI's accessibility bridging exposes several
   nested elements for one `.accessibilityIdentifier(...)`-tagged
   container (each internal layout wrapper seems to inherit/re-report it),
   so a descendant count is not "one identifier = one element". Count a
   single known-unique *leaf* element instead (e.g. one specific `Text`'s
   identifier, like `messageDetail.subject`, that's only ever set in one
   place) — that reliably reports 1 per instance.
2. **The `messageDetail.subject` `Text` — a plainly-rendered, already-
   loaded element — didn't match via `XCUIElementQuery.matching
   (identifier:)`** (an *exact* identifier match), the same failure mode
   M2's pitfall #4 already documented for `app.buttons["id"]`/
   `app.staticTexts["id"]` subscript lookups. It's not limited to the
   subscript form specifically — any exact-identifier query can hit it in
   this simulator/toolchain. `.matching(NSPredicate(format: "identifier
   CONTAINS %@", "messageDetail.subject"))` found it immediately. Default
   to `CONTAINS` for *any* identifier-based query here, not just the
   subscript form.
3. **Right after tapping a thread row, an unscoped `app.staticTexts` query
   can still double-count `messageList.list`'s own (about-to-be-pushed-
   away) row alongside `ThreadDetailView`'s copy of the same subject text**
   — `NavigationSplitView` on this simulator/device ("iPhone 17 Pro Max")
   *is* compact-width (confirmed via screenshot: a single column with a
   navigation-bar back button, not sidebar+content+detail side by side),
   but the outgoing content column's row apparently isn't torn out of the
   accessibility tree instantaneously when the detail push transition
   starts, so a query issued immediately after the tap can catch both for
   a moment. Scoping to the specific pane under test (e.g.
   `app.scrollViews["threadDetail.scrollView"].staticTexts.matching(...)`)
   rather than querying `app` at large sidesteps it regardless of the
   exact cause, and is worth doing on principle whenever more than one
   *could* plausibly contain matching text.
4. **Because this app is compact-width, `RootView`'s "last opened thread"
   restoration means a fresh `app.launch()` can start the app already
   pushed onto `ThreadDetailView` — with the sidebar (and its toolbar
   buttons, e.g. "add account") and even `messageList.list` itself
   unreachable until the navigation-bar back button is tapped.** Confirmed
   by a debug screenshot taken immediately after a test failed trying to
   find a `messageList.list` cell that, per the screenshot, simply wasn't
   on screen — the app had launched straight into the thread detail pane
   restored from the *previous* test's `OtegamiM4ThreadDetailUITests` run
   in the same simulator install. Any M4 test after the first one to open
   a thread must pop back first: `popBackOnceIfNeeded(in:)` (one level,
   detail → content) or `returnToSidebarRootIfNeeded(in:)` (up to three
   levels, polling for the sidebar's add-account entry point) in
   `DovecotAccountUITestHelpers.swift`. Don't assume a "fresh" launch
   means "fresh UI state" once a previous test in the same run has ever
   opened something `@AppStorage` remembers.
5. **A `ScrollView`/`LazyVStack` detail view that opens with its "primary"
   content off-screen never materializes that content's elements at all**
   — `ThreadDetailView` expands the *newest* message by default, but
   `messages` lists oldest-first, so the expanded `MessageView` sits at
   the *bottom* of the `LazyVStack`. Without an explicit scroll anchor,
   the `ScrollView` opens pinned to the top (the oldest, collapsed
   message), and `LazyVStack` — true to its name — doesn't render
   (or attach accessibility identifiers to) rows outside the current
   viewport, so `messageDetail.subject` simply doesn't exist yet no matter
   how long a test waits. Fixed with `.defaultScrollAnchor(.bottom)` on
   the `ScrollView`, not a test-side workaround — this was a real UX bug
   (a user opening a long thread should see the newest message, not have
   to scroll to it), not a simulator quirk. Worth checking for on *any*
   `LazyVStack`/`LazyVGrid` where the row a test (or a user) cares about
   isn't necessarily the first one in list order.

## M6: screenshotting non-persisted UI (sheets that aren't in GRDB)

`scripts/verify-ios-m5.sh` and earlier all screenshot *after* the XCUITest
process exits — safe because what they're capturing (an account list, a
message list) is GRDB-persisted, so a fresh `app.launch()` shows the same
thing the test just drove the app into. `scripts/verify-ios-m6.sh` needed
to screenshot `AccountTypeSelectionView`/`ICloudAccountSetupView`, neither
of which is persisted (they're pure navigation/sheet state) — capturing
after the test process exits just shows whatever's underneath (the empty
sidebar) instead. Fix: the target test method itself holds the screen up
with `Thread.sleep(forTimeInterval: 4)` right before returning, and the
wrapping shell script screenshots *during* that window from a background
subshell running concurrently with `xcodebuild test`. A single fixed-delay
screenshot (`sleep 10 && screenshot`) proved too timing-sensitive in
practice — confirmed by a manual debug run that took one screenshot per
second for 20s and inspected which frames actually showed the sheet: the
visible window landed anywhere from roughly t=6s to t=15s depending on
xcodebuild/simulator startup variance run to run, so a single guess could
miss it entirely (and did, on one otherwise-passing run). The robust
version repeatedly overwrites the same output file every second across a
window wide enough to almost certainly land inside the target screen's
visible time, rather than trying to predict one exact moment.
