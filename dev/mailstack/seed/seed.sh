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

echo "==> done"
