#!/usr/bin/env bash
# Build otegami for iOS, export an Ad Hoc IPA, and publish it (+ the
# itms-services manifest.plist + an install page) to a self-hosted server
# so a registered iPhone can install it over the air. See
# docs/ota-deploy.md for the full picture.
#
# Usage: scripts/deploy-ota.sh   (or `make deploy-ota`), run from anywhere
# inside the repo. Requires apps/Otegami/Config/Local.xcconfig to exist
# with a real DEVELOPMENT_TEAM (see README's "Signing" section), SSH
# access to the deploy target, and the OTA_* variables below to be set —
# either as environment variables or in scripts/deploy-ota.local.sh
# (git-ignored; copy scripts/deploy-ota.local.sh.sample to get started).
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_DIR="apps/Otegami"
APP_PROJECT="$APP_DIR/Otegami.xcodeproj"
APP_SCHEME="Otegami"
LOCAL_XCCONFIG="$APP_DIR/Config/Local.xcconfig"
APP_ICON_1024="$APP_DIR/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

BUILD_DIR="dist/ota"
ARCHIVE_PATH="$BUILD_DIR/Otegami.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
EXPORT_LOG="$BUILD_DIR/export.log"

# Per-developer deploy target: no hardcoded default (this varies per person
# hosting their own OTA endpoint). Set as env vars, or once in
# scripts/deploy-ota.local.sh (see scripts/deploy-ota.local.sh.sample).
OTA_CONFIG_FILE="${OTA_CONFIG_FILE:-$REPO_ROOT/scripts/deploy-ota.local.sh}"
if [ -f "$OTA_CONFIG_FILE" ]; then
	# shellcheck source=/dev/null
	source "$OTA_CONFIG_FILE"
fi

OTA_PI_HOST="${OTA_PI_HOST:-}"
OTA_PI_DIR="${OTA_PI_DIR:-otegami-ota}"
OTA_BASE_URL="${OTA_BASE_URL:-}"

log() { printf '==> %s\n' "$1"; }
fail() {
	printf '\n!! %s\n' "$1" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[ -n "$OTA_PI_HOST" ] || fail "OTA_PI_HOST が未設定です。scripts/deploy-ota.local.sh.sample を scripts/deploy-ota.local.sh (git 管理外) にコピーし、自分の配信先 (例: user@host.example.com) を設定してください。"
[ -n "$OTA_BASE_URL" ] || fail "OTA_BASE_URL が未設定です。scripts/deploy-ota.local.sh で配信先の https URL (例: https://example.com/ota) を設定してください。"

[ -f "$LOCAL_XCCONFIG" ] || fail "$LOCAL_XCCONFIG がありません。README の \"Signing\" 節のとおり Config/Local.xcconfig.sample をコピーして DEVELOPMENT_TEAM を設定してください。"

DEVELOPMENT_TEAM="$(sed -n 's/^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$LOCAL_XCCONFIG" | tr -d '[:space:]')"
[ -n "$DEVELOPMENT_TEAM" ] || fail "$LOCAL_XCCONFIG に DEVELOPMENT_TEAM がありません。"

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen が見つかりません。'brew install xcodegen' でインストールしてください。"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild が見つかりません。Xcode をインストールしてください。"

log "アップロード先 (${OTA_PI_HOST}) への疎通を確認しています..."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$OTA_PI_HOST" 'mkdir -p '"$OTA_PI_DIR" \
	|| fail "ssh ${OTA_PI_HOST} に接続できませんでした (VPN/ネットワーク接続、SSH 鍵、ホスト名を確認してください)。"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

log "xcodegen generate"
(cd "$APP_DIR" && xcodegen generate)

log "dist/ota をクリーンアップ"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "xcodebuild archive (Release, ${DEVELOPMENT_TEAM})"
xcodebuild \
	-project "$APP_PROJECT" \
	-scheme "$APP_SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE_PATH" \
	-allowProvisioningUpdates \
	archive \
	|| fail "xcodebuild archive に失敗しました。署名エラーの場合は Apple Developer サイトで UDID/プロビジョニングプロファイルの状態を確認してください。"

