#!/usr/bin/env bash
# M7 (FTS5 trigram + LIKE fallback full-text search) automated verification.
#
# Two phases, both against the dev mailstack's seeded fixtures:
#
#   1. OtegamiM7SetupUITests   Adds both Dovecot accounts (test1/test2) and
#                              confirms their baseline seeded messages show
#                              up before any search-specific phase runs.
#   2. OtegamiM7SearchUITests  Five independent scenarios (plan checkpoints
#                              (a)-(e)), each its own `xcodebuild test
#                              -only-testing:` invocation reusing phase 1's
#                              persisted GRDB state:
#                                (a) 2-character Japanese query ("打ち") hits
#                                    via the LIKE fallback
#                                (b) 3+ character Japanese query
#                                    ("打ち合わせ") hits via FTS5 trigram MATCH
#                                (c) English query ("html", lowercase) hits,
#                                    proving ASCII case folding
#                                (d) unified-inbox "すべて" scope returns
#                                    results from both test1 and test2
#                                (e) an impossible query shows the
#                                    zero-results empty state
#
# All five search queries deliberately hit on `message.subject` alone
# (never `messageBody.plainText`), so none of them race
# `BodyFetcher.prefetchRecent`'s background body-fetch pass — see
# `OtegamiM7SearchUITests`'s doc comment.
#
# Search results are pure `@State`, not `@AppStorage`-backed, so (unlike
# M1-M5's message list) there's nothing to see in a screenshot taken *after*
# the XCUITest process exits. Every search-phase test method instead holds
# its result screen up with `Thread.sleep(forTimeInterval: 4)` right before
# returning, and this script screenshots *during* that window from a
# concurrently-running background subshell — the same technique
# `docs/verify.md`'s M6 section established for its own non-persisted
# account-setup sheets.
#
# Usage: scripts/verify-ios-m7.sh
# Env:
#   IOS_SIMULATOR         Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR        Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID             App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/build.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"

mkdir -p "$SCREENSHOT_DIR"

# Repeatedly overwrites the same output file across a window wide enough to
# almost certainly land inside the target test method's `Thread.sleep`
# hold — see this script's header comment and docs/verify.md's M6 section
# for why a single fixed-delay screenshot is too timing-sensitive in this
# environment.
#
# 新画面構成: `sleep 6`/8 iterations (window t=6..14s) used to reliably land
# on the results state, but search moved from an instant `TabView` tab
# switch to `SearchScreenView` presented as a `.sheet` (`openSearchScreen`)
# — the sheet-presentation animation plus this test target's larger binary
# (more source files) pushed a cold `app.launch()`'s "search field ready,
# query typed, debounced results rendered" moment later than before,
# confirmed by every one of this script's mid-test screenshots landing on
# the still-showing 検索履歴 (history) state instead of results when this
# window was left unchanged. Widened to t=9..21s (13 iterations) to give
# enough margin again.
screenshot_mid_test() {
  local test_id="$1"
  local out_name="$2"
  (
    sleep 9
    for _ in $(seq 1 13); do
      xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$out_name" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  run_test "$test_id"
  wait "$screenshot_pid" 2>/dev/null || true
}

resolve_simulator_udid

echo "==> Booting simulator (if needed)"
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

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
erase_simulator
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Regenerating Xcode project and building for testing"
xcodegen_generate
build_for_testing

echo "==> Phase 1/2: adding test1 + test2 accounts, baseline seeded messages"
run_test "OtegamiM7SetupUITests"

echo "==> Phase 2/2, scenario (a): 2-character Japanese query (\"打ち\") — LIKE fallback"
screenshot_mid_test "OtegamiM7SearchUITests/testTwoCharacterJapaneseQueryHits" "m7-01-two-char-japanese.png"

echo "==> Phase 2/2, scenario (b): 3+ character Japanese query (\"打ち合わせ\") — FTS5 trigram MATCH"
screenshot_mid_test "OtegamiM7SearchUITests/testThreeCharacterJapaneseQueryHitsViaFTS" "m7-02-three-char-japanese-fts.png"

echo "==> Phase 2/2, scenario (c): English query (\"html\", lowercase) — ASCII case folding"
screenshot_mid_test "OtegamiM7SearchUITests/testEnglishQueryHits" "m7-03-english-query.png"

echo "==> Phase 2/2, scenario (d): unified-inbox \"すべて\" scope — both test1 and test2 results"
screenshot_mid_test "OtegamiM7SearchUITests/testUnifiedScopeReturnsBothAccounts" "m7-04-cross-account.png"

echo "==> Phase 2/2, scenario (e): impossible query — zero-results empty state"
screenshot_mid_test "OtegamiM7SearchUITests/testNoMatchesShowsEmptyState" "m7-05-empty-state.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m7-01-two-char-japanese.png      (2-char "打ち" — LIKE fallback hit)
  $SCREENSHOT_DIR/m7-02-three-char-japanese-fts.png (3+ char "打ち合わせ" — FTS5 trigram MATCH hit)
  $SCREENSHOT_DIR/m7-03-english-query.png           ("html" — case-insensitive hit)
  $SCREENSHOT_DIR/m7-04-cross-account.png           ("ようこそ" — test1 + test2 both present)
  $SCREENSHOT_DIR/m7-05-empty-state.png             (impossible query — zero-results state)
EOF
