import Foundation

#if os(macOS)
/// Task #158 (macOS「アップデートを確認」機能): the payload
/// `OtegamiCommands`' "アップデートを確認…" menu item passes to
/// `openWindow(id: "updateCheck", value:)`. Wraps `includePrereleases`
/// (option-click detection, `OtegamiCommands.swift`) together with a fresh
/// `id` on every invocation — `WindowGroup(for:)` treats a value it's
/// already showing a window for as "bring that window forward" rather than
/// "open a new one" (SwiftUI's standard window-per-distinct-value
/// dedup), so without a fresh `id` here, clicking the menu item a second
/// time while a stale result window is still open would just refocus the
/// old result instead of checking again.
struct UpdateCheckRequest: Codable, Hashable, Sendable {
    var includePrereleases: Bool
    var id = UUID()
}
#endif
