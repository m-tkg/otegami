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

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11: a plain `xcrun simctl uninstall` (what this step used to be) removes
# the app's own container — which resets the GRDB database — but does
# *not* reset Keychain or NSUbiquitousKeyValueStore, both of which live
# outside the per-app container on this simulator/toolchain. Since M11's
# `AccountCloudSyncEngine` reconciles from iCloud KVS at every launch, an
# account a *previous* verify run pushed to the KVS payload (and whose
# Keychain password also survived) would otherwise resurrect itself right
# after "uninstall for a fresh local DB", defeating the point of this step
# — `verify-ios-m1.sh`/`verify-ios-m4.sh` already made this same switch for
# the identical reason. A full erase clears all three, giving every run of
# this script the same truly-empty starting state `simctl uninstall` alone
# used to provide before M11.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

if [[ "${SKIP_MAILSTACK_RESET:-0}" != "1" ]]; then
  echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
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

# Repeatedly overwrites the same output file across a window wide enough to
# almost certainly land inside the target test method's `Thread.sleep`
# hold — see docs/verify.md's M6/M8 sections for why a single fixed-delay
# screenshot is too timing-sensitive in this environment. Needed here (as
# of the cold-launch-restoration removal — docs/verify.md) since neither
# UI test's target screen is reachable anymore via a post-test-exit
# `simctl launch` relaunch; the message has to be screenshotted while the
# test itself is still holding it open.
screenshot_mid_test() {
  local test_id="$1"
  local out_name="$2"
  (
    sleep 4
    for _ in $(seq 1 10); do
      xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$out_name" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"OtegamiUITests/$test_id" \
    test-without-building
  wait "$screenshot_pid" 2>/dev/null || true
}

echo "==> Running M2 verification UI test (open HTML body, image-block banner)"
screenshot_mid_test "OtegamiM2VerificationUITests" "m2-01-online-message.png"

echo "==> Stopping mailstack"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
make mailstack-down

echo "==> Running offline verification UI test (restart, tap the cached thread, confirm the body still renders)"
screenshot_mid_test "OtegamiM2OfflineVerificationUITests" "m2-02-offline-message.png"

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
