#!/usr/bin/env bash
# Account edit UI automated verification (`docs/roadmap.md`'s former
# "アカウント編集 UI" entry).
#
# Four phases, each its own `xcodebuild test -only-testing:` invocation
# (`OtegamiAccountEditUITests`), no host-side `doveadm`/`Process` calls
# needed (unlike M3-M5) since this feature's whole point is exercised
# entirely from inside the app against the already-running dev mailstack:
#
#   1. testAddAccountAndRenameDisplayName        add account, open the edit
#                                                 sheet, confirm email/種類
#                                                 are read-only, run "接続
#                                                 テスト", rename, save.
#   2. testSavingWrongPasswordSurfacesASyncError  save a wrong password,
#                                                 confirm a visible
#                                                 sync-error banner appears
#                                                 (no relaunch needed — the
#                                                 IDLE loop restarts
#                                                 in-process).
#   3. testFixingThePasswordRecoversSync          save the correct password
#                                                 back, confirm the banner
#                                                 clears.
#   4. testPickingALabelColorPersists             D「アカウントのラベル色」—
#                                                 pick a swatch, save,
#                                                 reopen, confirm it stuck.
#
# The account-edit sheet (like M6's account-type-selection sheet) is pure
# navigation state, not GRDB-persisted, so each phase's screenshot is taken
# *during* that phase's test run (a background subshell overwriting the
# same PNG once a second across the test method's trailing `Thread.sleep`),
# not after — see `.claude/skills/verify/SKILL.md`'s M6 section for why a
# single fixed-delay screenshot proved unreliable and this repeated-
# overwrite approach replaced it.
#
# Usage: scripts/verify-ios-account-edit.sh
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

# Runs `$1` (a `run_test` phase, unlike M6's simple screen-navigation
# phases, does real work first — adding an account, an initial sync, a
# connection test, an IDLE-loop reconnect attempt — before the test method
# finally holds its target screen up with a trailing `Thread.sleep
# (forTimeInterval: 4)`), overwriting `$2.png` once a second the whole time
# so whatever frame lands during that final hold window is what's left on
# disk once the phase finishes — since this phase's total duration varies
# run to run (unlike M6's short, fixed-shape phases), a bounded fixed-delay
# window isn't reliable here; screenshotting for as long as `run_test`
# itself takes and killing the loop the moment it returns is.
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

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# M11 fix (docs/verify.md's "M11" note, `.claude/skills/verify/SKILL.md`):
# a plain `simctl uninstall` doesn't clear Keychain/NSUbiquitousKeyValueStore
# on this simulator/toolchain, which could otherwise resurrect a stale
# account from a previous run's iCloud KVS push.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/3: add account, open edit sheet, connection test, rename, save"
screenshot_during "OtegamiAccountEditUITests/testAddAccountAndRenameDisplayName" "account-edit-01-renamed.png"

echo "==> Phase 2/3: save a wrong password, confirm a visible sync-error banner"
screenshot_during "OtegamiAccountEditUITests/testSavingWrongPasswordSurfacesASyncError" "account-edit-02-sync-error.png"

echo "==> Phase 3/3: fix the password, confirm the sync-error banner clears"
screenshot_during "OtegamiAccountEditUITests/testFixingThePasswordRecoversSync" "account-edit-03-recovered.png"

echo "==> Phase 4/4: D「アカウントのラベル色」— pick a color swatch, confirm it persists"
screenshot_during "OtegamiAccountEditUITests/testPickingALabelColorPersists" "account-edit-04-label-color.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/account-edit-01-renamed.png     (account list showing the renamed display name)
  $SCREENSHOT_DIR/account-edit-02-sync-error.png  (visible sync-error banner after a wrong password)
  $SCREENSHOT_DIR/account-edit-03-recovered.png   (banner cleared after the password was corrected)
  $SCREENSHOT_DIR/account-edit-04-label-color.png (account edit screen with a label color swatch selected)
EOF