# インストール画面 (manifest.plist の displayImageURL/fullSizeImageURL) 用
# のアイコン書き出し。App Store アイコン (1024x1024) から必要なサイズだけ
# 切り出す — transittimer/Scripts/ota.sh と同じやり方。
log "アイコン書き出し (インストール画面表示用)"
sips -z 57 57 "$APP_ICON_1024" --out "$BUILD_DIR/icon57.png" >/dev/null
sips -z 512 512 "$APP_ICON_1024" --out "$BUILD_DIR/icon512.png" >/dev/null

# manifest.plist は自分で書かず、ExportOptions.plist の `manifest` キーで
# xcodebuild -exportArchive 自身に生成させる (transittimer/Scripts/ota.sh
# と同じやり方)。以前はここを手書きし、bundle-version に git commit SHA を
# 埋め込んで「配信後に push 済み SHA と一致するか」を確認する運用だったが、
# xcodebuild が生成する bundle-version はアーカイブ実体の実際の
# CFBundleVersion (`Config/Shared.xcconfig` の CURRENT_PROJECT_VERSION) に
# なり、git SHA とは無関係になる — その代わりの確認手段として、この
# スクリプト自身が末尾で commit SHA をログ出力し、index.html にも埋め込む
# (docs/ota-deploy.md 参照)。
write_export_options() {
	cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$1</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>thinning</key>
	<string>&lt;none&gt;</string>
	<key>manifest</key>
	<dict>
		<key>appURL</key>
		<string>${OTA_BASE_URL}/otegami.ipa</string>
		<key>displayImageURL</key>
		<string>${OTA_BASE_URL}/icon57.png</string>
		<key>fullSizeImageURL</key>
		<string>${OTA_BASE_URL}/icon512.png</string>
	</dict>
</dict>
</plist>
PLIST
}

# xcodebuild's accepted -exportArchive `method` value for Ad Hoc distribution
# has changed name across Xcode versions ("ad-hoc" historically, newer
# tooling may expect "release-testing"). Try the candidates in order and
# stop retrying as soon as a failure looks unrelated to the method name
# itself (e.g. a real signing/provisioning problem), so that error surfaces
# instead of being masked by a second, equally-doomed attempt.
EXPORT_METHOD=""
for candidate in ad-hoc release-testing; do
	log "xcodebuild -exportArchive (method: ${candidate})"
	write_export_options "$candidate"
	rm -rf "$EXPORT_DIR"
	if xcodebuild -exportArchive \
		-archivePath "$ARCHIVE_PATH" \
		-exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
		-exportPath "$EXPORT_DIR" \
		-allowProvisioningUpdates \
		2>&1 | tee "$EXPORT_LOG"; then
		EXPORT_METHOD="$candidate"
		break
	fi
	if ! grep -qiE "not a valid value|invalid value|unknown method|must be one of" "$EXPORT_LOG"; then
		# Failed for a reason unrelated to the method name (signing,
		# provisioning, missing entitlement, ...) — retrying with the
		# other method name would just fail the same way. Stop here so
		# the real error above is what the caller sees.
		break
	fi
	log "'${candidate}' はこの Xcode で無効な method のようです。次の候補を試します。"
done

# Ad Hoc export は Apple Distribution 証明書と、それを含む provisioning
# profile を要求する。ローカルに Distribution 証明書が無い/Apple ID の
# アカウントセッションが xcodebuild から見えない環境 (実例: 2026-07-28 の
# 「No Accounts」障害) では両候補とも署名理由で失敗する。その場合は
# development 署名 (`debugging`) にフォールバックする — 配布先の実機は
# 開発デバイスとして登録済みなので、itms-services 経由のインストールは
# development 署名の IPA でも成立する (個人利用 OTA の割り切り)。
if [ -z "$EXPORT_METHOD" ] && grep -qiE "No signing certificate|doesn't include signing certificate|No Accounts" "$EXPORT_LOG"; then
	log "Distribution 署名が使えないため development 署名 (debugging) にフォールバックします"
	write_export_options "debugging"
	rm -rf "$EXPORT_DIR"
	if xcodebuild -exportArchive \
		-archivePath "$ARCHIVE_PATH" \
		-exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
		-exportPath "$EXPORT_DIR" \
		-allowProvisioningUpdates \
		2>&1 | tee "$EXPORT_LOG"; then
		EXPORT_METHOD="debugging"
	fi
