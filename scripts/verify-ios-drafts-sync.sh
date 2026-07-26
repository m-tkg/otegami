#!/usr/bin/env bash
# Drafts IMAP sync automated verification.
#
# Host-interleaved phases, same pattern as verify-ios-m3.sh/m4.sh/m5.sh
# (XCUITest can't shell out to `docker compose`/`doveadm` itself — see
# docs/verify.md's note on `Foundation.Process` being unavailable there):
#
#   1. OtegamiDraftsSyncSetupUITests          add test1 (with SMTP), confirm
#                                              the seeded baseline renders.
#   2. OtegamiDraftsSyncSaveUITests           compose a new message, cancel,
#                                              choose "下書きとして保存".
#   3. (host) doveadm                         confirm exactly one message
#                                              landed in Drafts, with the
#                                              \Draft flag.
#   4. OtegamiDraftsSyncEditUITests           open Drafts, resume the draft,
#                                              edit its body, save again.
#   5. (host) doveadm                         confirm still exactly one
#                                              message in Drafts (replaced,
#                                              not duplicated).
#   6. OtegamiDraftsSyncSendUITests           resume the (edited) draft
#                                              again and send it.
#   7. (host) Mailpit REST API + doveadm      confirm the message was
#                                              delivered, and its Drafts
#                                              copy was deleted.
#   8. (host) doveadm save                    inject an .eml directly into
#                                              Drafts (another IMAP client's
#                                              draft) and relaunch the app.
#   9. OtegamiDraftsSyncExternalDraftUITests  confirm the externally-written
#                                              draft surfaces in the unified
#                                              Drafts list, opens with its
#                                              body legible, and closing it
#                                              unedited prompts no save/
#                                              discard dialog.
#  10. (host) doveadm                         confirm that draft is STILL
#                                              present server-side (opening
#                                              it without editing must not
#                                              delete anything).
#
# Usage: scripts/verify-ios-drafts-sync.sh
# Env:
#   IOS_SIMULATOR         Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR        Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID             App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
MAILSTACK_USER="test1@otegami.test"
MAILPIT_API="http://localhost:8025/api/v1"

DRAFT_SUBJECT="otegami Drafts統合テスト下書き"
SENT_SUBJECT="otegami Drafts統合テスト下書き"
EXTERNAL_SUBJECT="otegami 他クライアント下書き統合テスト"
EXTERNAL_BODY_MARKER="外部クライアントが書いた下書き本文マーカー"

mkdir -p "$SCREENSHOT_DIR"

run_test() {
  local test_id="$1"
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"OtegamiUITests/$test_id" \
    test-without-building
}

screenshot() {
  local name="$1"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

doveadm() {
  docker compose -f "$ROOT_DIR/dev/mailstack/compose.yml" exec -T dovecot doveadm "$@"
}

drafts_message_count() {
  doveadm mailbox status -u "$MAILSTACK_USER" messages Drafts 2>/dev/null | sed -E 's/.*messages=([0-9]+).*/\1/'
}

mailpit_find_id() {
  local subject="$1"
  curl -s "$MAILPIT_API/messages?limit=50" | python3 -c "
import json, sys
subject = sys.argv[1]
data = json.load(sys.stdin)
for m in data.get('messages', []):
    if m.get('Subject') == subject:
        print(m['ID'])
        break
" "$subject"
}

echo "==> Resolving simulator UDID for '$IOS_SIMULATOR'"
UDID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$IOS_SIMULATOR" '
  $0 ~ name && $0 !~ /unavailable/ { print $2; exit }
')"
if [[ -z "$UDID" ]]; then
  echo "error: no available simulator matching '$IOS_SIMULATOR'" >&2
  exit 1
fi
echo "    UDID: $UDID"

echo "==> Booting simulator (if needed)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Clearing Mailpit's message store and Dovecot's Drafts/Sent mailboxes (clean slate for this run)"
curl -s -X DELETE "$MAILPIT_API/messages" -H "Content-Type: application/json" -d '{"IDs":[]}' >/dev/null
doveadm expunge -u "$MAILSTACK_USER" mailbox Drafts all || true
doveadm expunge -u "$MAILSTACK_USER" mailbox Sent all || true

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS)"
# See verify-ios-m5.sh's identical step for why `erase`, not `uninstall`
# (M11: iCloud KVS/Keychain survive a plain uninstall on this simulator).
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/10: add test1 account with SMTP, confirm baseline"
run_test "OtegamiDraftsSyncSetupUITests"

echo "==> Phase 2/10: compose a new message, save as draft"
run_test "OtegamiDraftsSyncSaveUITests"

