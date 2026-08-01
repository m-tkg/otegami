#!/usr/bin/env bash
# Verification for the "重複統合バグの修正後も資格情報が消えていたバグ"
# investigation (`docs/icloud-sync.md`) — two independent Keychain-recovery
# paths that both run automatically at `AppEnvironment.init()`:
#
#   1. Legacy-service fallback (`KeychainCredentialStore.legacyServices`):
#      recovers a password stranded under the pre-`52df393` service string.
#   2. Orphan-account-id adoption (`AppEnvironment
#      .adoptOrphanedCredentialIfUnambiguous`): recovers a password
#      stranded under a merged-away account's now-nonexistent accountId —
#      the state a device already left in a bad state by a duplicate-
#      account merge (`AccountDuplicateMerger`) ends up in.
#
# Usage: scripts/verify-ios-credential-recovery.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR  Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID       App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/build.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"

mkdir -p "$SCREENSHOT_DIR"

resolve_simulator_udid

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
erase_simulator

echo "==> Booting simulator"
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Regenerating Xcode project and building for testing"
xcodegen_generate
build_for_testing

echo "==> Phase 1/2: legacy Keychain-service-string recovery"
run_test OtegamiCredentialRecoveryUITests/testPasswordRecoversFromLegacyKeychainServiceOnRelaunch
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/credential-recovery-01-legacy-service-inbox.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Re-seeding + erasing between phases (independent scenarios, same account setup)"
erase_simulator
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)
make mailstack-seed

echo "==> Phase 2/2: orphaned-Keychain-entry (bad duplicate-merge aftermath) recovery"
run_test OtegamiCredentialRecoveryUITests/testOrphanedCredentialIsAdoptedOnNextOrdinaryLaunch
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 3
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/credential-recovery-02-orphan-adoption-inbox.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo ""
echo "==> Done."
echo "Screenshots:"
echo "  $SCREENSHOT_DIR/credential-recovery-01-legacy-service-inbox.png   (recovered after legacy-service relocation)"
echo "  $SCREENSHOT_DIR/credential-recovery-02-orphan-adoption-inbox.png (recovered after orphan-accountId relocation)"
