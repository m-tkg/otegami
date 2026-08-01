#!/usr/bin/env bash
# Shared xcodebuild/xcodegen helpers for scripts/verify-ios-*.sh (iOS
# Simulator UI test runs against the dev mailstack).
#
# Source scripts/lib/simulator.sh first (or otherwise set $UDID) before
# calling build_for_testing/run_test — both read the caller's $UDID.
#
# A few call sites intentionally don't use these (e.g.
# verify-ios-mailto.sh's `-derivedDataPath` build, verify-screen.sh's plain
# `build` instead of `build-for-testing`, verify-ios-avatar-phase1.sh's
# combined `build-for-testing test-without-building &`) — those differ from
# the shared pattern in a real flag/argument, not just incidentally, so
# they were left as their own inline xcodebuild calls rather than forced
# through these functions.

# Regenerates apps/Otegami/Otegami.xcodeproj from project.yml.
xcodegen_generate() {
  (cd apps/Otegami && xcodegen generate)
}

# Builds the OtegamiUITests bundle for $UDID without running any tests yet.
build_for_testing() {
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    build-for-testing
}

# Runs a single already-built UI test class (or class/method) against
# $UDID. Usage: run_test "OtegamiM1VerificationUITests/testFoo"
run_test() {
  local test_id="$1"
  xcodebuild \
    -project apps/Otegami/Otegami.xcodeproj \
    -scheme Otegami \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"OtegamiUITests/$test_id" \
    test-without-building
}
