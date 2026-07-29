import Foundation

/// One item's saved state within a reorderable/hideable toolbar: which
/// action it is (as an opaque string ID) and whether it currently renders
/// inline (`true`) or has been pushed into an overflow menu (`false`).
///
/// This type — and `MessageToolbarPreferencesCoding` below — is
/// deliberately generic over plain `String` IDs rather than the app's
/// `MessageToolbarAction` enum: `MessageToolbarAction` lives in
/// `apps/Otegami/Sources/Support/MessageToolbarSettingsStore.swift` because
/// its `title`/`systemImage` need `String(localized:)` resolved against the
/// app's own string catalog, but `apps/Otegami` has no unit test target
/// (only XCUITest, which needs a simulator — see `docs/verify.md`). Keeping
/// the actual order/visibility parsing, migration, and invariant-enforcement
/// logic here in `OtegamiCore` ("Linux-compatible model & pure-logic layer.
/// No dependencies." per `Package.swift`) means it's covered by
/// `swift test` (`make test`) like everything else in this target, and the
/// app-side `MessageToolbarSettingsStore` becomes a thin
/// `UserDefaults`-reading/writing wrapper around it.
public struct MessageToolbarItemPreference: Equatable, Sendable {
    public let id: String
    public var isVisible: Bool

    public init(id: String, isVisible: Bool) {
        self.id = id
        self.isVisible = isVisible
    }
}

/// Task #100 ("フッターツールバーのカスタマイズ" — toggle each action's
/// visibility, drag-reorder the visible ones, push hidden ones into an
/// overflow menu whose own trigger action can never itself be hidden or
/// reordered). Pure parse/encode/normalize functions; no `UserDefaults`
/// access (the caller owns that).
///
/// **Raw string format** (comma-joined, one `UserDefaults` string):
/// `"id1:1,id2:0,id3"` — `:1`/`:0` is the visibility flag (`1` = visible),
/// and a bare id with no `:` suffix (the *pre-#100* format, when this
/// feature only stored order — see `MessageToolbarSettingsStore`'s doc
/// comment) is treated as visible. This is the "旧形式キーを読める"
/// back-compat: same `UserDefaults` key, same comma-joined-tokens shape,
/// just an optional per-token suffix — an old-format string round-trips
/// through `parse` into "everything visible, in its saved order" exactly
/// as `loadOrder()` used to behave, so existing users' saved order survives
/// the upgrade unchanged (nothing was hidden before this feature existed).
///
/// **`defaults` parameter (not just a plain ID list)**: every `parse`/
/// `encode`/`normalize` call takes the *full default item set* — id, order,
/// **and each id's own default visibility** — rather than a bare
/// `[String]` of valid IDs. This is what lets a later app update introduce
/// a brand-new ID with a *specific* fallback visibility instead of always
/// defaulting missing IDs to visible: Task #88's `summarize`/`translate`
/// wanted "newly visible" (append before the overflow trigger), but the
/// follow-up batch that promoted the overflow menu's own native actions
/// (mute/pin/mark-unread/archive/junk/draft-English-reply/delete) into
/// first-class, customizable `MessageToolbarAction` cases wants the
/// opposite — "still hidden by default, exactly where they already were" —
/// for every user who upgrades with a pre-existing saved order that
/// predates those IDs. A single hardcoded "missing = visible" rule (the
/// original Task #100 shape of this API) can't express both defaults at
/// once; per-ID defaults can.
public enum MessageToolbarPreferencesCoding {
    /// Parses a raw `UserDefaults` string (or `nil`/empty, i.e. "never
    /// saved before") into normalized items.
    ///
    /// - `defaults`: the full default item set, in the order missing/new
    ///   ones should be appended, each carrying its own fallback
    ///   visibility (see this type's doc comment). An ID from `raw` that
    ///   isn't in `defaults` is dropped (stale ID from a since-removed
    ///   action); a `defaults` entry missing from `raw` is appended using
    ///   *that entry's own* `isVisible` (an app upgrade that adds a new
    ///   action never silently drops it from the toolbar, but doesn't have
    ///   to default it to visible either).
    /// - `pinnedTrailingID`: forced visible and moved to the end regardless
    ///   of what `raw` said (the "その他" overflow trigger — it can't be
    ///   hidden or reordered).
    public static func parse(raw: String?, defaults: [MessageToolbarItemPreference], pinnedTrailingID: String) -> [MessageToolbarItemPreference] {
        let knownIDs = Set(defaults.map(\.id))
        var items: [MessageToolbarItemPreference] = []
        var seen = Set<String>()
        if let raw, !raw.isEmpty {
            for token in raw.split(separator: ",") {
                let parts = token.split(separator: ":", maxSplits: 1)
                guard let idPart = parts.first else { continue }
                let id = String(idPart)
                guard knownIDs.contains(id), !seen.contains(id) else { continue }
                let isVisible = parts.count > 1 ? parts[1] != "0" : true
                items.append(MessageToolbarItemPreference(id: id, isVisible: isVisible))
                seen.insert(id)
            }
        }
        for defaultItem in defaults where !seen.contains(defaultItem.id) {
            items.append(defaultItem)
            seen.insert(defaultItem.id)
        }
        return normalize(items, defaults: defaults, pinnedTrailingID: pinnedTrailingID)
    }

