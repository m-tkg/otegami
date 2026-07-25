#!/usr/bin/env bash
# M9 follow-up (PENDING.md: "xcrun simctl push によるシミュレータへのペイロード
# 注入テスト...は本セッションでは未実施") — verifies NotificationService against
# a *simulated* push, injected locally with `xcrun simctl push`, without any
# `.p8` APNs key and without a real device. This exercises the real
# extension process (`apps/Otegami/NotificationService/NotificationService
# .swift`) end to end: OS delivery -> extension launch -> App Group GRDB
# read -> Keychain read -> a real IMAP round trip against the dev
# mailstack -> notification content rewrite. What it can't exercise is
# anything upstream of `simctl push` itself (real APNs, a real device
# token) — that remains the "実機での最終確認" PENDING.md item.
#
# Phases:
#   1. OtegamiPushSimulatedSetupUITests   add the test1 Dovecot account,
#                                          confirm the seeded baseline.
#   2. (host) resolve accountId/uidnext   read AccountRecord.id straight out
#                                          of the App Group's otegami.sqlite
#                                          (sqlite3, host-side — the exact
#                                          same "XCUITest can't shell out,
#                                          the wrapping script does instead"
#                                          split documented for doveadm in
#                                          docs/verify.md's M3 section, just
#                                          reading GRDB instead of driving
#                                          doveadm this time), and the
#                                          mailbox's current IMAP UIDNEXT via
#                                          `doveadm mailbox status` — mirrors
#                                          exactly what `WatcherPool.swift`
#                                          sends as `PushNotificationPayload
#                                          .uidNext` for a real relay push.
#   3. (host) doveadm save + simctl push  inject a known fixture, then push
#                                          a payload naming its accountId/
#                                          post-arrival uidNext — scenario 1,
#                                          "happy path" enrichment.
#   4. (host) mailstack-down + push       scenario 2: IMAP unreachable ->
#                                          NotificationService's generic
#                                          fallback within its ~30s budget.
#   5. (host) push an unknown accountId   scenario 3: account not found in
#                                          the local database -> the same
#                                          generic fallback, immediately.
#   Each scenario: screenshot the notification banner, then (best-effort)
#   OtegamiPushSimulatedNotificationReadUITests reads its rendered text
#   straight out of Notification Center's accessibility tree.
#
# ============================================================================
# KNOWN BLOCKER on this dev machine/toolchain (confirmed empirically while
# building this script — not a NotificationService bug):
#
#   `xcrun simctl push` fails outright, for *every* payload carrying an
#   `aps.alert` (required for `mutable-content` — a payload with only
#   `content-available` is rejected too, with `UNErrorDomain code=1401
#   "Notification has no user visible content"`):
#
#     UNErrorDomain code=2003: "Repository could not save notification.
#     Source is not authorized."
#
#   Root cause: the app has never called `UNUserNotificationCenter.current()
#   .requestAuthorization(options:)` anywhere in its production code.
#   `Support/PushTokenCenter.swift`'s `requestToken()` only calls
#   `UIApplication.shared.registerForRemoteNotifications()` (APNs device-
#   token registration) — on this iOS 26/27 toolchain that does *not*
#   implicitly request alert/banner authorization the way it did pre-iOS 10;
#   the two have been separate APIs for a decade. Confirmed two ways:
#     - `xcrun simctl push` itself rejects with the error above even *after*
#       driving `OtegamiM9PushSettingsUITests`' full enable flow (which does
#       call `registerForRemoteNotifications()`) on this same install.
#     - Settings -> Apps -> Otegami shows no "Notifications" row at all
#       (only Siri/Search/Cellular Data) — this OS's Settings only lists a
#       per-app Notifications toggle once *something* has registered the
#       app with `usernoted`, which a bare `registerForRemoteNotifications()`
#       apparently doesn't do here. There is no `xcrun simctl privacy ...
#       notifications` grant (unlike camera/contacts/location — `xcrun simctl
#       privacy --help` doesn't list a notifications service at all), and no
#       working Settings deep-link on this OS (`App-prefs:` URLs no-op).
#
#   The fix is a one-line addition — `UNUserNotificationCenter.current()
#   .requestAuthorization(options: [.alert, .sound, .badge])` alongside the
#   existing `registerForRemoteNotifications()` call in `PushTokenCenter
#   .requestToken()` — plus a UITest step that accepts the resulting system
#   permission prompt (`addUIInterruptionMonitor`/springboard "Allow" tap,
#   the same class of system-alert handling `dismissSavePasswordPromptIfNeeded`
#   already does for the Keychain AutoFill prompt). **Deliberately not made
#   here**: `Support/PushTokenCenter.swift` is outside this task's permitted
#   file scope (`apps/Otegami/NotificationService/`, `packages/OtegamiKit
#   /Sources/{PushRelayClient,AccountCloudSync}/`, and *new* files under
#   `apps/Otegami/UITests/`/`scripts/verify-*` only) — see this script's
#   companion investigation in `docs/verify.md` for the full writeup and
#   next steps.
#
#   Until that line lands, this script runs phases 1-2 (account setup,
#   accountId/uidnext discovery, payload construction) successfully, then
#   fails loudly and specifically at the first `simctl push` with a message
#   pointing back at this comment block, rather than a bare, confusing
#   `UNErrorDomain` dump. `NotificationEnrichment` (the title/body rewrite
#   policy itself) is unit-tested independently of this whole pipeline —
#   see `packages/OtegamiKit/Tests/PushRelayClientTests
#   /NotificationEnrichmentTests.swift` — so that part of NotificationService
#   *is* covered today regardless of this blocker.
# ============================================================================
#
# Usage: scripts/verify-ios-push-simulated.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR  Where to write PNGs/payload JSON (default: /tmp/otegami-verify)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
MAILSTACK_USER="test1@otegami.test"
FIXTURE="dev/mailstack/seed/fixtures/08-m3-new-mail.eml" # From: Aiko <aiko@otegami.test>, Subject: M3差分同期テスト

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

