#!/usr/bin/env bash
# M2 (lazy body fetch, HTML rendering, offline persistence) automated
# verification.
#
# Builds the app, runs it against the dev mailstack's Dovecot inside an
# XCUITest (adds the account, opens a Japanese HTML-only seeded message and
# confirms its body renders, opens an HTML message with an external image
# and confirms the "画像を表示" banner appears/disappears), then confirms
# the already-opened message's body is still readable after the mailstack
# is stopped and the app is restarted (offline). Screenshots for
# human/agent review are written to SCREENSHOT_DIR (default
# /tmp/otegami-verify).
#
# Usage: scripts/verify-ios-m2.sh
# Env:
#   IOS_SIMULATOR       Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR       Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID            App bundle id (default: com.m-tkg.otegami)
#   SKIP_MAILSTACK_RESET Set to 1 to leave the mailstack running as-is
#                         instead of up/seed at the start (useful if you
#                         already have it in the state you want).
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

if [[ "${SKIP_MAILSTACK_RESET:-0}" != "1" ]]; then
  echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
  make mailstack-up
  sleep 3
  make mailstack-seed
fi

echo "==> Uninstalling any previous build (fresh local DB for this run)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Running M2 verification UI test (open HTML body, image-block banner)"
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:OtegamiUITests/OtegamiM2VerificationUITests \
  test-without-building

echo "==> Capturing online screenshot (last-opened message, from the test run above)"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m2-01-online-message.png"

echo "==> Stopping mailstack"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
make mailstack-down

echo "==> Running offline verification UI test (restart, confirm cached body still renders)"
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:OtegamiUITests/OtegamiM2OfflineVerificationUITests \
  test-without-building

echo "==> Capturing offline screenshot"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/m2-02-offline-message.png"

echo "==> Restoring mailstack"
make mailstack-up

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m2-01-online-message.png   (mailstack up, last-opened message body visible)
  $SCREENSHOT_DIR/m2-02-offline-message.png  (mailstack down, same message still rendered from local DB)

Review both screenshots to confirm the Japanese HTML body is legible and
identical between the two (offline persistence of a previously-fetched
body).
EOF
