#!/usr/bin/env bash
# M8 (attachment send/receive + QuickLook + cid inline images) automated
# verification.
#
#   1. OtegamiM8SetupUITests               add the test1 Dovecot account
#                                           (with SMTP fields too — phase 4
#                                           below sends), confirm all three
#                                           new M8 seed fixtures
#                                           (14/15/16-*.eml) appear.
#   2. OtegamiM8AttachmentUITests          open the PNG-attachment seed
#                                           message, tap its attachment row
#                                           (not yet downloaded — exercises
#                                           spinner→fetch→QuickLook),
#                                           confirm a preview screen opens.
#                                           Screenshot mid-test.
#   3. OtegamiM8CIDImageUITests            open the cid-inline-image seed
#                                           message, confirm the body text
#                                           renders and the external-image
#                                           banner does *not* appear
#                                           (independent of the cid path).
#                                           Screenshot mid-test.
#   4. OtegamiM8ComposeAttachmentUITests   compose a new message with the
#                                           OTEGAMI_UITEST_ATTACH_FIXTURE
#                                           internal hook standing in for
#                                           the system file picker (out of
#                                           XCUITest's reach — see
#                                           ComposerView.attachUITestFixture
#                                           IfRequested's doc comment),
#                                           send it.
#   5. (host) Mailpit REST API             confirm the sent message's
#                                           attachment (filename) shows up
#                                           in Mailpit's message metadata.
#
# Usage: scripts/verify-ios-m8.sh
# Env:
#   IOS_SIMULATOR         Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR        Where to write PNGs (default: /tmp/otegami-verify)
#   BUNDLE_ID             App bundle id (default: com.m-tkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.m-tkg.otegami}"
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

# Repeatedly overwrites the same output file across a window wide enough to
# almost certainly land inside the target test method's `Thread.sleep`
# hold — see docs/verify.md's M6/M7 sections for why a single fixed-delay
# screenshot is too timing-sensitive in this environment.
screenshot_mid_test() {
  local test_id="$1"
  local out_name="$2"
  (
    sleep 4
    for _ in $(seq 1 10); do
      xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$out_name" >/dev/null 2>&1 || true
      sleep 1
    done
  ) &
  local screenshot_pid=$!
  run_test "$test_id"
  wait "$screenshot_pid" 2>/dev/null || true
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

echo "==> Clearing Mailpit's message store (clean slate for the compose phase)"
curl -s -X DELETE "$MAILPIT_API/messages" -H "Content-Type: application/json" -d '{"IDs":[]}' >/dev/null

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

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  build-for-testing

echo "==> Phase 1/5: add test1 account (+SMTP), confirm M8 seed fixtures appear"
run_test "OtegamiM8SetupUITests"

echo "==> Phase 2/5: open PNG attachment, tap → fetch → QuickLook preview"
screenshot_mid_test "OtegamiM8AttachmentUITests/testTappingAttachmentRowOpensQuickLookPreview" "m8-01-attachment-quicklook.png"

echo "==> Phase 3/5: open cid-inline-image message, confirm rendering + no external-image banner"
screenshot_mid_test "OtegamiM8CIDImageUITests/testCIDInlineImageMessageRendersWithoutExternalImageBanner" "m8-02-cid-inline-image.png"

echo "==> Phase 4/5: compose with the internal attach-fixture hook, send"
run_test "OtegamiM8ComposeAttachmentUITests"

echo "==> Capturing screenshot: after compose+send with attachment"
screenshot "m8-03-compose-attachment-sent.png"

echo "==> Phase 5/5: confirm the sent attachment's filename via Mailpit's REST API"
message_id=""
for _ in $(seq 1 15); do
  message_id="$(mailpit_find_id "otegami M8 添付送信テスト")"
  [[ -n "$message_id" ]] && break
  sleep 1
done
if [[ -z "$message_id" ]]; then
  echo "error: composed message with attachment never reached Mailpit" >&2
  exit 1
fi
echo "    OK: found in Mailpit (id=$message_id)"

message_json="$(curl -s "$MAILPIT_API/message/$message_id")"
if ! echo "$message_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
attachments = data.get('Attachments', [])
names = [a.get('FileName') for a in attachments]
assert 'm8-uitest-attachment.txt' in names, f'Expected m8-uitest-attachment.txt among attachments, got: {names!r}'
"; then
  echo "error: sent message's attachment metadata didn't include m8-uitest-attachment.txt" >&2
  echo "$message_json" >&2
  exit 1
fi
echo "    OK: attachment filename confirmed via Mailpit message metadata"

cat <<EOF

==> Done.
Screenshots:
  $SCREENSHOT_DIR/m8-01-attachment-quicklook.png     (attachment row tapped, QuickLook preview open)
  $SCREENSHOT_DIR/m8-02-cid-inline-image.png         (cid inline image message, no external-image banner)
  $SCREENSHOT_DIR/m8-03-compose-attachment-sent.png  (composer dismissed after sending with an attachment)
EOF
