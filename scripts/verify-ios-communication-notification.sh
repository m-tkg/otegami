#!/usr/bin/env bash
# Communication Notification (送信者アバター + 右下にOtegamiアイコン合成)の
# 見た目確認 — NotificationService Extension経由ではなく、本体アプリから
# 出す1本のローカル通知で代用する。
#
# ============================================================================
# なぜNSE経由ではなく本体アプリのローカル通知なのか
# ============================================================================
# この機能の本来の実装は`apps/Otegami/NotificationService/
# NotificationService.swift`(`UNNotificationServiceExtension`)だが、
# `docs/verify.md`/`scripts/verify-ios-push-simulated.sh`のヘッダに記録
# 済みの既知の不調により、この開発機のシミュレータ/ツールチェーンでは
# `xcrun simctl push`を受けてもNSEプロセスが一切spawnされない
# (`xcrun simctl spawn <udid> log show --predicate 'process ==
# "NotificationService"'`が常に0件)。したがってNSE経由では見た目を
# 一切確認できない。
#
# `INInteraction.donate()`と`UNNotificationContent.updating(from:)`は
# どちらも本体アプリのプロセスからでも動作するAPIなので、本体アプリから
# 同じ形のCommunication Notificationをローカル通知として1本だけ出し、
# OSが実際にどう描画するか (アバターの合成、`NEW_MAIL_ACTIONS`カテゴリの
# アクションボタン) だけを確認する。この経路はアプリ側の検証専用コード
# (`apps/Otegami/Sources/Support/UITestFixtures/
# CommunicationNotificationVerify.swift`、`OTEGAMI_UITEST_VERIFY_
# COMMUNICATION_NOTIFICATION=1`でのみ動作) で、`CommunicationNotification
# .swift`の`CommunicationNotificationBuilder.donate(sender:)`の複製 —
# 本体の実装が変わったら合わせて直す必要がある。
#
# ============================================================================
# 既知の環境制約: 通知許可 (`.alert`) をタップ無しで付与する方法が無い
# ============================================================================
# この機能を実際に見るには、まずiOSの「通知を送信することを許可しますか」
# ダイアログで「許可」をタップする必要がある。このスクリプトを書く過程で
# 次を確認・検証済み:
#
#   1. `xcrun simctl privacy <udid> grant notifications <bundle>`は
#      そもそも`simctl privacy --help`が列挙するサービス一覧に
#      `notifications`を含んでいない (`calendar`/`contacts`/`photos`等は
#      あるが通知は無い) — 通知許可はTCCの管轄外で、`simctl privacy`に
#      バイパス手段が存在しない。`docs/verify.md`が記録する既知の不調
#      (「`Operation not permitted`で失敗する」)と符合する。
#   2. この開発機は**Simulator.appのGUIウィンドウ自体が存在しない**
#      (ヘッドレス — `osascript -e 'tell application "System Events" to
#      get name of every process'`にも"Simulator"プロセスが出てこない)。
#      `scripts/verify-macos-qa.sh`が使っているような「System Events で
#      ウィンドウを掴んで動かす」トリックはウィンドウの位置/サイズ操作
#      に限られ、シミュレータ画面の*中身*はAX要素ツリーを持たない単一の
#      描画サーフェスなので、たとえウィンドウがあってもクリック対象を
#      名前で特定することはできない (`.claude/skills/verify/SKILL.md`
#      「there's no simctl "UI automation" primitive」の通り)。ウィンドウ
#      自体が無いこの環境ではその代替 (座標クリック) すら成立しない。
#   3. 既存のXCUITestベースの許可フロー
#      (`grantNotificationPermissionViaPushSettings`in
#      `DovecotAccountUITestHelpers.swift`) は (a) 自前でホストする
#      push relayのURLがビルドに埋め込まれている必要がある
#      (`Config/Local.xcconfig`、この開発機には存在しない) ため
#      プッシュ通知トグル自体が無効化されて押せず、(b) 代替となりうる
#      「Dovecotアカウントを追加した副作用でBadgeCenterが通知許可を
#      要求し、XCTestの既定の割り込みハンドラが自動で解決する」経路も、
#      この開発機ではシミュレータ内IMAP接続そのものが失敗する既知の不調
#      (`docs/verify.md`) によって同じく塞がっている。
#
# 実際に検証した挙動 (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE=1`で
# アカウントを直接注入し、プレーンな`simctl launch`だけで確認):
# アプリはBadgeCenter経由で正しく許可ダイアログを表示する
# (`"Otegami-dev" Would Like to Send You Notifications`) が、タップする
# 手段が無いのでダイアログは`.notDetermined`のまま居座り続ける。
#
# **結論**: このスクリプトは他の全工程 (donation・ローカル通知のスケジュ
# ール・バックグラウンド遷移・スクリーンショット取得) をタップ不要で
# 正しく実行するが、**この開発機では通知許可ダイアログ自体を自動で
# 解消できない** — 実行すると許可ダイアログのスクリーンショットが撮れる
# だけで、Communication Notificationのバナー自体は撮れないことが
# 期待される。`Config/Local.xcconfig`にpush relayを設定してXCUITestで
# 許可を得るか、実機、あるいはSimulator.appのウィンドウが実際に存在する
# 環境 (人間が一度だけ手動で「許可」をタップできる) であれば、このスクリ
# プト自体の残りの手順はそのまま機能するはず — 一度手動で許可さえ与えれば
# (その決定は`simctl erase`しない限り永続する)、以降は`SKIP_PERMISSION_
# REQUEST=1`無しの通常実行で毎回バナーが撮れる。
#
# ============================================================================
# 使い方
# ============================================================================
#   scripts/verify-ios-communication-notification.sh
#
# Env:
#   IOS_SIMULATOR    Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR   Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID        App bundle id (default: com.mtkg.otegami)
#   SKIP_BUILD       1 = ビルド/インストールをスキップし、既にインストール
#                    済みのビルドをそのまま使う (default: 0)
#   ERASE_SIMULATOR  1 = 起動前に`simctl erase`(通知許可の決定も含めて
#                    真っさらにする、default: 0)。手動で一度「許可」を
#                    与えた後の繰り返し確認では0のままにすること —
#                    eraseするとその決定も失われる。
#   TRIGGER_DELAY    ローカル通知の発火までの秒数 (default: 6, `Communication
#                    NotificationVerify.swift`と揃える必要は無い —
#                    このスクリプトはトリガー時刻を知らず、単に十分な
#                    バッファを見てスクリーンショットをループするだけ)。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-0}"
TRIGGER_DELAY="${TRIGGER_DELAY:-6}"
DERIVED_DATA_PATH="/tmp/otegami-verify-communication-notification-derived-data"

