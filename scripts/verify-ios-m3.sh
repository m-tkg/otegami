#!/usr/bin/env bash
# M3 (differential sync, flag sync, offline opQueue, foreground IDLE)
# automated verification.
#
# XCUITest can't shell out to `docker compose exec doveadm` itself
# (`Foundation.Process` is unavailable on iOS), so this script drives the
# "another client changed something on the server" half from the host,
# interleaved with XCUITest phases that drive the app. Four phases:
#
#   1. OtegamiM3SetupUITests           add the Dovecot account, confirm the
#                                       baseline seeded INBOX renders.
#   2. (host) doveadm save             inject a new message, standing in
#                                       for another client's delivery.
#   3. OtegamiM3NewMailUITests         relaunch; the scenePhase-.active
#                                       incremental sync (same code path a
#                                       foreground IDLE push triggers)
#                                       should pick it up within 30s.
#   4. OtegamiM3SwipeActionsUITests/
#      testSwipeMarksMessageRead       swipe a seeded message to
#                                       "既読にする" while online.
#   5. (host) doveadm fetch            assert \Seen actually reached the
#                                       server.
#   6. (host) mailstack-down
#   7. OtegamiM3SwipeActionsUITests/
#      testSwipeDeletesMessageOffline  swipe-delete the M3 message while
#                                       offline; only local removal is
#                                       assertable here.
#   8. (host) mailstack-up, then relaunch the app and give the
#      scenePhase-.active opQueue replay a few seconds to run.
#   9. (host) doveadm fetch (Trash)    assert the delete replayed into
#                                       Trash.
#
# Usage: scripts/verify-ios-m3.sh
# Env:
#   IOS_SIMULATOR        Simulator name (default: iPhone 17 Pro Max)
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
# Also clear any leftover Trash from a previous M3 run, so this run's
# "Trash gained exactly the deleted message" assertion isn't fooled by
# stale state.
doveadm expunge -u "$MAILSTACK_USER" mailbox Trash all || true

echo "==> Uninstalling any previous build (fresh local DB for this run)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/9: add account, confirm baseline INBOX"
run_test "OtegamiM3SetupUITests"

echo "==> Phase 2/9: inject new mail via doveadm (another client's delivery)"
doveadm save -u "$MAILSTACK_USER" -m INBOX < dev/mailstack/seed/fixtures/08-m3-new-mail.eml

echo "==> Phase 3/9: relaunch; confirm the new mail appears via foreground incremental sync"
run_test "OtegamiM3NewMailUITests"

echo "==> Capturing screenshot: new mail visible after differential sync"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m3-01-new-mail-synced.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Phase 4/9: swipe a seeded message to 既読にする (mailstack up)"
run_test "OtegamiM3SwipeActionsUITests/testSwipeMarksMessageRead"

echo "==> Phase 5/9: confirm \\Seen reached the server via doveadm"
seen_ok=0
for _ in $(seq 1 10); do
  if doveadm fetch -u "$MAILSTACK_USER" flags "HEADER Subject 明日の打ち合わせについて" 2>/dev/null | grep -q '\\Seen'; then
    seen_ok=1
    break
  fi
  sleep 1
done
if [[ "$seen_ok" != "1" ]]; then
  echo "error: swiped message never showed \\Seen server-side (opQueue replay didn't reach Dovecot)" >&2
  exit 1
fi
echo "    OK: \\Seen confirmed via doveadm fetch"

echo "==> Capturing screenshot: after swipe-to-read"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m3-02-swiped-read.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Phase 6/9: stopping mailstack (simulate offline)"
make mailstack-down

echo "==> Phase 7/9: swipe-delete offline; confirm local optimistic removal"
run_test "OtegamiM3SwipeActionsUITests/testSwipeDeletesMessageOffline"

echo "==> Capturing screenshot: after offline swipe-delete"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m3-03-offline-deleted.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Phase 8/9: restoring mailstack, relaunching to let opQueue replay run"
make mailstack-up
sleep 3
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
# The queued delete replays as part of RootView's scenePhase-.active
# handler, which runs opQueue replay + incremental sync right on launch —
# give it a few seconds over the (localhost) network before checking.
sleep 5

echo "==> Phase 9/9: confirm the deleted message replayed into Trash via doveadm"
trash_ok=0
for _ in $(seq 1 15); do
  if doveadm fetch -u "$MAILSTACK_USER" mailbox.name mailbox Trash all 2>/dev/null | grep -q '^mailbox.name: Trash$'; then
    trash_ok=1
    break
  fi
  sleep 1
done
if [[ "$trash_ok" != "1" ]]; then
  echo "error: deleted message never appeared in Trash (opQueue replay didn't complete once back online)" >&2
  exit 1
fi
echo "    OK: message found in Trash via doveadm fetch"

echo "==> Capturing final screenshot"
sleep 2
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m3-04-replayed-to-trash.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m3-01-new-mail-synced.png     (doveadm-injected mail appeared via foreground incremental sync)
  $SCREENSHOT_DIR/m3-02-swiped-read.png         (message swiped to 既読にする, \\Seen confirmed server-side)
  $SCREENSHOT_DIR/m3-03-offline-deleted.png     (offline swipe-delete removed locally, mailstack down)
  $SCREENSHOT_DIR/m3-04-replayed-to-trash.png   (after reconnect: opQueue replay moved the message to Trash)
EOF
