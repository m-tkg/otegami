#!/usr/bin/env bash
# Task #60 (シミュレータ検証基盤の整備): tap-free スクリーンショット取得の
# 標準手段。
#
# docs/verify.md の「シミュレータ検証の既知の不調」参照 — このシミュレータ/
# ツールチェーンでは (1) IMAP接続不能 (MailCoreErrorDomain error 1)、
# (2) XCUITestのタップ不達 (特に一覧行→本文遷移)、(3) 連絡先権限ダイアログの
# 非決定的な出現、(4) Foundation Modelsのサンドボックスエラー -1、の4つが
# 繰り返し検証を妨げてきた。このスクリプトは (2)(3) を迂回する「タップ不要」
# 経路だけを使い、XCUITestランナー (`xcodebuild test`) そのものを一切起動
# しない:
#
#   1. `xcodebuild build` (`build-for-testing`ではない — テストバンドルは
#      不要) でアプリだけをビルド。
#   2. `xcrun simctl install` でシミュレータへインストール。
#   3. `xcrun simctl launch` で起動。フィクスチャ選択は `AppEnvironment
#      .init()`のDB直接注入フラグ (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`
#      等) を**環境変数**として、画面遷移は`-uiTestsAutoAdvanceToContent`/
#      `-uitestsOpenSettingsDirectly`を**起動引数**として与える。`simctl
#      launch`自体には環境変数を渡すフラグが無く、呼び出し元シェルの
#      `SIMCTL_CHILD_<NAME>`プレフィクス付き環境変数だけが子プロセスへ
#      引き継がれる (`xcrun simctl launch --help`の最終行に明記) — この
#      スクリプトが `SIMCTL_CHILD_OTEGAMI_UITEST_...` という形で export
#      しているのはそのため。
#   4. 数秒待ってから `xcrun simctl io screenshot`。
#
# `OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1` (Task #60で追加) を既定で常に
# 付与する — 連絡先/Google/Gravatar/企業ロゴのアバター解決を全部スキップし、
# 上記(3)の連絡先権限ダイアログが原理的に発生し得ないようにする。
#
# 同じ理由で `OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1`
# (Task #60で追加、`BadgeCenter.requestAuthorizationIfNeeded()`参照) も既定
# で付与する — アカウントが1件でもあれば起動直後にOSの「通知を送信する
# ことを許可しますか」ダイアログが出て最初のスクリーンショットを埋めて
# しまう。`simctl privacy grant notifications`はこの開発機のランタイムでは
# `Operation not permitted`で使えなかったため、アプリ側にエスケープハッチを
# 追加した。
#
# Usage:
#   scripts/verify-screen.sh <scenario> [output-filename.png]
#
# Scenarios:
#   html-0 / html-security-notice      31番相当のフィクスチャ本文画面
#                                       (白背景+濃色文字、ダークモードで反転対象)
#   html-1 / html-no-colors            32番相当 (色指定なし、反転させない)
#   html-2 / html-self-dark-aware      自前ダーク対応宣言あり (反転させない)
#   html-3 / html-beta-testing-notice  33番相当 (背景なし+#444文字+cid画像、
#                                       高さ切れ修正のTask #58/#59対象)
#   html-4 / html-makerworld-like       34番相当 (body自身が白背景を明示+
#                                       透過PNGロゴ+薄グレーのカード+緑
#                                       ボタン — 実機報告のMakerWorld比較:
#                                       ダーク反転時の右端白帯/セクション間
#                                       色ムラ/透過ロゴが暗背景に沈む、の
#                                       3点の確認用)
#   list                                統合受信トレイの一覧画面 (fakeメッセージ5件)
#   settings                            設定画面 (SettingsSheetView)
#   account-settings                    Task #72: 設定→アカウントの設定
#                                       (fake Gmail アカウント1件を挿入、
#                                       一覧行の色ドットを確認)
#   account-edit                        Task #72: ↑からさらに1画面 (先頭
#                                       アカウントの編集画面 — ラベル色の
#                                       グリッドピッカーを確認)
#
# 上5つの`html-*`は `AppEnvironment.uitestFakeHTMLMessages`の0〜4番目
# (`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`の値と対応) — 実体は
# `dev/mailstack/seed/fixtures/31/32/33/34-*.eml`と同内容のSwift文字列
# リテラル (自前ダーク対応は.emlフィクスチャなし、AppEnvironment内にのみ
# 存在)。
#
# Env:
#   IOS_SIMULATOR    Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR   Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID        App bundle id (default: com.mtkg.otegami)
#   APPEARANCE       light|dark — `simctl ui ... appearance`をlaunch前に
#                    設定する。未指定ならシミュレータの現在値のまま。
#   DISABLE_AVATAR_SOURCES  0にするとアバターdisableフラグを付けない
#                           (連絡先権限ダイアログの実際の見た目を確認したい
#                           ときだけ; 既定 1)
#   SKIP_BUILD       1 = ビルド/インストールをスキップし、既にインストール
#                    済みのビルドをそのまま使う (`list`/`settings`など
#                    フィクスチャ挿入を伴わない/1回で足りるシナリオの
#                    繰り返し確認向け高速化用)。**注意**: `html-*`は
#                    フィクスチャ挿入が「同じ install内で1回だけ」しか
#                    効かない (下記) ので、`SKIP_BUILD=1`で別の
#                    `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`へ切り替え
#                    ても直接遷移は発火せず一覧のままになる — 別indexを
#                    試すときは`SKIP_BUILD=0`(既定)のままにすること。
#   ERASE_SIMULATOR  1 = 起動前に `simctl erase` (シミュレータ全体を真っさら
#                    にする、既定は0)。`SKIP_BUILD=0`(既定)の通常経路は
#                    ビルドのたびに`simctl uninstall`→`install`でアプリの
#                    GRDBも毎回まっさらにする (下記) ので、`html-*`の直接
#                    遷移だけが目的ならこれは通常不要 — Springboard自体の
#                    初回ブート待ちが余分にかかるだけ遅い。真に「初回起動」
#                    の見た目 (通知許可ダイアログを敢えて見る等) を確認
#                    したいときだけ使う。
#   WAIT_SECONDS     起動〜スクリーンショットまでの待ち時間 (default: 4)。
#                    `ERASE_SIMULATOR=1`の直後は初回ブートでSpringboard/
#                    アプリの初期化が普段より遅く、4秒では足りないことが
#                    あった (実測: 10秒で安定) — `ERASE_SIMULATOR=1`と
#                    併用するときは`WAIT_SECONDS=10`以上を指定すること。
#
# 既存の `OTEGAMI_UITEST_*` launch-environment flags のうち、このスクリプト
# が使わないもの (`rg 'OTEGAMI_UITEST_' apps/Otegami/Sources/AppEnvironment.swift`
# で棚卸し済み — 各詳細はそのファイル自身のドキュメントコメント参照。他の
# `scripts/verify-ios-*.sh`/`OtegamiUITests`が個別の目的で使う):
#   OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE
#   OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID
#   OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE
#   OTEGAMI_UITEST_FAKE_TRANSLATION
#   OTEGAMI_UITEST_DISABLE_CLOUD_SYNC
# launch *引数* (環境変数ではない) も同様に一部未使用のものがある:
#   -uiTestsSkipThreadRestoration
#   -otegamiEnableCloudSyncInSimulator
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCENARIO="${1:-}"
if [[ -z "$SCENARIO" ]]; then
  echo "usage: scripts/verify-screen.sh <scenario> [output-filename.png]" >&2
  echo "       see this script's own header comment for the scenario list" >&2
  exit 1
