import Testing
@testable import OtegamiCore

/// Task #100 ("フッターツールバーのカスタマイズ"). `MessageToolbarSettingsStore`
/// (app target, no unit test target of its own — see this file's sibling
/// doc comment on `MessageToolbarPreferencesCoding`) is a thin
/// `UserDefaults` wrapper around these pure functions, so the actual
/// migration/resolution rules are covered here instead.
@Suite("MessageToolbarPreferencesCoding")
struct MessageToolbarPreferencesTests {
    /// The original 7-action set (all visible by default) — used by most
    /// tests below, unchanged from the initial Task #100 shape.
    static let allVisibleDefaults: [MessageToolbarItemPreference] =
        ["reply", "forward", "search", "info", "summarize", "translate", "more"]
            .map { MessageToolbarItemPreference(id: $0, isVisible: true) }
    static let allVisibleIDs = allVisibleDefaults.map(\.id)
    static let pinnedTrailingID = "more"

    // MARK: - Fresh install / never saved before

    @Test("nil raw value falls back to the given per-id default visibility")
    func nilRawFallsBackToDefault() {
        let items = MessageToolbarPreferencesCoding.parse(raw: nil, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == Self.allVisibleIDs)
        #expect(items.allSatisfy { $0.isVisible })
    }

    @Test("empty string raw value falls back to the given per-id default visibility")
    func emptyRawFallsBackToDefault() {
        let items = MessageToolbarPreferencesCoding.parse(raw: "", defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == Self.allVisibleIDs)
    }

    // MARK: - 後方互換: 旧形式 (順序のみ、可視性の概念が無い) を読める