fi

[ -n "$EXPORT_METHOD" ] || fail "xcodebuild -exportArchive が 'ad-hoc' / 'release-testing' / 'debugging' のいずれでも失敗しました。ログ: $EXPORT_LOG"

IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$IPA_PATH" ] && [ -f "$IPA_PATH" ] || fail "エクスポートは成功しましたが $EXPORT_DIR に .ipa が見つかりません。"
cp "$IPA_PATH" "$BUILD_DIR/otegami.ipa"
log "IPA を書き出しました ($(du -h "$BUILD_DIR/otegami.ipa" | cut -f1))"

MANIFEST_PATH="$EXPORT_DIR/manifest.plist"
[ -f "$MANIFEST_PATH" ] || fail "エクスポートは成功しましたが $EXPORT_DIR に manifest.plist が見つかりません (method: ${EXPORT_METHOD})。xcodebuild が ExportOptions.plist の manifest キーからの自動生成に対応していない可能性があります — export.log ($EXPORT_LOG) を確認してください。"
cp "$MANIFEST_PATH" "$BUILD_DIR/manifest.plist"

# ---------------------------------------------------------------------------
# install page
# ---------------------------------------------------------------------------

COMMIT_SHA="$(git rev-parse --short HEAD)"
BUILD_DATE_DISPLAY="$(date '+%Y-%m-%d %H:%M %Z')"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo '?')"
MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo '?')"

cat >"$BUILD_DIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Otegami OTA インストール</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 480px; margin: 3rem auto; padding: 0 1.25rem; color: #1c1c1e; }
  h1 { font-size: 1.4rem; }
  a.install { display: block; text-align: center; background: #007aff; color: #fff; text-decoration: none; padding: 0.9rem; border-radius: 12px; font-weight: 600; margin: 1.5rem 0; }
  dl { font-size: 0.9rem; color: #555; }
  dt { font-weight: 600; }
  dd { margin: 0 0 0.6rem 0; }
  p.note { font-size: 0.85rem; color: #777; }
</style>
</head>
<body>
<h1>Otegami OTA インストール</h1>
<p>下のボタンをタップすると Otegami (Ad Hoc ビルド) をインストールします。事前に登録済みの端末のみインストールできます。</p>
<a class="install" href="itms-services://?action=download-manifest&amp;url=${OTA_BASE_URL}/manifest.plist">インストール</a>
<dl>
	<dt>バージョン</dt>
	<dd>${MARKETING_VERSION} (${BUNDLE_VERSION})</dd>
	<dt>ビルド日時</dt>
	<dd>${BUILD_DATE_DISPLAY}</dd>
	<dt>コミット</dt>
	<dd>${COMMIT_SHA}</dd>
</dl>
<p class="note">「インストールできません」と出る場合は docs/ota-deploy.md のトラブルシューティングを参照してください（UDID 未登録、プロビジョニングプロファイル期限切れ、プライベート CA 未信頼などが典型的な原因です）。</p>
</body>
</html>
HTML

# ---------------------------------------------------------------------------
# Upload to the deploy target
# ---------------------------------------------------------------------------

log "アップロード中 (${OTA_PI_HOST}:${OTA_PI_DIR})"
rsync -avz \
	"$BUILD_DIR/otegami.ipa" \
	"$BUILD_DIR/manifest.plist" \
	"$BUILD_DIR/index.html" \
	"$BUILD_DIR/icon57.png" \
	"$BUILD_DIR/icon512.png" \
	"${OTA_PI_HOST}:${OTA_PI_DIR}/" \
	|| fail "アップロードに失敗しました (rsync)。ネットワーク/ディスク容量を確認してください。"

log "完了。iPhone の Safari で ${OTA_BASE_URL}/ を開いてインストールしてください。"
log "manifest: ${OTA_BASE_URL}/manifest.plist"
log "バージョン: ${MARKETING_VERSION} (${BUNDLE_VERSION}) / コミット: ${COMMIT_SHA}"