echo "==> Phase 3/10: confirm exactly one message landed in Drafts, with \\Draft"
draft_ok=0
for _ in $(seq 1 15); do
  count="$(drafts_message_count)"
  if [[ "$count" == "1" ]] && doveadm fetch -u "$MAILSTACK_USER" flags mailbox Drafts HEADER Subject "$DRAFT_SUBJECT" 2>/dev/null | grep -q '\\Draft'; then
    draft_ok=1
    break
  fi
  sleep 1
done
if [[ "$draft_ok" != "1" ]]; then
  echo "error: saved draft never landed in Drafts with the \\Draft flag (count=$(drafts_message_count))" >&2
  exit 1
fi
echo "    OK: 1 message in Drafts, \\Draft flag confirmed"

echo "==> Capturing screenshot: after save-as-draft"
screenshot "drafts-01-saved.png"

echo "==> Phase 4/10: resume the draft, edit it, save again"
run_test "OtegamiDraftsSyncEditUITests"

echo "==> Phase 5/10: confirm still exactly one message in Drafts (replaced, not duplicated)"
replace_ok=0
for _ in $(seq 1 15); do
  if [[ "$(drafts_message_count)" == "1" ]]; then
    replace_ok=1
    break
  fi
  sleep 1
done
if [[ "$replace_ok" != "1" ]]; then
  echo "error: editing and re-saving the draft left something other than exactly 1 message in Drafts (count=$(drafts_message_count))" >&2
  exit 1
fi
echo "    OK: still exactly 1 message in Drafts after edit + resave"

echo "==> Capturing screenshot: after edit + resave"
screenshot "drafts-02-edited.png"

echo "==> Phase 6/10: resume the draft again and send it"
run_test "OtegamiDraftsSyncSendUITests"

echo "==> Phase 7/10: confirm delivery via Mailpit and Drafts cleanup via doveadm"
sent_message_id=""
for _ in $(seq 1 15); do
  sent_message_id="$(mailpit_find_id "$SENT_SUBJECT")"
  [[ -n "$sent_message_id" ]] && break
  sleep 1
done
if [[ -z "$sent_message_id" ]]; then
  echo "error: the message resumed from a draft never reached Mailpit" >&2
  exit 1
fi
echo "    OK: found in Mailpit (id=$sent_message_id)"

cleanup_ok=0
for _ in $(seq 1 15); do
  if [[ "$(drafts_message_count)" == "0" ]]; then
    cleanup_ok=1
    break
  fi
  sleep 1
done
if [[ "$cleanup_ok" != "1" ]]; then
  echo "error: the Drafts copy was not deleted after a successful send (count=$(drafts_message_count))" >&2
  exit 1
fi
echo "    OK: Drafts copy deleted after send"

echo "==> Capturing screenshot: after send"
screenshot "drafts-03-sent.png"

echo "==> Phase 8/10: inject a draft directly into Drafts (another IMAP client) and relaunch"
external_eml="From: Other Client <other@otegami.test>
To: draftsync-external@otegami.test
Subject: ${EXTERNAL_SUBJECT}
Message-Id: <draftsync-external@otegami.test>
Date: Mon, 1 Jan 2024 00:00:00 +0900
Content-Type: text/plain; charset=utf-8

${EXTERNAL_BODY_MARKER}
"
printf '%s' "$external_eml" | doveadm save -u "$MAILSTACK_USER" -m Drafts
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -uiTestsAutoAdvanceToContent >/dev/null
sleep 5 # let scenePhase == .active's incremental sync (now covering Drafts too) run
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Phase 9/10: confirm the externally-written draft surfaces, and closing it unedited is a no-op"
run_test "OtegamiDraftsSyncExternalDraftUITests"

echo "==> Capturing screenshot: external draft opened in Composer"
screenshot "drafts-04-external.png"

echo "==> Phase 10/10: confirm the externally-written draft is STILL present server-side"
if [[ "$(drafts_message_count)" != "1" ]]; then
  echo "error: opening the server-origin draft without editing it should not have deleted it (count=$(drafts_message_count))" >&2
  exit 1
fi
if ! doveadm fetch -u "$MAILSTACK_USER" flags mailbox Drafts HEADER Subject "$EXTERNAL_SUBJECT" 2>/dev/null | grep -q 'flags'; then
  echo "error: the externally-written draft is no longer findable by subject in Drafts" >&2
  exit 1
fi
echo "    OK: externally-written draft survived an unedited open — no data loss"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/drafts-01-saved.png    (composer dismissed after save-as-draft)
  $SCREENSHOT_DIR/drafts-02-edited.png   (composer dismissed after resume+edit+resave)
  $SCREENSHOT_DIR/drafts-03-sent.png     (composer dismissed after resuming the draft and sending)
  $SCREENSHOT_DIR/drafts-04-external.png (server-origin draft open in Composer, prefilled)
EOF