    @Test("legacy plain comma-joined order (pre-#100, no visibility suffix) round-trips as all-visible")
    func legacyFormatIsAllVisible() {
        let legacyRaw = "more,reply,forward,search,info,summarize,translate"
        let items = MessageToolbarPreferencesCoding.parse(raw: legacyRaw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        // "more" pinned to the end regardless of where the legacy string put it.
        #expect(items.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
        #expect(items.allSatisfy { $0.isVisible })
    }

    @Test("legacy order missing an action whose default is visible appends it visible")
    func legacyFormatAppendsMissingVisibleAction() {
        // Simulates a user who customized order before `summarize`/`translate` (Task #88) existed.
        let legacyRaw = "reply,forward,search,info,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: legacyRaw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
        #expect(items.allSatisfy { $0.isVisible })
    }

    // MARK: - 新形式: 順序 + 可視性

    @Test("new format parses visibility flags")
    func newFormatParsesVisibility() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:1,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        let visibility = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.isVisible) })
        #expect(visibility["reply"] == true)
        #expect(visibility["forward"] == false)
        #expect(visibility["info"] == false)
    }

    @Test("round trip through encode then parse preserves order and visibility")
    func encodeParseRoundTrip() {
        let items = [
            MessageToolbarItemPreference(id: "translate", isVisible: true),
            MessageToolbarItemPreference(id: "reply", isVisible: false),
            MessageToolbarItemPreference(id: "forward", isVisible: true),
            MessageToolbarItemPreference(id: "search", isVisible: false),
            MessageToolbarItemPreference(id: "info", isVisible: true),
            MessageToolbarItemPreference(id: "summarize", isVisible: true)
        ]
        let raw = MessageToolbarPreferencesCoding.encode(items, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        let reparsed = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(reparsed.map(\.id) == ["translate", "reply", "forward", "search", "info", "summarize", "more"])
        #expect(reparsed.map(\.isVisible) == [true, false, true, false, true, true, true])
    }

    // MARK: - 不明な ID / 欠けている ID

    @Test("unknown IDs from a future or removed action are dropped")
    func unknownIDsAreDropped() {
        let raw = "reply,ghost-action:0,forward,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(!items.map(\.id).contains("ghost-action"))
    }

    @Test("duplicate tokens keep only the first occurrence")
    func duplicateTokensKeepFirst() {
        let raw = "reply:0,forward,reply:1,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.filter { $0.id == "reply" }.count == 1)
        #expect(items.first { $0.id == "reply" }?.isVisible == false)
    }

    // MARK: - 「その他」(pinnedTrailingID) は常に可視・常に末尾・並び替え不可

    @Test("pinned trailing ID is forced visible even if saved as hidden")
    func pinnedTrailingIDForcedVisible() {
        let raw = "reply,forward,search,info,summarize,translate,more:0"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.last?.id == "more")
        #expect(items.last?.isVisible == true)
    }

    @Test("pinned trailing ID is moved to the end even if saved first")
    func pinnedTrailingIDMovedToEnd() {
        let raw = "more,reply,forward,search,info,summarize,translate"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.last?.id == "more")
        #expect(items.filter { $0.id == "more" }.count == 1)
    }

    @Test("normalize applied directly also enforces the pinned trailing invariant")
    func normalizeEnforcesPinnedTrailing() {
        let items = [
            MessageToolbarItemPreference(id: "more", isVisible: false),
            MessageToolbarItemPreference(id: "reply", isVisible: true)
        ]
        let normalized = MessageToolbarPreferencesCoding.normalize(items, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(normalized.last == MessageToolbarItemPreference(id: "more", isVisible: true))
        #expect(normalized.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
    }

    // MARK: - visibleOrder / hiddenOrder

    @Test("visibleOrder returns only visible ids in saved order")
    func visibleOrderFiltersHidden() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:0,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(MessageToolbarPreferencesCoding.visibleOrder(items) == ["reply", "search", "summarize", "more"])
    }

    @Test("hiddenOrder returns only hidden ids, excluding the pinned trailing ID")
    func hiddenOrderExcludesPinnedTrailing() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:0,more:0"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        // "more:0" in the raw string is overridden to visible by normalize, so it must never show up as hidden.
        #expect(MessageToolbarPreferencesCoding.hiddenOrder(items, pinnedTrailingID: Self.pinnedTrailingID) == ["forward", "info", "translate"])
    }

    @Test("all actions hidden except the pinned trailing one is a valid state")
    func allHiddenExceptPinnedTrailing() {
        let raw = "reply:0,forward:0,search:0,info:0,summarize:0,translate:0,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.allVisibleDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(MessageToolbarPreferencesCoding.visibleOrder(items) == ["more"])
        #expect(MessageToolbarPreferencesCoding.hiddenOrder(items, pinnedTrailingID: Self.pinnedTrailingID) == ["reply", "forward", "search", "info", "summarize", "translate"])
    }

    // MARK: - 追加仕様 (2026-07-29): 「その他」メニューのネイティブ項目
    // (mute/pin/markUnread/archive/junk/draftEnglishReply/delete) を
    // 一級の `MessageToolbarAction` に昇格 — 新規 ID ごとに異なる既定可視性
    // (一部は表示、一部は非表示) で追加できることの検証。

    /// 実アプリの`MessageToolbarSettingsStore.defaultOrder`を模した、
    /// 「一部だけ既定で可視」の defaults セット — 6つの既存アクション
    /// (+`more`) は可視、新規昇格した7アクションは非可視がデフォルト。
    static let mixedVisibilityDefaults: [MessageToolbarItemPreference] = [
        MessageToolbarItemPreference(id: "reply", isVisible: true),
        MessageToolbarItemPreference(id: "forward", isVisible: true),
        MessageToolbarItemPreference(id: "search", isVisible: true),
        MessageToolbarItemPreference(id: "info", isVisible: true),
        MessageToolbarItemPreference(id: "summarize", isVisible: true),
        MessageToolbarItemPreference(id: "translate", isVisible: true),
        MessageToolbarItemPreference(id: "mute", isVisible: false),
        MessageToolbarItemPreference(id: "pin", isVisible: false),
        MessageToolbarItemPreference(id: "markUnread", isVisible: false),
        MessageToolbarItemPreference(id: "archive", isVisible: false),
        MessageToolbarItemPreference(id: "junk", isVisible: false),
        MessageToolbarItemPreference(id: "draftEnglishReply", isVisible: false),
        MessageToolbarItemPreference(id: "delete", isVisible: false),
        MessageToolbarItemPreference(id: "more", isVisible: true)
    ]

    @Test("fresh install with mixed-visibility defaults matches each id's own default")
    func freshInstallMatchesMixedDefaults() {
        let items = MessageToolbarPreferencesCoding.parse(raw: nil, defaults: Self.mixedVisibilityDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(MessageToolbarPreferencesCoding.visibleOrder(items) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
        #expect(MessageToolbarPreferencesCoding.hiddenOrder(items, pinnedTrailingID: Self.pinnedTrailingID) ==
            ["mute", "pin", "markUnread", "archive", "junk", "draftEnglishReply", "delete"])
    }

    @Test("a pre-existing save from before the promoted actions existed gets them appended hidden, not visible")
    func preExistingSaveAppendsPromotedActionsHidden() {
        // A user who customized order back when only the original 7 ids existed.
        let legacyRaw = "translate:1,reply:1,forward:0,search:1,info:1,summarize:1,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: legacyRaw, defaults: Self.mixedVisibilityDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        // Their own prior customization (forward hidden) survives...
        #expect(items.first { $0.id == "forward" }?.isVisible == false)
        // ...and the 7 newly-promoted actions land at the end (in defaults'
        // order), each hidden per its own default — never visible, and
        // never silently inserted ahead of the user's existing order.
        let promotedIDs = ["mute", "pin", "markUnread", "archive", "junk", "draftEnglishReply", "delete"]
        let trailingBeforeMore = items.dropLast().suffix(promotedIDs.count)
        #expect(trailingBeforeMore.map(\.id) == promotedIDs)
        #expect(trailingBeforeMore.allSatisfy { !$0.isVisible })
        #expect(items.last?.id == "more")
    }

    @Test("a user who had already turned a promoted action on before this test existed keeps it visible")
    func explicitlySavedPromotedActionVisibilityIsPreserved() {
        // Not a realistic upgrade path (these ids didn't exist yet to save
        // as visible), but guards that *explicit* saved state always wins
        // over the default, regardless of which id it is.
        let raw = "reply:1,forward:1,search:1,info:1,summarize:1,translate:1,archive:1,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, defaults: Self.mixedVisibilityDefaults, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.first { $0.id == "archive" }?.isVisible == true)
    }
}
