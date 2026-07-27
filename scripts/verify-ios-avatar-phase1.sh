#!/usr/bin/env bash
# アバター強化バッチ (フェーズ1「連絡先の写真」/フェーズ2「Gravatar」) の
# 軽量検証: 設定 →「メール一覧」に両トグルが現れ、操作できることを確認
# する。アカウント0件でも到達できる (ハンバーガーメニューは常設) ため、
# mailstack への依存は無い — `SKIP_MAILSTACK_RESET`未指定時に呼ぶ
# `make mailstack-up`/`seed`はこのスクリプト自体には不要だが、他の
# `verify-ios-*.sh`と揃えておくと環境準備コマンドを使い分けずに済むため
# 残してある (無くても本検証は通る)。
#
# アカウント0件の初回起動直後だけ、ハンバーガー→設定の遷移が
# `settingsSheet.navigationStack`のタイムアウトで失敗する現象を発見した
# (このプロジェクトの他の全テストが「少なくとも1回何かに成功した後で」
# ハンバーガーメニューを開いており、真に何もしていない初回フレームでこの
# 遷移を試すテストが無かったための simulator/toolchain 固有の不安定さと
# 見ている) — `OtegamiAvatarSettingsUITests`側で数秒の猶予 + リトライに
# より回避済み。
#
# 画面 (`SettingsSheetView`) は GRDB 非永続 (シート/画面遷移状態) なので、
# M6 と同じ「テスト実行中にホストからスクリーンショットを撮る」方式を使う
# (`docs/verify.md`のM6節参照)。
#
# Usage: scripts/verify-ios-avatar-phase1.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"

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
  -only-testing:OtegamiUITests/OtegamiAvatarSettingsUITests \
  build-for-testing test-without-building &
TEST_PID=$!

# Screenshot repeatedly while the test runs, overwriting the same file —
# the target screen's exact visible window varies run to run (M6's doc
# comment), so this beats guessing a single fixed delay.
(
  for _ in $(seq 1 60); do
    xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/avatar-phase1-settings.png" 2>/dev/null || true
    sleep 1
  done
) &
SCREENSHOT_PID=$!

wait "$TEST_PID"
TEST_EXIT=$?
kill "$SCREENSHOT_PID" 2>/dev/null || true
wait "$SCREENSHOT_PID" 2>/dev/null || true

echo "==> Screenshot: $SCREENSHOT_DIR/avatar-phase1-settings.png"
exit "$TEST_EXIT"
