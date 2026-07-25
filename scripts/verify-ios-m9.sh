#!/usr/bin/env bash
# M9 (push relay opt-in UI) automated verification.
#
# Runs OtegamiM9PushSettingsUITests (apps/Otegami/UITests/
# OtegamiM9PushSettingsUITests.swift):
#
#   1. testEnableButtonDisabledForInvalidRelayURL — a non-https,
#      non-localhost relay URL keeps "有効にする" disabled
#      (AppEnvironment.validatedRelayURL).
#   2. testEnablingPushOnSimulatorShowsGracefulDegradationMessage — a valid
#      https:// URL enables the button; tapping it shows the credential-
#      sharing consent alert; confirming it attempts
#      AppEnvironment.enablePushNotifications, which on the simulator
#      always fails with .noDeviceToken (simulators never issue real APNs
#      device tokens — PushTokenCenter.swift's doc comment) — asserts that
#      surfaces as a visible error message rather than a crash/hang, and
#      that push never reports itself "enabled" as a result.
#
# Neither scenario needs a mail account configured first (the enable
# flow's "create a watch per .password account" step is a no-op with zero
# accounts), so this is simpler than the M1-M8 scripts: no mailstack
# dependency, no persisted-state phases to sequence.
#
# What this script does *not* cover (see PENDING.md's M9 section): real
# APNs delivery, NotificationService content rewriting on a real push, and
# anything requiring a physical device (no .p8 key has been issued for
# this project yet). The relay server's own IDLE -> push pipeline against
# a real IMAP server is scripts/verify-relay.sh's job, not this one's.
#
# Usage: scripts/verify-ios-m9.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR  Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID       App bundle id (default: com.m-tkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.m-tkg.otegami}"

mkdir -p "$SCREENSHOT_DIR"

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

echo "==> Uninstalling any previous build (fresh local state for this run)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Running OtegamiM9PushSettingsUITests"
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:OtegamiUITests/OtegamiM9PushSettingsUITests \
  test-without-building

echo "==> Screenshotting the app post-run (state check, not mid-alert — SwiftUI .alert content isn't screenshot-worthy after dismissal)"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null 2>&1 || xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m9-01-app-relaunch.png"

cat <<EOF

==> Done.
Screenshot:
  $SCREENSHOT_DIR/m9-01-app-relaunch.png
EOF
