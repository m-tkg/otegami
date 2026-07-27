#!/usr/bin/env bash
# M5 (Compose/Reply/SMTP + Outbox + Sent APPEND) automated verification.
#
# XCUITest can't shell out to `docker compose`/`curl` from inside the
# simulator's sandbox (`Foundation.Process` is unavailable on iOS — the
# same limitation M3/M4's scripts document), so the host wrapper drives
# every server-side assertion (Mailpit REST API, doveadm) between XCUITest
# phases, same pattern as verify-ios-m3.sh/verify-ios-m4.sh:
#
#   1. OtegamiM5SetupUITests               add the test1 Dovecot account
#                                           with SMTP fields filled in
#                                           (Mailpit, localhost:1025),
#                                           confirm the SMTP connection
#                                           test succeeds and the seeded
#                                           baseline still renders.
#   2. OtegamiM5ComposeSendUITests         compose a brand-new message,
#                                           send it.
#   3. (host) Mailpit REST API             confirm the message arrived,
#      (host) doveadm                      and a Sent-mailbox copy landed
#                                           via the best-effort APPEND.
#   4. OtegamiM5ReplyUITests               open the seeded "ようこそ
#                                           otegami へ" message, tap 返信,
#                                           confirm prefill, send.
#   5. (host) Mailpit REST API             confirm In-Reply-To/References
#                                           headers on the sent reply.
#   6. (host) mailstack-down
#   7. OtegamiM5OfflineComposeUITests      compose+send while offline;
#                                           confirm the "送信待ち" indicator
#                                           appears (local-only, no network).
#   8. (host) mailstack-up
#   9. OtegamiM5OfflineReplayUITests       relaunch; scenePhase-.active
#                                           opQueue replay should flush the
#                                           queued send and clear the
#                                           indicator.
#  10. (host) Mailpit REST API             confirm the offline-composed
#                                           message eventually arrived.
#
# Usage: scripts/verify-ios-m5.sh
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

# Finds a Mailpit message by exact subject, printing its ID (empty if not
# found yet). Polled in a retry loop by the phases below rather than
# asserting on the first check — SMTP delivery to Mailpit and opQueue
# replay are both asynchronous from this script's perspective.
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

mailpit_headers() {
  local message_id="$1"
  curl -s "$MAILPIT_API/message/$message_id/headers"
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
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Clearing Mailpit's message store and Dovecot's Sent mailbox (clean slate for this run)"
curl -s -X DELETE "$MAILPIT_API/messages" -H "Content-Type: application/json" -d '{"IDs":[]}' >/dev/null
doveadm expunge -u "$MAILSTACK_USER" mailbox Sent all || true

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
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl erase "$UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true  # アバター強化バッチ: Contacts の OS 権限ダイアログが自動検証中に出るのを防ぐ (docs/verify.mdの同種の対策と同じ理由)

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/10: add test1 account with SMTP (Mailpit), confirm baseline"
run_test "OtegamiM5SetupUITests"

echo "==> Phase 2/10: compose and send a brand-new message"
run_test "OtegamiM5ComposeSendUITests"

echo "==> Phase 3/10: confirm the new message arrived at Mailpit"
new_message_id=""
for _ in $(seq 1 15); do
  new_message_id="$(mailpit_find_id "otegami M5 新規送信テスト")"
  [[ -n "$new_message_id" ]] && break
  sleep 1
done
if [[ -z "$new_message_id" ]]; then
  echo "error: composed message never reached Mailpit" >&2
  exit 1
fi
echo "    OK: found in Mailpit (id=$new_message_id)"

echo "==> Confirming a Sent-mailbox copy landed via the best-effort IMAP APPEND"
sent_ok=0
for _ in $(seq 1 15); do
  if doveadm fetch -u "$MAILSTACK_USER" flags mailbox Sent HEADER Subject "otegami M5 新規送信テスト" 2>/dev/null | grep -q 'flags'; then
    sent_ok=1
    break
  fi
  sleep 1
done
if [[ "$sent_ok" != "1" ]]; then
  echo "error: no Sent-mailbox copy found via doveadm (best-effort APPEND didn't land)" >&2
  exit 1
fi
echo "    OK: Sent-mailbox copy confirmed via doveadm"

echo "==> Capturing screenshot: after compose+send"
screenshot "m5-01-compose-sent.png"

echo "==> Phase 4/10: open the seeded baseline message, reply, send"
run_test "OtegamiM5ReplyUITests"

echo "==> Phase 5/10: confirm the reply's In-Reply-To/References headers via Mailpit"
reply_message_id=""
for _ in $(seq 1 15); do
  reply_message_id="$(mailpit_find_id "Re: ようこそ otegami へ")"
  [[ -n "$reply_message_id" ]] && break
  sleep 1
done
if [[ -z "$reply_message_id" ]]; then
  echo "error: reply message never reached Mailpit" >&2
  exit 1
fi
headers_json="$(mailpit_headers "$reply_message_id")"
if ! echo "$headers_json" | python3 -c "
import json, sys
headers = json.load(sys.stdin)
in_reply_to = ' '.join(headers.get('In-Reply-To', []))
references = ' '.join(headers.get('References', []))
assert 'seed-0001' in in_reply_to, f'In-Reply-To missing seed-0001@otegami.test: {in_reply_to!r}'
assert 'seed-0001' in references, f'References missing seed-0001@otegami.test: {references!r}'
"; then
  echo "error: reply's In-Reply-To/References headers didn't reference the original message" >&2
  echo "$headers_json" >&2
  exit 1
fi
echo "    OK: In-Reply-To/References confirmed via Mailpit headers"

echo "==> Capturing screenshot: after reply sent"
screenshot "m5-02-reply-sent.png"

echo "==> Phase 6/10: stopping mailstack (simulate offline)"
make mailstack-down

echo "==> Phase 7/10: compose+send while offline; confirm 送信待ち indicator"
run_test "OtegamiM5OfflineComposeUITests"

echo "==> Capturing screenshot: offline, message queued (送信待ち visible)"
screenshot "m5-03-offline-queued.png"

echo "==> Phase 8/10: restoring mailstack"
make mailstack-up
sleep 3

echo "==> Phase 9/10: relaunch; confirm scenePhase-.active opQueue replay clears the indicator"
run_test "OtegamiM5OfflineReplayUITests"

echo "==> Phase 10/10: confirm the offline-composed message eventually reached Mailpit"
offline_message_id=""
for _ in $(seq 1 15); do
  offline_message_id="$(mailpit_find_id "otegami M5 オフライン送信テスト")"
  [[ -n "$offline_message_id" ]] && break
  sleep 1
done
if [[ -z "$offline_message_id" ]]; then
  echo "error: offline-composed message never reached Mailpit after reconnect" >&2
  exit 1
fi
echo "    OK: offline-composed message found in Mailpit after replay (id=$offline_message_id)"

echo "==> Capturing final screenshot: after replay, 送信待ち cleared"
screenshot "m5-04-offline-replayed.png"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m5-01-compose-sent.png      (new-message compose + send, sheet dismissed)
  $SCREENSHOT_DIR/m5-02-reply-sent.png        (reply sent, thread view)
  $SCREENSHOT_DIR/m5-03-offline-queued.png    (offline: 送信待ち indicator visible)
  $SCREENSHOT_DIR/m5-04-offline-replayed.png  (after reconnect: 送信待ち cleared, message delivered)
EOF
