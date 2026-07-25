#!/usr/bin/env bash
# QA sweep scenario 4 ("オフライン遷移の雑な組合せ"): messy combinations of
# the dev mailstack going down/up around local read/delete operations.
#
# Phases:
#   0. (host) ensure the test1 Dovecot account exists (reuses M1's setup
#      flow via a plain `-only-testing:OtegamiUITests/OtegamiM1VerificationUITests`
#      run against a freshly-erased simulator, mailstack up).
#   1. (host) make mailstack-down
#   2. OtegamiQASweepOfflineUITests/testColdLaunchWhileOfflineThenNavigate
#      cold launch while offline, scroll, open a thread.
#   3. OtegamiQASweepOfflineUITests/testMarkReadWhileOfflineAppliesLocally
#      mark HTML版だより read via a leading swipe, offline.
#   4. OtegamiQASweepOfflineUITests/testDeleteWhileOfflineRemovesRowLocally
#      delete (件名なし) via a trailing swipe, offline.
#   5. (host) make mailstack-up
#   6. OtegamiQASweepOfflineUITests/testRelaunchAfterMailstackComesBackUpReplaysCleanly
#      cold relaunch — RootView's scenePhase==.active handler replays the
#      opQueue against the now-reachable server.
#   7. (host) doveadm: confirm \Seen reached the server for the read
#      message, and that the deleted message landed in Trash.
#   8. (host) make mailstack-down again, immediately.
#   9. OtegamiQASweepOfflineUITests/testColdLaunchAfterGoingOfflineAgainStillWorks
#      cold launch offline again — confirms no corruption/hang.
#  10. (host) make mailstack-up (restore).
#
# Usage: scripts/verify-qa-sweep-offline.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   BUNDLE_ID       App bundle id (default: com.m-tkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
BUNDLE_ID="${BUNDLE_ID:-com.m-tkg.otegami}"
MAILSTACK_USER="test1@otegami.test"

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

echo "==> Ensuring mailstack is up and seeded for account setup"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 0: add the test1 account (mailstack up)"
run_test "OtegamiM1VerificationUITests/testAddDovecotAccountAndSyncINBOX"

echo "==> Phase 1: mailstack down"
make mailstack-down
sleep 1

echo "==> Phase 2: cold launch while offline, navigate"
run_test "OtegamiQASweepOfflineUITests/testColdLaunchWhileOfflineThenNavigate"

echo "==> Phase 3: mark read while offline"
run_test "OtegamiQASweepOfflineUITests/testMarkReadWhileOfflineAppliesLocally"

echo "==> Phase 4: delete while offline"
run_test "OtegamiQASweepOfflineUITests/testDeleteWhileOfflineRemovesRowLocally"

echo "==> Phase 5: mailstack up"
make mailstack-up
sleep 3

echo "==> Phase 6: relaunch — opQueue replay against the now-reachable server"
run_test "OtegamiQASweepOfflineUITests/testRelaunchAfterMailstackComesBackUpReplaysCleanly"

echo "==> Phase 7: confirming the offline operations reached the server"
seen_ok=0
for _ in $(seq 1 15); do
  if doveadm fetch -u "$MAILSTACK_USER" flags HEADER Subject "HTML版だより" 2>/dev/null | grep -q '\\Seen'; then
    seen_ok=1
    break
  fi
  sleep 1
done
if [[ "$seen_ok" != "1" ]]; then
  echo "error: \"HTML版だより\" never showed \\Seen server-side after coming back online" >&2
  exit 1
fi
echo "    OK: \\Seen confirmed for HTML版だより"

trash_ok=0
for _ in $(seq 1 15); do
  count="$(doveadm mailbox status -u "$MAILSTACK_USER" messages Trash 2>/dev/null | sed -n 's/.*messages=\([0-9]*\).*/\1/p')"
  if [[ -n "$count" && "$count" -ge 1 ]]; then
    trash_ok=1
    break
  fi
  sleep 1
done
if [[ "$trash_ok" != "1" ]]; then
  echo "error: the offline-deleted message never showed up in Trash server-side after coming back online" >&2
  exit 1
fi
echo "    OK: deleted message reached Trash server-side"

echo "==> Phase 8: mailstack down again, immediately after coming online"
make mailstack-down
sleep 1

echo "==> Phase 9: cold launch offline again — confirm no corruption/hang"
run_test "OtegamiQASweepOfflineUITests/testColdLaunchAfterGoingOfflineAgainStillWorks"

echo "==> Phase 10: restoring the mailstack"
make mailstack-up

cat <<EOF

==> Done. All offline/online transition combinations survived cleanly:
  - cold launch while offline (before any online session ever happened)
  - mark-read / delete while offline (local optimistic updates)
  - opQueue replay on coming back online (\\Seen + Trash confirmed server-side)
  - going offline again immediately after an online replay
EOF
