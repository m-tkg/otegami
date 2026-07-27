#!/usr/bin/env bash
# アカウントの並び替え — automated verification.
#
# Three phases, each its own `xcodebuild test -only-testing:` invocation
# (`OtegamiAccountReorderUITests`), same "screenshot during the test's
# trailing Thread.sleep, not after" pattern as
# `scripts/verify-ios-account-edit.sh` (the account list is pure navigation
# state while a settings sheet/hamburger drawer is up, not GRDB-persisted on
# its own):
#
#   1. testDefaultOrderMatchesCreationOrderEverywhere   add test1 then test2,
#                                                        confirm the default
#                                                        (un-reordered) order
#                                                        is creation order in
#                                                        設定/ハンバーガー/
#                                                        チップ行.
#   2. testDragReorderInSettingsPersists                drag test2 above
#                                                        test1 in 設定の
#                                                        アカウント一覧 (Edit
#                                                        mode), confirm the
#                                                        swap took effect.
#   3. testReorderedOrderSurvivesRelaunchAndAppliesEverywhere
#                                                        relaunch, confirm
#                                                        the swapped order
#                                                        persisted and shows
#                                                        up in every other
#                                                        account-ordered
#                                                        surface too.
#
# Usage: scripts/verify-ios-account-reorder.sh
# Env:
#   IOS_SIMULATOR        Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR        Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID             App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"

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

# See `scripts/verify-ios-account-edit.sh`'s identically-named helper for
# why this overwrites the same PNG on a 1s loop for the whole phase rather
# than a single fixed-delay screenshot.
screenshot_during() {
  local test_id="$1"
  local out_name="$2"
  (
    while true; do
      xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$out_name" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  run_test "$test_id"
  kill "$screenshot_pid" 2>/dev/null || true
  wait "$screenshot_pid" 2>/dev/null || true
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
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11 fix (docs/verify.md's "M11" note): a plain `simctl uninstall` doesn't
# clear Keychain/NSUbiquitousKeyValueStore on this simulator/toolchain,
# which could otherwise resurrect a stale account from a previous run.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/3: add test1 + test2, confirm default (creation) order everywhere"
screenshot_during "OtegamiAccountReorderUITests/testDefaultOrderMatchesCreationOrderEverywhere" "account-reorder-01-default-order.png"

echo "==> Phase 2/3: drag test2 above test1 in 設定のアカウント一覧, confirm it took effect"
screenshot_during "OtegamiAccountReorderUITests/testDragReorderInSettingsPersists" "account-reorder-02-dragged.png"

echo "==> Phase 3/3: relaunch, confirm the new order persisted and applies everywhere"
screenshot_during "OtegamiAccountReorderUITests/testReorderedOrderSurvivesRelaunchAndAppliesEverywhere" "account-reorder-03-persisted.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/account-reorder-01-default-order.png  (test1 above test2 everywhere, before any reorder)
  $SCREENSHOT_DIR/account-reorder-02-dragged.png         (settings list right after dragging test2 above test1)
  $SCREENSHOT_DIR/account-reorder-03-persisted.png        (post-relaunch: test2 above test1 everywhere)
EOF
