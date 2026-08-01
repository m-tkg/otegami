#!/usr/bin/env bash
# Shared iOS Simulator helpers for scripts/verify-ios-*.sh and friends.
#
# Source this (after `set -euo pipefail` and setting $IOS_SIMULATOR /
# $BUNDLE_ID) rather than copy-pasting the blocks below — every call site
# this replaced was diffed byte-for-byte against its former inline copy
# before being extracted (Phase 5 scripts/Makefile hygiene). Each function
# reads/writes the caller's plain (non-local) $UDID variable, since callers
# run in the same shell (sourced, not a subshell) and rely on $UDID
# surviving into whatever they do next.
#
# Not every call site uses every function here — some scripts skip the
# erase (e.g. verify-ios-mailto.sh reinstalls fresh instead), and a couple
# have boot/erase sequences that don't match this file's helpers exactly
# (e.g. verify-qa-sweep-offline.sh's unsuppressed `simctl boot`) and were
# deliberately left inline rather than forced into these functions.

# Resolves $IOS_SIMULATOR to a UDID, exiting 1 if no available (non-
# "unavailable") simulator matches. Sets the caller's $UDID.
resolve_simulator_udid() {
  echo "==> Resolving simulator UDID for '$IOS_SIMULATOR'"
  UDID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$IOS_SIMULATOR" '
  $0 ~ name && $0 !~ /unavailable/ { print $2; exit }
')"
  if [[ -z "$UDID" ]]; then
    echo "error: no available simulator matching '$IOS_SIMULATOR'" >&2
    exit 1
  fi
  echo "    UDID: $UDID"
}

# Shuts down (if running) and erases all content/settings on $UDID — this
# clears the local DB, Keychain, and iCloud KVS alike. A plain `simctl
# uninstall` only clears the app's own container, which isn't enough once
# AccountCloudSyncEngine reconciles from iCloud KVS at every launch (see
# docs/icloud-sync.md's verify note for the failure this avoids).
erase_simulator() {
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID"
}

# Boots $UDID (idempotent — booting an already-booted device errors, which
# this swallows) and blocks until it's ready for use.
boot_simulator() {
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b
}

# Grants the Contacts privacy permission to $BUNDLE_ID on $UDID so the OS
# permission dialog doesn't block an automated verification run (see
# docs/verify.md's simulator known-flakiness notes).
grant_contacts_privacy() {
  xcrun simctl privacy "$UDID" grant contacts "$BUNDLE_ID" 2>/dev/null || true
}
