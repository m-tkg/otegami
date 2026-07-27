#!/usr/bin/env bash
# HTML表示の高さ問題 (実機フィードバック — WebViewの表示エリアが画面の
# 半分程度で頭打ちになり、本文が途中で切れ、その下に大きな空白が残る) の
# 検証: `27-google-tos-style.eml` (Google利用規約風の長文HTML、`<head>`に
# MSO条件付きコメント+本文がクラス経由でしか見た目を制御しない<style>を
# 両方含む) を開き、末尾近くのテキストまで画面/アクセシビリティツリーに
# 現れることを確認する。scripts/verify-ios-b-html-render.sh と同じ構造。
#
# Usage: scripts/verify-ios-html-height.sh [output-filename.png]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
OUT_NAME="${1:-html-height-google-tos.png}"

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

echo "==> Erasing simulator content"
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"

echo "==> Booting simulator"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true

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

echo "==> Running the HTML-height verification UI test"
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:"OtegamiUITests/OtegamiHTMLHeightUITests" \
  test-without-building

echo "==> Done. Screenshot is attached to the test's own xcresult bundle"
echo "    (XCTAttachment, not a host-side file) — see the most recent"
echo "    ~/Library/Developer/Xcode/DerivedData/*/Logs/Test/*.xcresult"
echo "    and pull it with: xcrun xcresulttool get --legacy --format json ..."