fi

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
APPEARANCE="${APPEARANCE:-}"
DISABLE_AVATAR_SOURCES="${DISABLE_AVATAR_SOURCES:-1}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-4}"
DERIVED_DATA_PATH="/tmp/otegami-verify-screen-derived-data"

mkdir -p "$SCREENSHOT_DIR"

# シナリオ → (launch env vars / launch args / 既定の出力ファイル名)。
launch_env=("OTEGAMI_UITEST_DISABLE_CLOUD_SYNC=1") # 一覧・本文どちらもクラウド同期は不要 (`docs/verify.md`と同じ理由)
launch_args=("-uiTestsAutoAdvanceToContent")
default_out=""

case "$SCENARIO" in
  html-0|html-security-notice)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1" "OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=0")
    default_out="html-0-security-notice.png"
    ;;
  html-1|html-no-colors)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1" "OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=1")
    default_out="html-1-no-colors.png"
    ;;
  html-2|html-self-dark-aware)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1" "OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=2")
    default_out="html-2-self-dark-aware.png"
    ;;
  html-3|html-beta-testing-notice)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1" "OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=3")
    default_out="html-3-beta-testing-notice.png"
    ;;
  html-4|html-makerworld-like)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1" "OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX=4")
    default_out="html-4-makerworld-like.png"
    ;;
  list)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1")
    default_out="list.png"
    ;;
  settings)
    launch_args+=("-uitestsOpenSettingsDirectly")
    default_out="settings.png"
    ;;
  account-settings)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1")
    launch_args+=("-uitestsOpenSettingsDirectly" "-uitestsOpenAccountSettingsDirectly")
    default_out="account-settings.png"
    ;;
  account-edit)
    launch_env+=("OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT=1")
    launch_args+=("-uitestsOpenSettingsDirectly" "-uitestsOpenAccountSettingsDirectly" "-uitestsOpenFirstAccountEditDirectly")
    default_out="account-edit.png"
    ;;
  *)
    echo "error: unknown scenario '$SCENARIO' — see this script's header comment for the list" >&2
    exit 1
    ;;
