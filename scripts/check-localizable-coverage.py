#!/usr/bin/env python3
"""Localization coverage check for apps/Otegami/Sources (Task #170).

Guards against the recurring "UI 言語混在" bug class: a new SwiftUI view
adds a string literal directly to Text/Button/Label/etc. without ever
touching `apps/Otegami/Resources/Localizable.xcstrings` (or
`scripts/generate-localizable.py`), so the string never gets an `en`
translation and always renders in Japanese regardless of the device's
language setting — or, less often, the reverse (an English literal added
directly, always rendering in English even under a Japanese locale).
Task #158's "アップデートを確認…" macOS menu item and friends fell into the
first case; Task #145 documents several instances of the second.

Three checks, run against every `.swift` file under `apps/Otegami/Sources`
(except `DesignSystem/Catalog`, the `#if DEBUG`-only design token catalog
screen that ships in no build):

1. **Missing catalog entry** (fatal): a string literal passed as the
   user-facing argument of a localizing SwiftUI API (`Text(...)`,
   `Button(...)`, `.navigationTitle(...)`, etc.) that isn't a key in
   `Localizable.xcstrings`. Checked for both Japanese-literal calls (the
   overwhelmingly common case, since the app's source language is `ja` and
   most UI code writes the Japanese string directly) and English-literal
   calls that look like real UI phrases rather than protocol jargon.
2. **Missing translation** (fatal): a catalog key present but without a
   non-empty `en` string. (Every entry has one as of this writing — this
   check is future-proofing against a hand-edit in Xcode's String Catalog
   editor that adds a key without translating it.)
3. **Unused catalog key** (warning only): a catalog key that doesn't occur
   as a substring anywhere in the scanned source. Not fatal — a plain
   substring search has false negatives (e.g. a key only reachable via a
   `switch` built at another layer) — but worth surfacing as a deletion
   candidate.

Whitelisted literal (see WHITELIST_* below) are exempt from check 1 even
without a catalog entry — RFC header names (`Cc`/`Bcc`/...), protocol/
technical acronyms (`IMAP`/`TLS`/...), and provider brand names (`Gmail`/
`iCloud`/...) are meant to stay in English in both locales, matching the
policy `docs/localization.md` (Task #145) already settled on.

Exit status is non-zero iff any fatal issue (1 or 2) is found. Run via
`make check-localization`, wired into `ci-app.yml`.

**Known gap**: any literal containing Swift string interpolation (`\(...)`)
is skipped entirely (`unescape_swift_literal` returns `None`) rather than
resolved, because a literal, unqualified `Text("... \(x)")`/`Button("...
\(x)")` call can't become a fixed catalog key — the interpolated part is
data, not part of the key. `String(localized: "... \(x)")` is a real
exception to this: `String.LocalizationValue`'s interpolation converts each
interpolated value into a `%<format>` placeholder at extraction time (e.g.
an interpolated `Int` becomes `%lld` — see the `"添付ファイル %lld 個"` /
`"スレッド (%lld)"` entries in `generate-localizable.py`), so it *is*
statically resolvable in principle, but this script doesn't attempt that
resolution (it would need the interpolated expression's Swift type, which a
regex-based scanner doesn't have). `ThreadDetailView.navigationTitleText`
(Task #170) was exactly this shape and had to be found by screenshot
review instead — grep for `String(localized:.*\\(` across
`apps/Otegami/Sources` periodically to manually audit this class, since
the automated check can't.

Usage: `python3 scripts/check-localizable-coverage.py`
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "apps/Otegami/Resources/Localizable.xcstrings"
SOURCES_ROOT = REPO_ROOT / "apps/Otegami/Sources"

# #if DEBUG-only design token catalog screen (never ships) — see
# docs/design-system.md and docs/localization.md's "意図的に対象外" list.
EXCLUDED_DIRS = {
    SOURCES_ROOT / "DesignSystem/Catalog",
}

# --- Whitelist: literals allowed to stay English without a catalog entry ---
#
# Kept in sync with docs/localization.md's Task #145 "意図的に変更しなかっ
# たもの" list. Extend this (not the check logic) when a new legitimate
# English-in-both-locales term shows up as a false positive.
WHITELIST_EXACT = {
    # RFC/mail header names, shown verbatim in Composer and the message
    # info sheet in both locales.
    "From", "To", "Cc", "Bcc", "Subject",
    "Message-ID", "In-Reply-To", "References",
    # Protocol / technical jargon.
    "IMAP", "SMTP", "STARTTLS", "TLS", "SSL", "OAuth", "HTML", "URL", "ID",
    "BIMI",
    # Provider / vendor brand names.
    "Gmail", "iCloud", "Yahoo", "Yahoo! JAPAN", "Outlook", "Office365",
    "Exchange", "Microsoft", "Otegami",
    # Short badges (DesignSystem/Components badges — intentionally English
    # abbreviations, not sentences).
    "EN", "EN badge", "HTML badge",
}
# Regex fallback for whitelisted literals that vary in punctuation/casing
# (e.g. trailing "..."/"…", or short acronym-only strings not worth
# enumerating individually).
WHITELIST_PATTERNS = [
    re.compile(r"^[A-Z0-9]{1,6}$"),  # bare acronyms/codes, e.g. "PDF", "M4A"
]

JAPANESE_RE = re.compile(
    r"[぀-ゟ゠-ヿ㐀-鿿＀-￯]"
)
# A literal that "looks like" a real English UI phrase worth localizing —
# multiple words of plain text — as opposed to a single technical token,
# a format string, punctuation-only, or something with a % placeholder.
ENGLISH_PHRASE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 ,.'\-!?…:/()&]*$")

# APIs whose first positional string-literal argument is user-facing text
# that should be catalog-driven. `Text(verbatim:)`/other keyword-labeled
# first arguments are deliberately NOT matched here (the regex requires the
# literal to immediately follow the opening paren) — verbatim calls are the
# documented escape hatch for dynamic data (account names, addresses) and
# are correctly excluded from catalog coverage.
CALL_APIS = [
    "Text", "Button", "Label", "Toggle", "Menu", "CommandMenu", "TextField",
    "SecureField", "ContentUnavailableView", "NavigationLink", "Section",
    "Picker",
]
MODIFIER_APIS = [
    "navigationTitle", "alert", "confirmationDialog", "accessibilityLabel",
    "accessibilityHint", "accessibilityValue", "help",
]

CALL_LITERAL_RE = re.compile(
    r"\b(?:" + "|".join(CALL_APIS) + r")\(\s*\"((?:[^\"\\]|\\.)*)\""
)
MODIFIER_LITERAL_RE = re.compile(
    r"\.(?:" + "|".join(MODIFIER_APIS) + r")\(\s*\"((?:[^\"\\]|\\.)*)\""
)
# `String(localized: "...")` — the explicit-catalog-lookup escape hatch
# docs/localization.md documents for `switch`-built `String` computed
# properties handed to `Text(someVariable)` (which otherwise renders
# verbatim, bypassing the catalog entirely). Just as much a catalog
# dependency as a direct `Text("...")` call.
STRING_LOCALIZED_RE = re.compile(r"String\(localized:\s*\"((?:[^\"\\]|\\.)*)\"")

ESCAPES = {
    "n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0",
}


def unescape_swift_literal(raw: str) -> str | None:
    """Best-effort Swift string literal unescape. Returns None if the
    literal contains string interpolation (`\\(`) — those can't be resolved
    statically to a fixed catalog key, so callers should skip them."""
    if "\\(" in raw:
        return None
    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == "\\" and i + 1 < len(raw):
            nxt = raw[i + 1]
            if nxt == "u" and raw[i + 2 : i + 3] == "{":
                end = raw.index("}", i + 3)
                out.append(chr(int(raw[i + 3 : end], 16)))
                i = end + 1
                continue
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def is_whitelisted(literal: str) -> bool:
    if literal in WHITELIST_EXACT:
        return True
    return any(p.match(literal) for p in WHITELIST_PATTERNS)


def strip_comments(text: str) -> str:
    """Blank out `//` and `/* */` (nested) comments, replacing their
    characters with spaces so byte offsets / line numbers are unchanged.
    String literals (single- and triple-quoted) are passed through untouched
    so a `//` or `/*` inside a string isn't mistaken for a comment starting
    (this codebase's extremely verbose Japanese doc comments regularly
    contain example code with literal quotes, e.g. `Section("見出し")`
    inside a `//` explanation — without this, that literal would be
    misdetected as a real, uncataloged UI string). Doesn't handle Swift's
    `#"raw strings"#` (unused in this codebase as of writing — see the repo
    survey in Task #170)."""
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = end + 3 if end != -1 else n
            i = end
            continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = end if end != -1 else n
            for j in range(i, end):
                out[j] = " "
            i = end
            continue
        if text.startswith("/*", i):
            depth = 1
            j = i + 2
            while j < n and depth > 0:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, j):
                if text[k] != "\n":
                    out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def iter_source_files():
    for path in sorted(SOURCES_ROOT.rglob("*.swift")):
        if any(excluded in path.parents or excluded == path.parent for excluded in EXCLUDED_DIRS):
            continue
        if any(str(path).startswith(str(d)) for d in EXCLUDED_DIRS):
            continue
        yield path


