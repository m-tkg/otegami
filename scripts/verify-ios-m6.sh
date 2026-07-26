#!/usr/bin/env bash
# M6 (Gmail OAuth + iCloud presets) automated verification.
#
# Unlike M1-M5's scripts, this one needs no Mailpit REST API / doveadm
# round trips of its own — every M6 checkpoint the plan calls for that's
# reachable without a real Google/iCloud account is a pure XCUITest
# assertion. It still starts/stops the dev mailstack because
# OtegamiM6OtherAccountFlowUITests (the "「その他」経路が従来通り動く"
# regression check) needs it, same as M1's script.
#
# What this does NOT verify (see PENDING.md): a real interactive Google
# OAuth round trip, a real iCloud IMAP/SMTP connection. Both require a
# throwaway account this environment doesn't have; docs/oauth-setup.md's
# "実機での最終確認手順" is the human follow-up for the former, and
# PENDING.md's "iCloud App 用パスワードでの実アカウント確認" entry for the
# latter.
#
#   1. OtegamiM6TypeSelectionUITests    Gmail/iCloud/その他 all offered;
#                                        Gmail disabled + docs/oauth-setup.md
#                                        hint shown (no Client ID configured
#                                        in this build); Cancel dismisses.
#   2. OtegamiM6ICloudFormUITests       iCloud form shows the
#                                        imap.mail.me.com/smtp.mail.me.com
#                                        presets, validates input, links to
#                                        appleid.apple.com.
#   3. OtegamiM6OtherAccountFlowUITests "その他 (IMAP)" still reaches the
#                                        Dovecot-seeded inbox (M1 baseline,
#                                        now one tap deeper).
#
# Usage: scripts/verify-ios-m6.sh
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

screenshot() {
  local name="$1"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
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
# M11: see verify-ios-m1.sh's identical step for why a plain `simctl
# uninstall` no longer gives this script's account-type-selection/empty-
# state assertions a truly-empty starting account list — an account
# another verify run pushed to iCloud KVS (with its Keychain password also
# surviving the app's own uninstall) resurrects itself on next launch.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

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
  # Neither the account-type-selection sheet nor the iCloud form persist
  # any state to GRDB, so screenshotting *after* the XCUITest process exits
  # (every other verify script's pattern, per docs/verify.md) would just
  # show whatever's underneath instead of the sheet itself.
  # OtegamiM6TypeSelectionUITests/OtegamiM6ICloudFormUITests each hold their
  # target screen up via a `Thread.sleep(forTimeInterval: 4)` right before
  # returning specifically so this function has a window to catch it in —
  # same "screenshot mid-poll from a second shell" technique
  # docs/verify.md's M2 section documents.
  #
  # A single fixed-delay screenshot proved too timing-sensitive in practice
  # (xcodebuild/simulator startup overhead varies run to run — a `sleep 10`
  # landed inside the target screen's ~t=8s-15s visible window on one run
  # and missed it entirely on another), so this instead repeatedly
  # overwrites the same output file every second from t=6s to t=13s: since
  # the screen is static for that whole window, every write inside it
  # produces the same correct image, and the *last* write (t=13s, safely
  # before the ~15s test typically finishes and the app gets torn down)
  # is what's left on disk once `run_test` returns.
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

echo "==> Phase 1/3: account type selection (Gmail disabled + hint, iCloud/その他 enabled, Cancel dismisses)"
screenshot_mid_test "OtegamiM6TypeSelectionUITests" "m6-01-account-type-selection.png"

echo "==> Phase 2/3: iCloud form presets + validation"
screenshot_mid_test "OtegamiM6ICloudFormUITests" "m6-02-icloud-form.png"

echo "==> Phase 3/3: \"その他 (IMAP)\" regression — still reaches the Dovecot-seeded inbox"
run_test "OtegamiM6OtherAccountFlowUITests"

echo "==> Capturing screenshot: seeded inbox via \"その他\""
screenshot "m6-03-other-imap-inbox.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m6-01-account-type-selection.png  (Gmail/iCloud/その他 picker)
  $SCREENSHOT_DIR/m6-02-icloud-form.png              (iCloud form, presets visible)
  $SCREENSHOT_DIR/m6-03-other-imap-inbox.png         ("その他" regression, seeded inbox)

Not covered here (see PENDING.md / docs/oauth-setup.md):
  - a real interactive Gmail OAuth sign-in
  - a real iCloud IMAP/SMTP connection
EOF
