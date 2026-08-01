#!/usr/bin/env bash
# M4 (threading, multi-account, unified inbox) automated verification.
#
# Four XCUITest phases, each a separate `xcodebuild test` invocation
# against the same simulator install (state — GRDB, Keychain — survives
# between them, same pattern as `verify-ios-m3.sh`), interleaved with host
# `doveadm` checks for the one checkpoint (swipe-read) that needs to
# confirm a server-side effect:
#
#   1. OtegamiM4SetupUITests            add the test1 Dovecot account,
#                                        confirm the References-linked
#                                        3-message thread (09/10/11) and
#                                        the References-free subject-
#                                        fallback thread (12/13) each
#                                        collapse to one row with the
#                                        right count badge.
#   2. OtegamiM4ThreadDetailUITests     open the 3-message thread: 3
#                                        header rows, only the newest
#                                        expanded by default, tapping an
#                                        older header expands it too.
#   3. OtegamiM4SwipeReadUITests        leading-swipe the 2-message
#                                        02/03 thread to "既読にする".
#      (host) doveadm fetch             confirm \Seen reached *both*
#                                        underlying messages server-side.
#   4. OtegamiM4UnifiedInboxUITests     add the test2 Dovecot account;
#                                        confirm the (default-selected)
#                                        unified inbox lists threads from
#                                        both accounts together.
#
# Usage: scripts/verify-ios-m4.sh
# Env:
#   IOS_SIMULATOR         Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR        Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID             App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/build.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
MAILSTACK_USER="test1@otegami.test"

mkdir -p "$SCREENSHOT_DIR"

screenshot() {
  local name="$1"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# Like `screenshot`, but for a phase whose XCUITest already left the app on
# the message list (not a thread detail) — relevant because `xcodebuild
# test-without-building` doesn't leave the AUT process alive once the test
# run exits (confirmed empirically: a plain `simctl launch` here still cold-
# starts a fresh process, same as `--terminate-running-process`), so *any*
# relaunch triggers `RootView`'s "last opened thread" `@AppStorage`
# restoration — which would reopen whatever thread an *earlier* phase last
# viewed, not reflect what this phase's test actually left on screen.
# `-uiTestsSkipThreadRestoration` (a launch argument `RootView` checks for)
# suppresses that restoration for this one relaunch.
screenshotForeground() {
  local name="$1"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsSkipThreadRestoration -uiTestsAutoAdvanceToContent >/dev/null
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

doveadm() {
  docker compose -f "$ROOT_DIR/dev/mailstack/compose.yml" exec -T dovecot doveadm "$@"
}

resolve_simulator_udid

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11: a plain `xcrun simctl uninstall` (what this step used to be) removes
# the app's own container — which resets the GRDB database — but does
# *not* reset Keychain or NSUbiquitousKeyValueStore, both of which live
# outside the per-app container on this simulator/toolchain. Since M11's
# `AccountCloudSyncEngine` reconciles from iCloud KVS at every launch, an
# account a *previous* verify run pushed to the KVS payload (and whose
# Keychain password also survived) would otherwise resurrect itself right
# after "uninstall for a fresh local DB", defeating the point of Phase 1
# (`OtegamiM4SetupUITests` expects to start from the empty-account
# sidebar) — confirmed via a real failure ("Neither the empty-state nor
# toolbar \"add account\" button appeared") while regression-testing the
# cold-launch/sidebar-selection fixes in docs/verify.md. `verify-ios-m1.sh`
# already made this same switch for the identical reason; M4 hadn't been
# updated to match until now. A full erase clears all three, giving every
# run of this script the same truly-empty starting state `simctl
# uninstall` alone used to provide before M11.
erase_simulator

echo "==> Booting simulator"
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Regenerating Xcode project and building for testing"
xcodegen_generate
build_for_testing

echo "==> Phase 1/4: add test1 account, confirm threaded baseline (References + subject-fallback)"
run_test "OtegamiM4SetupUITests"

echo "==> Capturing screenshot: unified inbox with collapsed threads + count badges"
screenshot "m4-01-unified-inbox-threads.png"

echo "==> Phase 2/4: open the 3-message thread, confirm only the newest is expanded"
# Screenshotted *during* the test run (mid-test, same technique as M6/M8's
# `screenshot_mid_test`), not via a post-test relaunch — `RootView`'s "last
# opened thread" restoration is same-session-only now, not cross-launch
# (docs/verify.md), so a relaunch after this test exits would land on the
# message list, not the thread it just opened.
#
# 新画面構成: this phase's test class runs `testCollapsingEveryMessageStaysTopAligned`
# first (alphabetical XCTest ordering), whose own designed screenshot
# moment is a `Thread.sleep(4)` right at the *end* of that ~29s method
# (after opening the thread, waiting for 3 headers, collapsing the newest,
# and polling for every body to unmount) — confirmed via `sleep 4` +
# 10x1s (t=4..14s) landing on the plain message list every time (the row
# tap/navigation hadn't even happened yet that early), not the thread
# detail this screenshot is meant to show. Widened to start well past that
# method's own setup + polling.
(
  sleep 17
  for _ in $(seq 1 8); do
    xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m4-02-thread-detail.png" >/dev/null 2>&1 || true
    sleep 1
  done
) &
screenshot_pid=$!
run_test "OtegamiM4ThreadDetailUITests"
wait "$screenshot_pid" 2>/dev/null || true

echo "==> Phase 3/4: swipe the 2-message thread to 既読にする"
run_test "OtegamiM4SwipeReadUITests"

echo "==> Confirming both underlying messages picked up \\Seen via doveadm"
for subject in "明日の打ち合わせについて" "Re: 明日の打ち合わせについて"; do
  seen_ok=0
  for _ in $(seq 1 10); do
    # doveadm's search query tokens must stay separate argv entries — see
    # verify-ios-m3.sh's matching comment for why joining them into one
    # shell string breaks doveadm's own argument parser.
    if doveadm fetch -u "$MAILSTACK_USER" flags HEADER Subject "$subject" 2>/dev/null | grep -q '\\Seen'; then
      seen_ok=1
      break
    fi
    sleep 1
  done
  if [[ "$seen_ok" != "1" ]]; then
    echo "error: \"$subject\" never showed \\Seen server-side (thread-wide swipe read didn't reach Dovecot)" >&2
    exit 1
  fi
  echo "    OK: \\Seen confirmed for \"$subject\""
done

echo "==> Capturing screenshot: after thread-wide swipe-to-read"
screenshotForeground "m4-03-swiped-read.png"

echo "==> Phase 4/4: add test2 account, confirm both accounts' threads in the unified inbox"
run_test "OtegamiM4UnifiedInboxUITests"

echo "==> Capturing screenshot: unified inbox with both accounts' threads"
screenshotForeground "m4-04-unified-inbox-two-accounts.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m4-01-unified-inbox-threads.png       (References + subject-fallback threads collapsed with count badges)
  $SCREENSHOT_DIR/m4-02-thread-detail.png                (thread detail: newest expanded, older collapsed/expandable)
  $SCREENSHOT_DIR/m4-03-swiped-read.png                  (after thread-wide swipe-to-read, \\Seen confirmed server-side for both messages)
  $SCREENSHOT_DIR/m4-04-unified-inbox-two-accounts.png   (unified inbox listing both test1 and test2 accounts' threads)
EOF