def scan_source_literals():
    """Returns (findings, all_source_text) where findings is a list of
    dicts describing each literal that needs a catalog entry, and
    all_source_text is the concatenation of every scanned file (used for
    the unused-key substring search)."""
    findings = []
    all_text_parts = []
    for path in iter_source_files():
        text = path.read_text(encoding="utf-8")
        all_text_parts.append(text)  # unused-key search still sees comments/docs
        rel = path.relative_to(REPO_ROOT)
        code_text = strip_comments(text)
        for regex in (CALL_LITERAL_RE, MODIFIER_LITERAL_RE, STRING_LOCALIZED_RE):
            for m in regex.finditer(code_text):
                raw = m.group(1)
                literal = unescape_swift_literal(raw)
                if literal is None:
                    continue  # interpolated — can't resolve statically
                if literal == "":
                    continue
                line_no = text.count("\n", 0, m.start()) + 1
                is_japanese = bool(JAPANESE_RE.search(literal))
                is_english_phrase = bool(ENGLISH_PHRASE_RE.match(literal)) and " " in literal
                if not is_japanese and not is_english_phrase:
                    continue  # single technical token / format string / punctuation
                if is_whitelisted(literal):
                    continue
                findings.append({
                    "file": str(rel),
                    "line": line_no,
                    "literal": literal,
                    "kind": "ja" if is_japanese else "en-hardcoded",
                })
    return findings, "\n".join(all_text_parts)


