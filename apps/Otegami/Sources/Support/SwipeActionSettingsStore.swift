import Foundation

/// 1l "操作" settings block: "スワイプの割り当て". SwiftUI's `.swipeActions` can
/// only auto-fire the *first declared* action on a full swipe (no public
/// API for two distance-based thresholds each firing a different action —
/// `MessageListRow`'s own doc comment on `leadingSwipeActions`), and the
/// trailing edge only ever has one real action (削除, deliberately
/// tap-only — see that same file). That leaves exactly one axis worth
/// exposing as a user preference: **which of the two leading actions
/// (既読/未読, アーカイブ) is the "quick" one** reachable by a full swipe.
///
/// This is a deliberately narrower reading of the handoff's "スワイプ割り当て
/// のカスタマイズ" than "assign any action to any slot" — a fully generic
/// per-edge action registry would mean reworking `MessageListRow`/
/// `MessageListView`'s hand-wired `onToggleRead`/`onArchive`/`onDelete`
/// closures into a dispatch table for two fixed slots, a much larger
/// refactor for marginal value once 翻訳/後で (the only other actions the
/// handoff even mentions) still have no backing feature to assign either
/// (see `MessageListRow`'s reserved-slot comment). See
/// `docs/design-system.md`'s design-phase-3 section for the full reasoning
/// behind scoping it down instead of skipping it entirely.
enum LeadingSwipeQuickAction: String, CaseIterable, Identifiable {
    case toggleRead
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleRead: "既読/未読"
        case .archive: "アーカイブ"
        }
    }
}

enum SwipeActionSettingsStore {
    /// Raw-string-backed (not the enum itself) so both the Settings
    /// `Picker` and `MessageListRow` can each independently declare
    /// `@AppStorage(SwipeActionSettingsStore.leadingQuickActionKey)` against
    /// the same key without threading a binding down through
    /// `MessageListView`/`MessageListRow`'s already-long initializer
    /// parameter lists — `@AppStorage` reads `UserDefaults` directly, so
    /// this is simpler than adding yet another `AppEnvironment`-sourced
    /// parameter purely for a per-device UI preference with no other
    /// business logic attached.
    static let leadingQuickActionKey = "swipeActions.leadingQuickAction"
}
