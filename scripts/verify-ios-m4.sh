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
#   BUNDLE_ID             App bundle id (default: com.m-tkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.m-tkg.otegami}"
MAILSTACK_USER="test1@otegami.test"

mkdir -p "$SCREENSHOT_DIR"

run_test() {
  local test_id="$1"
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"OtegamiUITests/$test_id" \
    test-without-building
}

screenshot() {
  local name="$1"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

doveadm() {
  docker compose -f "$ROOT_DIR/dev/mailstack/compose.yml" exec -T dovecot doveadm "$@"
}

echo "==> Resolving simulator UDID for '$IOS_SIMULATOR'"
UDID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$IOS_SIMULATOR" '
  $0 ~ name && $0 !~ /unavailable/ { print $2; exit }
')"
if [[ -z "$UDID" ]]; then
  echo "error: no available simulator matching '$IOS_SIMULATOR'" >&2
  exit 1
fi
echo "    UDID: $UDID"

echo "==> Booting simulator (if needed)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Uninstalling any previous build (fresh local DB for this run)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/4: add test1 account, confirm threaded baseline (References + subject-fallback)"
run_test "OtegamiM4SetupUITests"

echo "==> Capturing screenshot: unified inbox with collapsed threads + count badges"
screenshot "m4-01-unified-inbox-threads.png"

echo "==> Phase 2/4: open the 3-message thread, confirm only the newest is expanded"
run_test "OtegamiM4ThreadDetailUITests"

echo "==> Capturing screenshot: thread detail view (restored on relaunch via lastOpenedThread)"
screenshot "m4-02-thread-detail.png"

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
screenshot "m4-03-swiped-read.png"

echo "==> Phase 4/4: add test2 account, confirm both accounts' threads in the unified inbox"
run_test "OtegamiM4UnifiedInboxUITests"

echo "==> Capturing screenshot: unified inbox with both accounts' threads"
screenshot "m4-04-unified-inbox-two-accounts.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m4-01-unified-inbox-threads.png       (References + subject-fallback threads collapsed with count badges)
  $SCREENSHOT_DIR/m4-02-thread-detail.png                (thread detail: newest expanded, older collapsed/expandable)
  $SCREENSHOT_DIR/m4-03-swiped-read.png                  (after thread-wide swipe-to-read, \\Seen confirmed server-side for both messages)
  $SCREENSHOT_DIR/m4-04-unified-inbox-two-accounts.png   (unified inbox listing both test1 and test2 accounts' threads)
EOF
