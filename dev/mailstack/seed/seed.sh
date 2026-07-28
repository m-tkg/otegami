#!/usr/bin/env bash
# Loads the sample .eml fixtures in seed/fixtures/ into the dev mail stack's
# Dovecot INBOX, using `doveadm save` (the dovecot/dovecot image ships no
# shell, so this pipes each fixture's content through `docker compose exec`
# rather than copying files into a Maildir directly).
#
# Idempotent: each seeded user's INBOX is emptied (`doveadm expunge ... all`)
# before re-seeding, so running this repeatedly (e.g. once per verification
# run) reproduces the same fixed set of messages instead of accumulating
# duplicates. `doveadm expunge` on a mailbox that doesn't exist yet (first
# run against a fresh volume) exits non-zero; that's expected and harmless,
# hence `|| true`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAILSTACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

cd "$MAILSTACK_DIR"

reset_inbox() {
  local user="$1"
  echo "==> clearing $user INBOX (idempotent reseed)"
  docker compose exec -T dovecot doveadm expunge -u "$user" mailbox INBOX all || true
}

seed_message() {
  local user="$1"
  local file="$2"
  echo "==> seeding $(basename "$file") into $user INBOX"
  docker compose exec -T dovecot doveadm save -u "$user" -m INBOX < "$file"
}

reset_inbox "test1@otegami.test"
reset_inbox "test2@otegami.test"

seed_message "test1@otegami.test" "$FIXTURES_DIR/01-welcome.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/02-thread-original.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/03-thread-reply.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/04-newsletter.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/06-html-external-image.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/07-html-only-japanese.eml"
seed_message "test2@otegami.test" "$FIXTURES_DIR/05-test2-welcome.eml"

# M4: a References-linked test1<->test2 back-and-forth thread (3 messages,
# all delivered into test1's INBOX — this exercises the *threading* of a
# multi-party References chain, not real cross-account delivery; test2's
# own INBOX doesn't need a copy for that).
seed_message "test1@otegami.test" "$FIXTURES_DIR/09-thread-b-original.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/10-thread-b-reply.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/11-thread-b-reply2.eml"

# M4: a same-subject reply with no In-Reply-To/References at all, to
# exercise Threader's subject-fallback path (normalizedSubject match +
# participant overlap + 7-day window) independently of the References
# union-find path above.
seed_message "test1@otegami.test" "$FIXTURES_DIR/12-subject-fallback-original.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/13-subject-fallback-reply.eml"

# M8: attachment send/receive + cid inline images. A small PNG attachment,
# a Japanese-filename PDF attachment (RFC 2231 filename*=), and an HTML
# message with a cid:-referenced inline image — see docs/verify.md's M8
# section for what each backs.
seed_message "test1@otegami.test" "$FIXTURES_DIR/14-attachment-png.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/15-attachment-japanese-pdf.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/16-cid-inline-image.eml"

# RFC 2231 filename fallback: unlike 15-attachment-japanese-pdf.eml (RFC
# 2047 encoded-word filename, which the pinned mailcore2 revision parses
# natively), this attachment's Content-Disposition uses only RFC 2231's
# filename*0*=/filename*1*= continuation form — the gap
# MailCoreIMAPSession's raw-scan fallback (docs/roadmap.md) exists to cover.
seed_message "test1@otegami.test" "$FIXTURES_DIR/19-attachment-rfc2231-japanese.eml"

# QA sweep boundary-data scenario: a message with no Subject header at all
# (ThreadRow/MessageView's "(件名なし)" fallback) and one with a Subject but
# an empty body, both real edge cases a mail server can legitimately deliver.
seed_message "test1@otegami.test" "$FIXTURES_DIR/17-no-subject.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/18-empty-body.eml"

# design-phase-3: an English-language message (multi-paragraph, no Japanese
# at all) to exercise the translation bar (1i) end-to-end against the dev
# mailstack — `MessageLanguageDetector` should tag this `detectedLanguage ==
# "en"` on body fetch, which is what the translation bar's visibility check
# gates on.
seed_message "test1@otegami.test" "$FIXTURES_DIR/20-english-quarterly-report.eml"

# A9-A3 セキュリティ検証: WKWebView 側の JavaScript 無効化が実際に効いているかを
# 目視確認するための、悪意あるスクリプトを含む HTML メール4種
# (docs/verify.md の A9 節参照)。<script> による DOM 書き換え、
# onerror ハンドラでの背景色変更、iframe による外部コンテンツ埋め込み、
# javascript: スキームリンク。
seed_message "test1@otegami.test" "$FIXTURES_DIR/21-security-script-dom-rewrite.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/22-security-onerror-bgcolor.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/23-security-iframe.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/24-security-javascript-link.eml"

# C7「メール内リンクを開くブラウザ」検証用: 実在する外部リンクを1つ含む
# 通常の HTML メール (docs/verify.md の C7 節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/25-link-browser-test.eml"

# 実機フィードバック第3弾 (B) 検証用: 参考画像1相当のマーケティングHTML
# (完全な <html><head>...<meta name="viewport" content="width=900">...
# </head><body>...</body></html> ドキュメント、900px 固定幅のラッパー
# テーブル、900x300 の画像) — HTMLDocumentBuilder.extractBodyContent(from:)
# が無いと元メールの競合する viewport meta がこのアプリ自身の viewport
# meta を上書きし、デスクトップ幅でレイアウトされて拡大描画される
# (docs/verify.md の B 節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/26-marketing-wide-html.eml"

