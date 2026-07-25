#!/usr/bin/env bash
# M1 (generic IMAP -> INBOX -> message list) automated verification.
#
# Builds the app, runs it against the dev mailstack's Dovecot inside an
# XCUITest (adds a generic IMAP account, confirms the connection test and
# initial sync bring in the seeded INBOX messages), then confirms the list
# still renders from the local GRDB database with the mailstack stopped
# (offline). Screenshots for human/agent review are written to
# SCREENSHOT_DIR (default /tmp/otegami-verify).
#
# Usage: scripts/verify-ios-m1.sh
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

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11: a plain `xcrun simctl uninstall` (what this step used to be) removes
# the app's own container — which resets the GRDB database — but does
# *not* reset Keychain or NSUbiquitousKeyValueStore, both of which live
# outside the per-app container on this simulator/toolchain. Since M11's
# `AccountCloudSyncEngine` reconciles from iCloud KVS at every launch, an
# account a *previous* verify run pushed to the KVS payload (and whose
# Keychain password also survived) would otherwise resurrect itself right
# after "uninstall for a fresh local DB", defeating the point of this step
# — confirmed while adding M11 (see docs/icloud-sync.md's verify note). A
# full erase clears all three, giving every run of this script the same
# truly-empty starting state `simctl uninstall` alone used to provide
# before M11.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

if [[ "${SKIP_MAILSTACK_RESET:-0}" != "1" ]]; then
  echo "==> Starting dev mailstack and seeding fixtures"
  make mailstack-up
  sleep 3
  make mailstack-seed
fi

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Running M1 verification UI test (add account, connection test, INBOX sync)"
# M10 fix: this used to be a blanket `-only-testing:OtegamiUITests` (the
# whole target), which only ever meant "just M1's test class" back when M1
# was the only one in the target. Every milestone since has added its own
# UITest class to the same `OtegamiUITests` target/scheme, so this blanket
# filter silently started running *every* milestone's tests back-to-back in
# one xcodebuild invocation — none of which (besides M1's own) get the
# per-phase mailstack up/down toggling or `simctl uninstall` reset their own
# dedicated verify-ios-mN.sh scripts give them, so most of them fail from
# state pollution, not from any real app regression. Confirmed while
# building M10: scoping this to just OtegamiM1VerificationUITests (matching
# every later script's `-only-testing:OtegamiUITests/ClassName` pattern)
# is what this script always meant to do.
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:OtegamiUITests/OtegamiM1VerificationUITests \
  test-without-building

echo "==> Capturing online screenshot"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/01-online-inbox.png"

echo "==> Stopping mailstack and capturing offline screenshot"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
make mailstack-down
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/02-offline-inbox.png"

echo "==> Restoring mailstack"
make mailstack-up

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/01-online-inbox.png   (mailstack up, INBOX synced from Dovecot)
  $SCREENSHOT_DIR/02-offline-inbox.png  (mailstack down, list still rendered from local DB)

Review both screenshots to confirm the seeded Japanese subjects appear and
are identical between the two (offline persistence).
EOF
