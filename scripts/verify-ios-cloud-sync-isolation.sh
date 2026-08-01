#!/usr/bin/env bash
# Real-device iCloud KVS contamination fix — automated verification.
#
# Confirms, from OUTSIDE the app (the host Mac's own `cloudd` unified log),
# that adding a dev-mailstack account on an ordinary Simulator launch (no
# `-otegamiEnableCloudSyncInSimulator` opt-in) never causes any
# CloudKit/iCloud-KVS traffic for this app's container at all — the fix for
# the real-device incident recorded in `docs/icloud-sync.md`'s "開発用ビル
# ドでの iCloud KVS 汚染" section (`AppEnvironment
# .isCloudSyncPermittedOnThisBuild`'s doc comment has the full account of
# how this was confirmed to be happening in the first place).
#
# This is deliberately a log-based check rather than an in-app assertion:
# the whole point of the bug is that the Simulator's iCloud KVS calls are
# proxied through the host Mac's real `cloudd` daemon (using whatever real
# Apple ID that Mac is signed into) — `cloudd` logs a
# `"TCC approved access for container containerID=iCloud.<bundle id>:Sandbox"`
# line every time it grants an app process access to that container, which
# is the earliest, most direct observable signal that a KVS/CloudKit call
# was even attempted, independent of whether the call itself would go on to
# succeed or silently no-op.
#
# Usage: scripts/verify-ios-cloud-sync-isolation.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   BUNDLE_ID       App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/build.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
# `log`/`grep` below use the full path — this dev environment's shell hooks
# (rtk) intercept the bare command names and mis-parse quoted predicates.
LOG_BIN="/usr/bin/log"

resolve_simulator_udid

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS state)"
erase_simulator

echo "==> Booting simulator"
boot_simulator
grant_contacts_privacy

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Regenerating Xcode project and building for testing"
xcodegen_generate
build_for_testing

# Real wall-clock timestamps (not simulator-relative) bracket the window
# `log show` searches — captured *before* the test run starts and *after*
# it ends, plus a small margin on each side to absorb `xcodebuild`
# start-up/teardown overhead without narrowing the window past the actual
# test.
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> [$START_TS] Running OtegamiCloudSyncSimulatorIsolationUITests (adds a dev-mailstack account on an ordinary, non-opted-in Simulator launch)"

run_test "OtegamiCloudSyncSimulatorIsolationUITests"

END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> [$END_TS] Test run complete"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Searching this Mac's own cloudd/CloudKit log for any container access this app's Simulator process triggered in that window"
CLOUD_ACCESS_LINES="$("$LOG_BIN" show --style compact --start "$START_TS" --end "$END_TS" \
  --predicate "eventMessage CONTAINS \"iCloud.$BUNDLE_ID\"" 2>/dev/null || true)"

if [[ -n "$CLOUD_ACCESS_LINES" ]]; then
  echo ""
  echo "FAIL: cloudd logged container access for iCloud.$BUNDLE_ID during the test window — the Simulator cloud-sync gate did not hold:"
  echo "$CLOUD_ACCESS_LINES"
  exit 1
fi

echo ""
echo "PASS: no cloudd/CloudKit container access for iCloud.$BUNDLE_ID was logged while"
echo "OtegamiCloudSyncSimulatorIsolationUITests added a dev-mailstack account — the"
echo "Simulator cloud-sync gate (AppEnvironment.isCloudSyncPermittedOnThisBuild) held."
echo ""
echo "Not covered here: a Mac-native (non-Simulator) 'make mac' run, which the"
echo "Simulator gate doesn't apply to at all — that vector is covered instead by"
echo "CloudAccountSnapshot.isDevelopmentAccount (packages/OtegamiKit's unit tests),"
echo "which excludes dev-mailstack hosts from the cloud payload regardless of platform."
