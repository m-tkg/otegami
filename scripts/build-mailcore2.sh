#!/usr/bin/env bash
#
# Builds MailCore2 as an XCFramework for use by
# packages/OtegamiKit/Sources/MailTransportMailCore.
#
# STATUS (M0): scaffold only. Not run yet — MailCore2 is not wired into
# MailTransportMailCore until M1. Revisit every TODO below before relying on
# this script's output.
#
# Expected usage (M1+):
#   scripts/build-mailcore2.sh
#   -> produces packages/OtegamiKit/Vendor/MailCore2.xcframework
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/packages/OtegamiKit/Vendor"
BUILD_DIR="$ROOT_DIR/.build/mailcore2"
REPO_URL="https://github.com/MailCore/mailcore2.git"

# TODO(M1): pin to a specific commit/tag once we've verified it builds
# cleanly against current Xcode; MailCore2 upstream is largely unmaintained.
REPO_REF="master"

echo "==> This script is a placeholder and has not been executed end-to-end yet (M0)."
echo "==> Building MailCore2.xcframework is deferred to M1."
echo
echo "Planned steps:"
echo "  1. Clone $REPO_URL (ref: $REPO_REF) into $BUILD_DIR"
echo "  2. Apply any patches needed for current Xcode/SDKs (TODO: identify these)"
echo "  3. Build static libs for iOS device, iOS Simulator, and macOS"
echo "     (TODO: confirm build system — CMake vs Xcode project — and flags)"
echo "  4. Package the per-platform builds into $VENDOR_DIR/MailCore2.xcframework"
echo "     via 'xcodebuild -create-xcframework'"
echo "  5. Wire the resulting xcframework into"
echo "     packages/OtegamiKit/Package.swift as a binaryTarget consumed by"
echo "     the MailTransportMailCore target"
echo
echo "Exiting without doing anything (TODO: implement, M1)."
exit 0
