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
#   BUNDLE_ID       App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"

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
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11: a plain `xcrun simctl uninstall` (what this step used to be) removes
# the app's own container but not Keychain/NSUbiquitousKeyValueStore, both
# of which live outside the per-app container on this simulator/toolchain —
# an account a *previous* verify run pushed to iCloud KVS (and whose
# Keychain password also survived) otherwise resurrects itself right after
# "uninstall for a fresh local DB", defeating this step's whole point (the
# same fix `verify-ios-m1.sh`/`verify-ios-m2.sh`/`verify-ios-m4.sh` already
# made, applied here after hitting the identical failure running this
# script during a QA regression pass: "Neither the empty-state nor toolbar
# \"add account\" button appeared"). A full erase clears all three; the
# simulator needs a shutdown first (erase fails on a booted device) and a
# reboot after (later steps assume it's already up).
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

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
