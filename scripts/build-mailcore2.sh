#!/usr/bin/env bash
#
# "Provisions" MailCore2 for packages/OtegamiKit/Sources/MailTransportMailCore.
#
# STATUS (M1): MailCore2 is wired in as a source-built Swift Package
# Manager dependency (see packages/OtegamiKit/Package.swift ->
# https://github.com/readdle/mailcore2, branch feature/spm-support, pinned
# to an exact revision) rather than as a self-built XCFramework. There is
# therefore no XCFramework for this script to produce or for
# MailTransportMailCore to link as a binaryTarget — see
# docs/build-mailcore2.md for the full rationale (an XCFramework build was
# attempted first; it's abandoned in favor of this approach, not skipped).
#
# What this script actually does:
#   1. Explain the above, so `scripts/build-mailcore2.sh` remains a useful
#      single entry point even though "build" is no longer quite the right
#      verb for it.
#   2. Work around a download hang seen in some sandboxed/proxied network
#      setups: `swift build`'s own binary-artifact downloader can hang
#      indefinitely fetching swift-unicode's ICU xcframework (a transitive
#      dependency of mailcore2) even when the same URL downloads instantly
#      via `curl`. If that happens, pre-seed SwiftPM's shared artifact
#      cache from a `curl` download instead, which `swift build` then finds
#      and reuses without touching the network itself.
#   3. Resolve and build OtegamiKit's MailTransportMailCore target, so
#      running this script is a genuine end-to-end verification that the
#      MailCore2 dependency is usable, matching what a fresh checkout would
#      need to do before `make test`/`make mac`/`make ios` will succeed.
#
# Usage: scripts/build-mailcore2.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DIR="$ROOT_DIR/packages/OtegamiKit"

# The swift-unicode binary artifact mailcore2 pulls in transitively (for
# ICU-based charset detection). Pinned by packages/OtegamiKit/Package.swift
# -> mailcore2 -> readdle/swift-unicode 68.2.0; update this alongside that
# pin if it ever changes (mismatched checksum just fails the cache-seed
# attempt below harmlessly, and `swift build` falls back to its own
# download).
ICU_ARTIFACT_URL="https://github.com/readdle/icu4darwin/releases/download/68.2/icu68-2-darwin-no-strip-xcframework-dynamic.zip"
ICU_ARTIFACT_CHECKSUM="4e47b9ca38fd3d17d0bd4e6af2b5e906677a0abd94173b8208f0b64f07d21021"

sanitize_url_for_cache_key() {
  # SwiftPM's shared artifact cache keys entries by the download URL with
  # every non-alphanumeric character replaced by `_` (observed empirically
  # against ~/Library/Caches/org.swift.swiftpm/artifacts; not documented
  # SwiftPM behavior, so this is best-effort and safe to fail).
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9]/_/g'
}

seed_swiftpm_artifact_cache() {
  local cache_root="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
  local cache_key
  cache_key="$(sanitize_url_for_cache_key "$ICU_ARTIFACT_URL")"
  local cache_path="$cache_root/$cache_key"

  if [ -f "$cache_path" ]; then
    return 0
  fi

  echo "==> Pre-fetching swift-unicode's ICU xcframework via curl (works around a"
  echo "    known SwiftPM binary-artifact download hang in some sandboxed networks)"
  mkdir -p "$cache_root"
  local tmp_path
  tmp_path="$(mktemp "$cache_root/.download-XXXXXX")"
  if ! curl -fL --max-time 120 -o "$tmp_path" "$ICU_ARTIFACT_URL"; then
    echo "==> curl pre-fetch failed; leaving it to 'swift build' to download normally."
    rm -f "$tmp_path"
    return 0
  fi

  local actual_checksum
  actual_checksum="$(shasum -a 256 "$tmp_path" | awk '{print $1}')"
  if [ "$actual_checksum" != "$ICU_ARTIFACT_CHECKSUM" ]; then
    echo "==> WARNING: downloaded artifact checksum does not match the pin in"
    echo "    swift-unicode's Package.swift ($ICU_ARTIFACT_CHECKSUM). Not seeding the"
    echo "    cache with it; leaving it to 'swift build' to download normally."
    rm -f "$tmp_path"
    return 0
  fi

  chmod 600 "$tmp_path"
  mv "$tmp_path" "$cache_path"
  echo "==> Seeded SwiftPM artifact cache at $cache_path"
}

echo "==> MailCore2 is a source-built SPM dependency (see docs/build-mailcore2.md)."
echo "==> Resolving and building packages/OtegamiKit's MailTransportMailCore target..."
echo

seed_swiftpm_artifact_cache

cd "$KIT_DIR"
swift package resolve
swift build --target MailTransportMailCore

echo
echo "==> MailTransportMailCore built successfully against MailCore2."
echo "==> Nothing to place in Vendor/ — there is no XCFramework in this setup."