doveadm() {
  docker compose -f "$ROOT_DIR/dev/mailstack/compose.yml" exec -T dovecot doveadm "$@"
}

# Reads a `CFBundleIdentifier => GroupContainers` pair for the installed
# Otegami app out of `xcrun simctl listapps`. Deliberately *discovered*
# rather than a hardcoded `com.m-tkg.otegami` default (unlike
# `scripts/verify-ios-m9.sh`'s `BUNDLE_ID` env var default): this dev
# machine's `apps/Otegami/Config/Local.xcconfig` overrides `OTEGAMI_BUNDLE_ID`
# to `com.mtkg.otegami` (no hyphen) for its own signing setup, per that
# file's own doc comment on why `Local.xcconfig` exists — a hardcoded
# default would silently look up the wrong bundle id on this machine (and
# the App Group container path below depends on getting it right, unlike
# the other verify-ios-m*.sh scripts, which never need to read inside the
# container).
resolve_installed_app() {
  xcrun simctl listapps "$UDID" > "$SCREENSHOT_DIR/.listapps.plist"
  plutil -convert json -o "$SCREENSHOT_DIR/.listapps.json" "$SCREENSHOT_DIR/.listapps.plist"
  # Filters on the app's *display name* ("Otegami" — stable regardless of
  # which bundle id `Config/Local.xcconfig` happens to be set to on this
  # machine), not just "has a GroupContainers entry" — several stock system
  # apps (Reminders, Notes, ...) also use app groups for their widgets, so
  # that alone isn't a unique enough signal (confirmed: an earlier version
  # of this filter matched `com.apple.reminders` before this fix).
  BUNDLE_ID="$(python3 -c "
import json
with open('$SCREENSHOT_DIR/.listapps.json') as f:
    apps = json.load(f)
for bundle_id, info in apps.items():
    if bundle_id.endswith('.uitests') or bundle_id.endswith('.xctrunner'):
        continue
    if info.get('CFBundleDisplayName') == 'Otegami' and info.get('GroupContainers'):
        print(bundle_id)
        break
")"
  if [[ -z "$BUNDLE_ID" ]]; then
    echo "error: could not find an installed app with a GroupContainers entry (looked for the main Otegami app, not *.uitests/*.xctrunner)" >&2
    exit 1
  fi
  GROUP_CONTAINER="$(python3 -c "
import json
with open('$SCREENSHOT_DIR/.listapps.json') as f:
    apps = json.load(f)
containers = apps['$BUNDLE_ID'].get('GroupContainers', {})
path = next(iter(containers.values()))
print(path.replace('file://', '').rstrip('/'))
")"
  DB_PATH="$GROUP_CONTAINER/otegami/otegami.sqlite"
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

echo "==> Starting dev mailstack and seeding fixtures (idempotent reseed)"
make mailstack-up
sleep 3
make mailstack-seed

echo "==> Erasing simulator content (clean local DB, Keychain, and iCloud KVS — see docs/verify.md's M11 section)"
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

echo "==> Phase 1: add test1 account"
run_test "OtegamiPushSimulatedSetupUITests"

echo "==> Resolving installed bundle id + App Group container"
resolve_installed_app
echo "    BUNDLE_ID: $BUNDLE_ID"
echo "    DB_PATH:   $DB_PATH"
if [[ ! -f "$DB_PATH" ]]; then
  echo "error: expected GRDB database not found at $DB_PATH" >&2
  exit 1
fi

ACCOUNT_ID="$(sqlite3 "$DB_PATH" "SELECT id FROM account WHERE email = '$MAILSTACK_USER' LIMIT 1;")"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "error: $MAILSTACK_USER account not found in $DB_PATH" >&2
  exit 1
fi
echo "    ACCOUNT_ID: $ACCOUNT_ID"

make_payload() {
  # $1=output path, $2=accountId, $3=uidNext — mirrors
  # server/otegami-relay/Sources/OtegamiRelay/Push/APNsSender.swift's
  # `APNsBody` shape exactly (mutable-content + loc-key NEW_MAIL, accountId/
  # uidNext outside `aps`, nothing else — the plan's "本文/件名を含めない"
  # privacy design).
  cat > "$1" << EOF
{
  "Simulator Target Bundle": "$BUNDLE_ID",
  "aps": {
    "alert": { "loc-key": "NEW_MAIL" },
    "mutable-content": 1
  },
  "accountId": "$2",
  "uidNext": $3
}
EOF
}

push_and_capture() {
  # $1=payload path, $2=screenshot filename, $3=label for log output
  echo "==> Pushing (simctl): $3"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  local push_started push_output push_status
  push_started="$(date +%s)"
  if ! push_output="$(xcrun simctl push "$UDID" "$BUNDLE_ID" "$1" 2>&1)"; then
    push_status=$?
    echo "$push_output" >&2
    if [[ "$push_output" == *"Source is not authorized"* ]]; then
      cat >&2 << 'EOF'

error: simctl push rejected — the app has never been granted notification
authorization on this simulator install. This is a known, documented
blocker (see this script's header comment block above) requiring a
one-line UNUserNotificationCenter.requestAuthorization(...) addition to
apps/Otegami/Sources/Support/PushTokenCenter.swift, which is outside this
task's permitted file scope. Everything up to this point (account setup,
accountId/uidnext discovery, payload construction) succeeded — only the
actual push delivery is blocked.
EOF
    fi
    exit "$push_status"
  fi
  local elapsed=$(( $(date +%s) - push_started ))
  echo "    push accepted (${elapsed}s to submit)"

  sleep 3
  xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/$2"
  echo "    screenshot: $SCREENSHOT_DIR/$2"

  echo "==> Reading Notification Center (best-effort)"
  run_test "OtegamiPushSimulatedNotificationReadUITests" || true
  local total_elapsed=$(( $(date +%s) - push_started ))
  echo "    total wall-clock from push submission to notification-read: ${total_elapsed}s"
}

echo "==> Phase 2: inject a known fixture, resolve post-arrival uidnext"
doveadm save -u "$MAILSTACK_USER" -m INBOX < "$FIXTURE"
UID_NEXT="$(doveadm mailbox status -u "$MAILSTACK_USER" uidnext INBOX | sed -n 's/.*uidnext=\([0-9]*\).*/\1/p')"
if [[ -z "$UID_NEXT" ]]; then
  echo "error: could not read INBOX uidnext via doveadm" >&2
  exit 1
fi
echo "    INBOX uidnext after injection: $UID_NEXT"

make_payload "$SCREENSHOT_DIR/push-01-enriched.json" "$ACCOUNT_ID" "$UID_NEXT"
push_and_capture "$SCREENSHOT_DIR/push-01-enriched.json" "push-01-enriched-banner.png" \
  "scenario 1/3: known account + real new mail (expect sender 'Aiko' / subject 'M3差分同期テスト')"

echo "==> Phase 3: stopping mailstack (IMAP unreachable) — expect graceful generic-text fallback"
make mailstack-down
make_payload "$SCREENSHOT_DIR/push-02-imap-unreachable.json" "$ACCOUNT_ID" "$((UID_NEXT + 1))"
push_and_capture "$SCREENSHOT_DIR/push-02-imap-unreachable.json" "push-02-imap-unreachable-banner.png" \
  "scenario 2/3: IMAP unreachable (expect generic fallback text, well within NotificationService's ~30s budget)"
make mailstack-up

echo "==> Phase 4: unknown accountId — expect immediate generic-text fallback"
make_payload "$SCREENSHOT_DIR/push-03-unknown-account.json" "00000000-0000-0000-0000-000000000000" "1"
push_and_capture "$SCREENSHOT_DIR/push-03-unknown-account.json" "push-03-unknown-account-banner.png" \
  "scenario 3/3: accountId not found locally (expect generic fallback text, fast — no IMAP attempt at all)"

cat <<EOF

==> Done.
Payloads:
  $SCREENSHOT_DIR/push-01-enriched.json
  $SCREENSHOT_DIR/push-02-imap-unreachable.json
  $SCREENSHOT_DIR/push-03-unknown-account.json
Screenshots:
  $SCREENSHOT_DIR/push-01-enriched-banner.png          (expect sender/subject rewritten from "Aiko"/"M3差分同期テスト")
  $SCREENSHOT_DIR/push-02-imap-unreachable-banner.png  (expect generic "新着メールがあります")
  $SCREENSHOT_DIR/push-03-unknown-account-banner.png   (expect generic "新着メールがあります")
Notification Center text (best-effort, see xcodebuild output above for
"PUSH-VERIFY-NOTIFICATION-LABEL: ..." lines per scenario).
EOF
