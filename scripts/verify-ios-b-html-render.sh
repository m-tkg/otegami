#!/usr/bin/env bash
# 実機フィードバック第3弾 (B) verification: opens
# `26-marketing-wide-html.eml` (参考画像1相当 — a full <html><head>...<meta
# name="viewport" content="width=900">...</head><body> document with a
# 900px fixed-width wrapper table and a 900x300 image) and screenshots it.
# Ad-hoc, one-off script (not wired into a milestone number) — mirrors
# scripts/verify-ios-m2.sh's structure.
#
# Usage: scripts/verify-ios-b-html-render.sh [output-filename.png]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/build.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
OUT_NAME="${1:-b-html-marketing.png}"

mkdir -p "$SCREENSHOT_DIR"

resolve_simulator_udid

echo "==> Erasing simulator content"
erase_simulator

echo "==> Booting simulator"
boot_simulator
grant_contacts_privacy  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

if [[ "${SKIP_MAILSTACK_RESET:-0}" != "1" ]]; then
  echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
  make mailstack-up
  sleep 3
  make mailstack-seed
fi

echo "==> Regenerating Xcode project and building for testing"
xcodegen_generate
build_for_testing

screenshot_mid_test() {
  local test_id="$1"
  local out_name="$2"
  # Unlike verify-ios-m2.sh (whose account is already set up by a prior
  # test phase, so its own test's `Thread.sleep(4)` hold falls within a few
  # seconds of the xcodebuild invocation starting), this script's single
  # test method does its own account setup first (~60-70s of typing/taps),
  # so the message screen's final hold lands much later. Screenshotting
  # every 2s across a wide window (up to ~150s) rather than a short burst
  # right after start reliably lands at least one shot inside that hold
  # regardless of how long account setup itself takes on a given run.
  # Writes numbered frames (not one overwritten file) into a per-run
  # subdirectory — this test's own account-setup preamble takes a
  # variable, unpredictable amount of time before the message screen's
  # final `Thread.sleep(4)` hold, so there's no single fixed delay that
  # reliably lands *inside* that hold and nowhere else (too early: mid
  # account-setup; too late, past `kill` below: the home screen after
  # teardown). Numbered frames let this script pick the last few *before*
  # `kill` fires and report all of them, rather than gambling on one.
  local frames_dir="$SCREENSHOT_DIR/${out_name%.png}-frames"
  rm -rf "$frames_dir"
  mkdir -p "$frames_dir"
  (
    sleep 4
    i=0
    while true; do
      i=$((i + 1))
      xcrun simctl io "$UDID" screenshot "$(printf '%s/frame-%04d.png' "$frames_dir" "$i")" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  run_test "$test_id"
  # Kill the loop the instant xcodebuild returns (not `wait`, which would
  # block until the loop's own 150-iteration budget naturally runs out) —
  # anything captured *after* the test process exits is the home screen or
  # whatever comes next, not the message screen this script cares about.
  kill "$screenshot_pid" 2>/dev/null || true
  wait "$screenshot_pid" 2>/dev/null || true
}

echo "==> Running the wide-marketing-HTML verification UI test"
screenshot_mid_test "OtegamiWideMarketingHTMLUITests" "$OUT_NAME"

frames_dir="$SCREENSHOT_DIR/${OUT_NAME%.png}-frames"
last_frames="$(ls -1 "$frames_dir" 2>/dev/null | tail -6)"

cat <<EOF

==> Done.
Frames directory: $frames_dir
Last few frames captured before teardown (the message screen's hold should
be among these — check each, since account-setup timing varies run to run):
$last_frames
EOF
