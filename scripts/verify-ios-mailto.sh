#!/usr/bin/env bash
# Task #48 (デフォルトメールアプリ対応) — verifies that a `mailto:` URL
# opened from *outside* the app (`xcrun simctl openurl`, standing in for a
# real "tap a mailto: link in another app") reaches `OtegamiApp
# .handleOpenURL(_:)` and prefills the Composer, through the real OS URL
# routing — not just `MailtoURLParser`'s own unit tests
# (packages/OtegamiKit/Tests/OtegamiCoreTests/MailtoURLParserTests.swift),
# which never touch `.onOpenURL`/`CFBundleURLTypes` at all.
#
# IMPORTANT, found by actually running this (not assumed going in): a build
# with `OTEGAMI_MAIL_CLIENT_ENTITLEMENT` left at its default `NO` cannot be
# reached by `mailto:` at all, even via `simctl openurl` for this app's own
# testing purposes — `mailto` (like `tel`/`sms`) is a *reserved* scheme, and
# `lsd` (LaunchServices daemon) refuses to register *any* third-party
# handler for it without the `com.apple.developer.mail-client` entitlement,
# regardless of `CFBundleURLTypes`. Confirmed via
# `log show --predicate 'eventMessage CONTAINS "mailto"'`:
# `lsd: ERROR: There is no registered handler for URL scheme mailto`,
# surfaced to `simctl openurl` as `LSApplicationWorkspaceErrorDomain error
# 115`. So this script *requires* a build with the entitlement flag on —
# Simulator doesn't enforce provisioning, so this works with Apple's
# approval and a Local.xcconfig flip regardless (see
# docs/default-mail-app.md's "動作確認" section for the full writeup).
#
# No dev mailstack/account setup needed — unlike almost every other
# verify-ios-*.sh script, prefilling the Composer's To/Cc/Bcc/subject/body
# doesn't depend on any account existing (the "差出人" picker is simply
# empty, which doesn't block this feature's own verification).
#
# Phases:
#   1. (host) simctl launch + openurl   launch the app, then open a
#                                        `mailto:` URL naming two `to`
#                                        addresses (one in the path, one via
#                                        `?to=`, RFC 6068 §2's equivalence
#                                        example) + cc/bcc/subject/body.
#                                        This queues Springboard's "Open in
#                                        “Otegami”?" consent alert (the same
#                                        alert a real mailto: tap from
#                                        another app would show for a
#                                        non-http(s) custom scheme) — the
#                                        URL isn't actually delivered to the
#                                        app until that's dismissed.
#   2. OtegamiMailtoUITests             dismisses the Springboard alert
#                                        (`app.activate()`, not
#                                        `app.launch()` — see that file's
#                                        own doc comment) and asserts the
#                                        Composer's field values via
#                                        accessibility identifiers.
#   3. (host) screenshot                visual confirmation, taken *after*
#                                        the UITest so it captures the
#                                        actual prefilled Composer (not the
#                                        consent alert) — this script's
#                                        caller should look at the PNG, per
#                                        this repo's "見ずに完了と報告しない"
#                                        rule.
#
# Usage:
#   1. Add `OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES` to
#      apps/Otegami/Config/Local.xcconfig (see Local.xcconfig.sample) —
#      required, see above. Remove it again afterward if you don't want a
#      long-lived local override.
#   2. scripts/verify-ios-mailto.sh
# Env:
#   IOS_SIMULATOR   Simulator name (default: iPhone 17 Pro Max)
#   SCREENSHOT_DIR  Where to write the PNG (default: /tmp/otegami-verify)
#   BUNDLE_ID       App bundle id (default: com.mtkg.otegami)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$(dirname "${BASH_SOURCE[0]}")/lib/simulator.sh"

IOS_SIMULATOR="${IOS_SIMULATOR:-iPhone 17 Pro Max}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-/tmp/otegami-verify}"
BUNDLE_ID="${BUNDLE_ID:-com.mtkg.otegami}"
MAILTO_URL='mailto:a@otegami.test?to=b@otegami.test&cc=c@otegami.test&bcc=d@otegami.test&subject=mailto%E3%83%86%E3%82%B9%E3%83%88&body=%E6%9C%AC%E6%96%87%E3%81%A7%E3%81%99'

mkdir -p "$SCREENSHOT_DIR"

if ! grep -qE '^\s*OTEGAMI_MAIL_CLIENT_ENTITLEMENT\s*=\s*YES\s*$' apps/Otegami/Config/Local.xcconfig 2>/dev/null; then
  echo "error: apps/Otegami/Config/Local.xcconfig must set OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES for this script" >&2
  echo "       (see docs/default-mail-app.md's \"動作確認\" section for why this is required even on Simulator)" >&2
  exit 1
fi

resolve_simulator_udid

echo "==> Booting simulator (if needed)"
boot_simulator

# A dedicated `-derivedDataPath` (not Xcode's default shared DerivedData/
# dir) so this script always knows exactly where its own build's output
# landed — `find ... DerivedData -name Otegami.app -print -quit` (an
# earlier version of this script) turned out to be non-deterministic
# whenever more than one `Otegami-<hash>` directory exists (e.g. one from a
# previous `make ios` run, one from this script), which silently installed
# a *stale* build missing the entitlement this script requires — the whole
# point of this script — and produced a confusing, seemingly-random
# LSApplicationWorkspaceErrorDomain 115 further down.
DERIVED_DATA_PATH="/tmp/otegami-verify-mailto-derived-data"

echo "==> Regenerating Xcode project and building for testing"
(cd apps/Otegami && xcodegen generate)
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build-for-testing

echo "==> Installing the just-built app"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Otegami.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: could not locate the built Otegami.app at $APP_PATH" >&2
  exit 1
fi
# Reinstalling over a stale install of the *other* (non-entitled) variant
# has been observed to leave `lsd` still refusing to register the mailto
# handler — uninstall first so this is always a genuinely fresh install of
# the entitled build.
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"

echo "==> Launching the app"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 5

echo "==> Opening mailto: URL: $MAILTO_URL"
for attempt in 1 2 3 4 5; do
  if xcrun simctl openurl "$UDID" "$MAILTO_URL"; then
    break
  fi
  if [[ "$attempt" -eq 5 ]]; then
    echo "error: simctl openurl kept failing after 5 attempts (see this script's header comment on error 115)" >&2
    exit 1
  fi
  echo "    retrying ($attempt/5)..."
  sleep 3
done

echo "==> Running OtegamiMailtoUITests (dismisses the Springboard consent alert, then asserts the Composer's prefilled fields)"
xcodebuild \
  -project apps/Otegami/Otegami.xcodeproj \
  -scheme Otegami \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:"OtegamiUITests/OtegamiMailtoUITests/testMailtoOpenPrefillsComposer" \
  test-without-building

echo "==> Screenshot (taken after the UITest so it shows the actual prefilled Composer)"
xcrun simctl io "$UDID" screenshot "$SCREENSHOT_DIR/mailto-01-composer-prefilled.png"
echo "    $SCREENSHOT_DIR/mailto-01-composer-prefilled.png"

echo "==> Done"
