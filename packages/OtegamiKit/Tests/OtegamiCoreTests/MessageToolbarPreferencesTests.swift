import Testing
@testable import OtegamiCore

/// Task #100 ("フッターツールバーのカスタマイズ"). `MessageToolbarSettingsStore`
/// (app target, no unit test target of its own — see this file's sibling
/// doc comment on `MessageToolbarPreferencesCoding`) is a thin
/// `UserDefaults` wrapper around these pure functions, so the actual
/// migration/resolution rules are covered here instead.
@Suite("MessageToolbarPreferencesCoding")
struct MessageToolbarPreferencesTests {
    static let knownIDs = ["reply", "forward", "search", "info", "summarize", "translate", "more"]
    static let pinnedTrailingID = "more"

    // MARK: - Fresh install / never saved before

    @Test("nil raw value falls back to all-visible default order")
    func nilRawFallsBackToDefault() {
        let items = MessageToolbarPreferencesCoding.parse(raw: nil, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == Self.knownIDs)
        #expect(items.allSatisfy { $0.isVisible })
    }

    @Test("empty string raw value falls back to all-visible default order")
    func emptyRawFallsBackToDefault() {
        let items = MessageToolbarPreferencesCoding.parse(raw: "", knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == Self.knownIDs)
    }

    // MARK: - 後方互換: 旧形式 (順序のみ、可視性の概念が無い) を読める

    @Test("legacy plain comma-joined order (pre-#100, no visibility suffix) round-trips as all-visible")
    func legacyFormatIsAllVisible() {
        let legacyRaw = "more,reply,forward,search,info,summarize,translate"
        let items = MessageToolbarPreferencesCoding.parse(raw: legacyRaw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        // "more" pinned to the end regardless of where the legacy string put it.
        #expect(items.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
        #expect(items.allSatisfy { $0.isVisible })
    }

    @Test("legacy order missing an action (saved before that action existed) appends it visible")
    func legacyFormatAppendsMissingAction() {
        // Simulates a user who customized order before `summarize`/`translate` (Task #88) existed.
        let legacyRaw = "reply,forward,search,info,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: legacyRaw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
        #expect(items.allSatisfy { $0.isVisible })
    }

    // MARK: - 新形式: 順序 + 可視性

    @Test("new format parses visibility flags")
    func newFormatParsesVisibility() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:1,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
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
        let raw = MessageToolbarPreferencesCoding.encode(items, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        let reparsed = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(reparsed.map(\.id) == ["translate", "reply", "forward", "search", "info", "summarize", "more"])
        #expect(reparsed.map(\.isVisible) == [true, false, true, false, true, true, true])
    }

    // MARK: - 不明な ID / 欠けている ID

    @Test("unknown IDs from a future or removed action are dropped")
    func unknownIDsAreDropped() {
        let raw = "reply,ghost-action:0,forward,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(!items.map(\.id).contains("ghost-action"))
    }

    @Test("duplicate tokens keep only the first occurrence")
    func duplicateTokensKeepFirst() {
        let raw = "reply:0,forward,reply:1,more"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.filter { $0.id == "reply" }.count == 1)
        #expect(items.first { $0.id == "reply" }?.isVisible == false)
    }

    // MARK: - 「その他」(pinnedTrailingID) は常に可視・常に末尾・並び替え不可

    @Test("pinned trailing ID is forced visible even if saved as hidden")
    func pinnedTrailingIDForcedVisible() {
        let raw = "reply,forward,search,info,summarize,translate,more:0"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.last?.id == "more")
        #expect(items.last?.isVisible == true)
    }

    @Test("pinned trailing ID is moved to the end even if saved first")
    func pinnedTrailingIDMovedToEnd() {
        let raw = "more,reply,forward,search,info,summarize,translate"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(items.last?.id == "more")
        #expect(items.filter { $0.id == "more" }.count == 1)
    }

    @Test("normalize applied directly also enforces the pinned trailing invariant")
    func normalizeEnforcesPinnedTrailing() {
        let items = [
            MessageToolbarItemPreference(id: "more", isVisible: false),
            MessageToolbarItemPreference(id: "reply", isVisible: true)
        ]
        let normalized = MessageToolbarPreferencesCoding.normalize(items, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(normalized.last == MessageToolbarItemPreference(id: "more", isVisible: true))
        #expect(normalized.map(\.id) == ["reply", "forward", "search", "info", "summarize", "translate", "more"])
    }

    // MARK: - visibleOrder / hiddenOrder

    @Test("visibleOrder returns only visible ids in saved order")
    func visibleOrderFiltersHidden() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:0,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(MessageToolbarPreferencesCoding.visibleOrder(items) == ["reply", "search", "summarize", "more"])
    }

    @Test("hiddenOrder returns only hidden ids, excluding the pinned trailing ID")
    func hiddenOrderExcludesPinnedTrailing() {
        let raw = "reply:1,forward:0,search:1,info:0,summarize:1,translate:0,more:0"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        // "more:0" in the raw string is overridden to visible by normalize, so it must never show up as hidden.
        #expect(MessageToolbarPreferencesCoding.hiddenOrder(items, pinnedTrailingID: Self.pinnedTrailingID) == ["forward", "info", "translate"])
    }

    @Test("all actions hidden except the pinned trailing one is a valid state")
    func allHiddenExceptPinnedTrailing() {
        let raw = "reply:0,forward:0,search:0,info:0,summarize:0,translate:0,more:1"
        let items = MessageToolbarPreferencesCoding.parse(raw: raw, knownIDs: Self.knownIDs, pinnedTrailingID: Self.pinnedTrailingID)
        #expect(MessageToolbarPreferencesCoding.visibleOrder(items) == ["more"])
        #expect(MessageToolbarPreferencesCoding.hiddenOrder(items, pinnedTrailingID: Self.pinnedTrailingID) == ["reply", "forward", "search", "info", "summarize", "translate"])
    }
}