mkdir -p "$SCREENSHOT_DIR"

resolve_simulator_udid

if [[ "$ERASE_SIMULATOR" == "1" ]]; then
  echo "==> Erasing simulator content (ERASE_SIMULATOR=1 — this also resets any previously-granted notification permission)"
  erase_simulator
fi

echo "==> Booting simulator (if needed)"
boot_simulator

# ヘッダに記載の通りこの開発機では成功しない見込みだが、`docs/verify.md`の
# 既存スクリプトの慣習 (`grant_contacts_privacy`と同じ「効かなくても実害の
# 無いbest-effort呼び出し」) に倣って一応試す。
xcrun simctl privacy "$UDID" grant notifications "$BUNDLE_ID" 2>/dev/null || true

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
  echo "==> Installing the just-built app (uninstall first for a genuinely fresh app container)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP_PATH"
fi

echo "==> Launching with OTEGAMI_UITEST_VERIFY_COMMUNICATION_NOTIFICATION=1"
# アカウント/メッセージのフィクスチャは一切注入しない — この検証は
# `CommunicationNotificationVerify`が単体で完結させる架空の差出人だけを
# 使うので、`OTEGAMI_UITEST_INSERT_FAKE_*`は不要 (むしろBadgeCenter経由の
# 別の`.badge`限定の許可要求が先に走ってしまい、後続の`.alert`込みの要求が
# 何も聞かれないまま determined 済み扱いになるのを避けたい)。
# `DISABLE_AVATAR_SOURCES=1`で連絡先権限ダイアログが割り込まないようにし、
# `DISABLE_CLOUD_SYNC=1`でこの検証に無関係なiCloud同期を止める — どちらも
# `scripts/verify-screen.sh`と同じ定番の組み合わせ。
env \
  SIMCTL_CHILD_OTEGAMI_UITEST_VERIFY_COMMUNICATION_NOTIFICATION=1 \
  SIMCTL_CHILD_OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES=1 \
  SIMCTL_CHILD_OTEGAMI_UITEST_DISABLE_CLOUD_SYNC=1 \
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent

echo "==> Waiting 2s, then screenshotting the permission-request moment"
sleep 2
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/communication-notification-00-permission-prompt.png"

# バナーを撮るにはアプリをバックグラウンドへ送る必要がある (フォアグラウンド
# だとバナーが出ないか見た目が異なる — `AppDelegate`は`willPresent`を実装
# しておらず、iOSの既定動作でフォアグラウンド中は表示されない)。別アプリ
# (設定App) を起動することで、Otegamiをterminateせずバックグラウンドへ
# 送る — ローカル通知はOS管理でプロセス生死に依存しないため、バックグラ
# ウンド化後もスケジュール済みのリクエストはそのまま発火する。
echo "==> Sending Otegami to the background (launching Settings)"
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1 || true

# `TRIGGER_DELAY`秒のトリガーに対して、起動直後の一回勝負のスクリーンショット
# は当たり外れが大きい (`docs/verify.md`のM6節と同じ理由) ため、発火が
# 見込まれる時間帯を跨いで複数回撮り、それぞれ別ファイルに残す。
echo "==> Polling for the notification banner across the trigger window"
for i in 1 2 3 4 5; do
  sleep 1
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/communication-notification-0$i-poll.png" 2>/dev/null || true
done

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/communication-notification-00-permission-prompt.png
    (直後の状態 — 通知許可ダイアログが写っているはず)
  $SCREENSHOT_DIR/communication-notification-0[1-5]-poll.png
    (トリガー(約${TRIGGER_DELAY}秒後)を跨いだ複数枚 — 許可が下りていれば
    この中のどれかにCommunication Notificationのバナーが写る)

このスクリプトのヘッダ「既知の環境制約」節の通り、通知許可 (.alert) を
タップ無しで付与する手段がこの開発機には無いため、上記のpollスクリーン
ショットは許可ダイアログが居座ったままの状態が写るだけの可能性が高い。
実際にバナーを確認できたかどうかは、これらのPNGを目で見て判断すること。
EOF