esac

if [[ "$DISABLE_AVATAR_SOURCES" == "1" ]]; then
  launch_env+=("OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1")
fi
launch_env+=("OTEGAMI_UITEST_DISABLE_NOTIFICATION_PERMISSION_REQUEST=1")

OUT_NAME="${2:-$default_out}"
OUT_PATH="$SCREENSHOT_DIR/$OUT_NAME"

echo "==> Resolving simulator UDID for '$IOS_SIMULATOR'"
UDID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$IOS_SIMULATOR" '
  $0 ~ name && $0 !~ /unavailable/ { print $2; exit }
')"
if [[ -z "$UDID" ]]; then
  echo "error: no available simulator matching '$IOS_SIMULATOR'" >&2
  exit 1
fi
echo "    UDID: $UDID"

if [[ "$ERASE_SIMULATOR" == "1" ]]; then
  echo "==> Erasing simulator content (ERASE_SIMULATOR=1)"
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID"
fi

echo "==> Booting simulator (if needed)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
# 保険 — DISABLE_AVATAR_SOURCES=0 で連絡先解決自体を確認したい場合や、
# フラグ導入前にインストールされた古いビルドが動いている場合でも権限
# ダイアログで待たされないようにする (`docs/verify.md`の既存の対策と同じ)。
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true

if [[ -n "$APPEARANCE" ]]; then
  echo "==> Setting appearance to '$APPEARANCE'"
  xcrun simctl ui "$UDID" appearance "$APPEARANCE"
fi

if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "==> SKIP_BUILD=1 — reusing whatever's already installed"
else
  echo "==> Regenerating Xcode project and building (app only, no test bundle)"
  (cd apps/Otegami && xcodegen generate)
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Otegami.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: could not locate the built Otegami.app at $APP_PATH" >&2
    exit 1
  fi
  # Reinstalling *over* a previous install would keep that install's GRDB
  # database (and App Group container) around — every `OTEGAMI_UITEST_
  # INSERT_FAKE_*`フィクスチャ挿入は「同じメールアドレスの行が既に無ければ
  # 挿入」というガード付き (`AppEnvironment.init()`の各ブロック参照) なので、
  # 2回目以降の launch では何も挿入されず、`OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`
  # による本文への直接遷移も (挿入ブロック自体がスキップされる以上)
  # 発火しない — 一覧画面のまま止まって見える。`uninstall`してから
  # `install`することで、この (build-and-install する) 通常経路は毎回
  # 「まっさらな新規インストール」になり、`html-*`シナリオが常に本文まで
  # 直行できるようにする (`ERASE_SIMULATOR=1`のようなシミュレータ全体の
  # 消去より軽い — Springboardの再起動や通知許可の決定は保持される)。
  echo "==> Installing the just-built app (uninstall first for a genuinely fresh app container)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP_PATH"
fi

echo "==> Launching '$SCENARIO' (env: ${launch_env[*]} / args: ${launch_args[*]})"
# `simctl launch`自身はenvを渡すフラグを持たない — 呼び出し元シェルの
# `SIMCTL_CHILD_<NAME>`環境変数だけが子プロセスへ引き継がれる
# (`xcrun simctl launch --help`参照)。`env`コマンドでその場限りの
# `SIMCTL_CHILD_*`を組み立てて渡す。
env_args=()
for kv in "${launch_env[@]}"; do
  env_args+=("SIMCTL_CHILD_${kv}")
done
env "${env_args[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" "${launch_args[@]}"

echo "==> Waiting ${WAIT_SECONDS}s for the view to settle"
sleep "$WAIT_SECONDS"

echo "==> Screenshot -> $OUT_PATH"
xcrun simctl io "$UDID" screenshot "$OUT_PATH"

echo "==> Done: $OUT_PATH"