    /// Encodes normalized items back to the raw `UserDefaults` string.
    public static func encode(_ items: [MessageToolbarItemPreference], defaults: [MessageToolbarItemPreference], pinnedTrailingID: String) -> String {
        normalize(items, defaults: defaults, pinnedTrailingID: pinnedTrailingID)
            .map { "\($0.id):\($0.isVisible ? "1" : "0")" }
            .joined(separator: ",")
    }

    /// Enforces the invariants both `parse` and `encode` rely on:
    /// - `pinnedTrailingID` (if it's in `defaults`) is always present,
    ///   always visible, and always last — wherever it appeared in `items`
    ///   is ignored.
    /// - every other `defaults` entry missing from `items` is appended
    ///   using that entry's own default visibility, in `defaults`'s order.
    /// - unknown ids and duplicates are dropped, first occurrence wins.
    public static func normalize(_ items: [MessageToolbarItemPreference], defaults: [MessageToolbarItemPreference], pinnedTrailingID: String) -> [MessageToolbarItemPreference] {
        let knownIDs = Set(defaults.map(\.id))
        var seen = Set<String>()
        var result: [MessageToolbarItemPreference] = []
        for item in items where knownIDs.contains(item.id) && item.id != pinnedTrailingID && !seen.contains(item.id) {
            result.append(item)
            seen.insert(item.id)
        }
        for defaultItem in defaults where defaultItem.id != pinnedTrailingID && !seen.contains(defaultItem.id) {
            result.append(defaultItem)
            seen.insert(defaultItem.id)
        }
        if knownIDs.contains(pinnedTrailingID) {
            result.append(MessageToolbarItemPreference(id: pinnedTrailingID, isVisible: true))
        }
        return result
    }

    /// IDs whose action currently renders inline, left-to-right order.
    public static func visibleOrder(_ items: [MessageToolbarItemPreference]) -> [String] {
        items.filter(\.isVisible).map(\.id)
    }

    /// IDs pushed into the overflow menu (excludes `pinnedTrailingID`
    /// itself, which is never hidden), in their saved order.
    public static func hiddenOrder(_ items: [MessageToolbarItemPreference], pinnedTrailingID: String) -> [String] {
        items.filter { !$0.isVisible && $0.id != pinnedTrailingID }.map(\.id)
    }
}

/// Task #113 (2) (実機フィードバック「ボタンのラベルを表示」トグル): pure
/// layout policy for whether the footer toolbar's icon+label buttons
/// (`MessageDetailFooterToolbar.toolbarIcon`/`toolbarAIIcon`, both
/// platforms) render their title `Text` alongside the icon, or collapse to
/// icon-only. Deliberately not `UserDefaults` access — that stays a plain
/// `Bool` key on the app-target `MessageToolbarSettingsStore`, same as
/// every other simple on/off preference in that file (no parsing/migration
/// needed for a fresh key with no legacy format) — this is just the one
/// bit of shared *rendering* math (the icon/label gap) worth covering with
/// `swift test`, since `apps/Otegami` itself has no unit test target (only
/// XCUITest, which needs a simulator — see `docs/verify.md`).
public enum MessageToolbarIconLayout {
    /// The `VStack` spacing between a toolbar icon and its label. `0` (not
    /// merely omitting the `Text`) once labels are off, so turning labels
    /// off also closes the gap they left behind — the Task #113 spec's
    /// "高さも詰める" (compact the row's height too, not just hide the
    /// text) requirement.
    public static func iconLabelSpacing(showsLabels: Bool) -> Double {
        showsLabels ? 2 : 0
    }
}