# HTML表示の高さ問題検証用: 実機報告 (WebView表示エリアが画面半分で頭打ち、
# 本文が途中で切れ、下に空白が残る) 相当の Google 利用規約風 HTML —
# <head> に MSO 条件付きコメント (中に "<body"/"</body>" という文字列を
# 含むフォールバック骨格、Outlook向けテンプレートで一般的なパターン) と、
# 本文がクラス経由でしか見た目を制御していない <style> ブロックを両方含む
# 長文メール (docs/verify.md の該当節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/27-google-tos-style.eml"

# 画像バナー統合検証用: 埋め込み (cid:) とリモート (http:) 両方の画像
# 参照を持つメール — 両方ブロックされている状態で「画像を表示」バナーが
# メニュー (Menu) になり、2つの選択肢を出すことを確認する
# (docs/verify.md の該当節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/28-both-image-kinds.eml"

# fit-to-width 検証用 (実機フィードバック — 楽天銀行のような幅600-800px級の
# 固定幅テーブルHTMLメールが等倍描画され、右端がクリップ・文字が巨大に
# 見える): 幅700pxの中央寄せテーブル + 画像 + 罫線 + white-space: nowrap の
# ラベル/値行 + 改行なしの区切り線、という実在の銀行通知メールに近い構造
# (docs/verify.md/docs/design-system.md 該当節参照)。29 は日本語 (実機報告と
# 同じ言語)、30 はその英語版 — 1i の HTML レイアウト保持翻訳の検証にも使う
# (fit-to-width と翻訳の両方が同じ固定幅テーブル構造に対して効くことを
# 1通で確認できる)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/29-fixed-width-bank-notice.eml"
seed_message "test1@otegami.test" "$FIXTURES_DIR/30-fixed-width-notice-en.eml"

# Task #45 検証用: 実機報告 (Google のセキュリティ通知メールで、ダーク
# モードだと暗地に暗文字でほぼ読めない/罫線から下の本文が描画されない)
# を再現する構造 — 白背景・濃色文字を明示指定 (自前のダークモード対応
# なし)、中央寄せの角丸カード、cid: 画像 (ロゴ + アバター、height: auto
# !important のCSSリセットにより読み込み完了までレイアウト高さが確定
# しない)、罫線の下に本文2段落 + CTA ボタン、fit-to-width の scale
# パスを決定的に踏ませる nowrap の注記行、という組み合わせ
# (docs/design-system.md の Task #45 節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/31-security-notice-dark-mode.eml"

# Task #51 検証用 (Task #45 の退行修正): 31 と対になる、背景色・文字色を
# 一切指定しないシンプルな HTML メール — ダークモードで開いても
# `HTMLDocumentBuilder` の CSS リセットだけで元々正しく読めていたはずが、
# Task #45 の無条件反転がこれを暗地に暗文字へ壊していた実機退行の再現
# ケース (docs/design-system.md の Task #51 節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/32-plain-html-no-colors.eml"

# Task #56 検証用: 実機報告 (TestFlight風の通知メールで、アプリアイコン
# 画像が画面幅いっぱいに引き伸ばされる/背景色を指定しないまま文字色だけ
# #444 系で明示指定していてダークモードで暗地に暗文字になる/本文が
# 途中で切れる/要約・翻訳フローティングボタンが本文に被る、という4点が
# 同時に発生) を再現する構造 — 背景色なし・#444 濃色文字を明示指定、
# 中央寄せの cid: 画像 (`width`属性 + `style="width:100%;
# max-width:120px;"`という業界標準の「レスポンシブだが上限あり」画像
# 手法、Apple/主要ESPのテンプレートで頻出)、リンク数本、複数段落
# (docs/design-system.md の Task #56 節参照)。
seed_message "test1@otegami.test" "$FIXTURES_DIR/33-beta-testing-notice.eml"

# 実機フィードバック検証用 (MakerWorld実メールとの比較報告 — ダークモード
# のスマート反転で(1) 右端に縦の白帯、(2) セクション間の色ムラ、(3) 透過
# PNGロゴが暗背景に沈む、の3点): MakerWorldの構造 (白背景をbody自身に
# 明示指定、中央寄せの透過PNGロゴ、薄グレーの角丸カード、緑のCTAボタン)
# を模した最小構成。ロゴ画像は120x40の透過PNG (黒の線画ブロック、
# ロゴチップ判定の閾値200px以下に収まるサイズ) — `HTMLDocumentBuilder
# .wrap`の`<style>`コメント/`fitToWidthScript`の`decideLogoChips`参照。
seed_message "test1@otegami.test" "$FIXTURES_DIR/34-white-canvas-transparent-logo.eml"

# Task #76 検証用: 添付ファイルのカード表示 (ファイル名2行省略、サイズ表示)
# を確認するための、長い日本語ファイル名 (RFC 2047 encoded-word) の PDF
# 添付メール — 14/15/19 の短いファイル名だけでは2行折り返し・省略の見た目を
# 確認できないため追加。
seed_message "test1@otegami.test" "$FIXTURES_DIR/35-attachment-long-filename.eml"

echo "==> done"