def main() -> int:
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    catalog_keys = catalog["strings"]

    findings, all_source_text = scan_source_literals()

    missing_entries = [f for f in findings if f["literal"] not in catalog_keys]
    missing_translations = [
        key for key, entry in catalog_keys.items()
        if not entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
    ]
    unused_keys = [key for key in catalog_keys if key not in all_source_text]

    fatal = False

    if missing_entries:
        fatal = True
        print(f"[FATAL] {len(missing_entries)} string literal(s) not in Localizable.xcstrings:")
        for f in missing_entries:
            tag = "JA" if f["kind"] == "ja" else "EN-hardcoded"
            print(f"  {f['file']}:{f['line']} [{tag}] {f['literal']!r}")
        print(
            "  -> add an entry to scripts/generate-localizable.py's `translations` "
            "dict and rerun it (`python3 scripts/generate-localizable.py`), or "
            "whitelist the literal in check-localizable-coverage.py if it's "
            "intentionally untranslated (brand name / protocol jargon)."
        )
        print()

    if missing_translations:
        fatal = True
        print(f"[FATAL] {len(missing_translations)} catalog key(s) missing an `en` translation:")
        for key in sorted(missing_translations):
            print(f"  {key!r}")
        print()

    if unused_keys:
        print(f"[WARN] {len(unused_keys)} catalog key(s) not found (substring search) in scanned source — deletion candidates:")
        for key in sorted(unused_keys):
            print(f"  {key!r}")
        print()

    if fatal:
        print("Localization coverage check FAILED.")
        return 1
    print(
        f"Localization coverage check passed "
        f"({len(catalog_keys)} catalog keys, {len(findings)} literal(s) scanned"
        f"{', ' + str(len(unused_keys)) + ' unused warning(s)' if unused_keys else ''})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
