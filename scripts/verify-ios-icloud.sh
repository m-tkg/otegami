#!/usr/bin/env bash
# M11 (iCloud account sync) automated verification.
#
# A real two-device iCloud KVS round trip can't be driven from a single
# simulator/CI environment (it requires a manual two-device check).
# What this script *does* verify automatically:
#
#   1. The app launches at all with the new `com.apple.developer.ubiquity
#      -kvstore-identifier` entitlement in place — the iOS/macOS
#      equivalent of M10's "App Group entitlement missing" postmortem
#      would be a crash-on-launch here.
#   2. Settings shows the "iCloud でアカウントを同期" toggle, on by default.
#   3. Toggling it off then back on doesn't crash or lose the account list
#      (a full reconcile runs on the on-transition).
#   4. Adding an account the ordinary way (dev/mailstack's Dovecot, M1
#      baseline) still works unchanged with the entitlement present — the
#      regression check the plan explicitly calls for.
#
# Usage: scripts/verify-ios-icloud.sh
# Env:
#   IOS_SIMULATOR         Simulator name (default: iPhone 17 Pro Max)
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

echo "==> Resolving simulator UDID for '$IOS_SIMULATOR'"
UDID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$IOS_SIMULATOR" '
  $0 ~ name && $0 !~ /unavailable/ { print $2; exit }
')"
if [[ -z "$UDID" ]]; then
  echo "error: no available simulator matching '$IOS_SIMULATOR'" >&2
  exit 1
fi
echo "    UDID: $UDID"

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# See verify-ios-m1.sh's identical step's doc comment: a plain `simctl
# uninstall` doesn't reset Keychain/iCloud KVS on this simulator/toolchain,
# so a leftover synced account from an earlier verify run could otherwise
# resurrect itself and confuse this script's own account-count assumptions.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

screenshot_mid_test() {
  # settings.cloudSyncToggle lives on a pure-navigation sheet (no GRDB
  # persistence), same reasoning as verify-ios-m6.sh's identical helper —
  # see its doc comment for why this is a repeated-overwrite capture
  # rather than a single fixed-delay screenshot.
  local test_id="$1"
  local out_name="$2"
  (
    sleep 6
    for _ in $(seq 1 8); do
      xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$out_name" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  run_test "$test_id"
  wait "$screenshot_pid" 2>/dev/null || true
}

echo "==> Phase 1/2: cloud sync toggle shown, on by default"
screenshot_mid_test OtegamiM11ICloudSyncUITests/testCloudSyncToggleIsShownAndOnByDefault icloud-01-settings-toggle.png

echo "==> Phase 2/2: toggle off/on round trip + Dovecot account-add regression"
run_test OtegamiM11ICloudSyncUITests/testTogglingCloudSyncOffAndBackOnDoesNotCrashOrLoseTheAccountList

echo "==> Capturing final inbox screenshot"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/icloud-02-inbox-after-toggle-roundtrip.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo ""
echo "==> Done."
echo "Screenshots:"
echo "  $SCREENSHOT_DIR/icloud-01-settings-toggle.png              (iCloud sync toggle, on by default)"
echo "  $SCREENSHOT_DIR/icloud-02-inbox-after-toggle-roundtrip.png (account list survives a toggle off/on)"
echo ""
echo "Not covered here: a real two-device (iPhone + Mac,"
echo "same Apple ID) iCloud KVS round trip."
