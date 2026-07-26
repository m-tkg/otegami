import Foundation

/// D8 スワイプ設定: the 5 actions assignable to any swipe slot. Also used by
/// macOS's row context menu (`MessageListRow.contextMenuContent`), which has
/// no concept of "short"/"long" and just lists every action.
enum SwipeAction: String, CaseIterable, Identifiable {
    case toggleRead
    case archive
    case junk
    case pin
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleRead: "既読/未読切替"
        case .archive: "アーカイブ"
        case .junk: "迷惑メールにする"
        case .pin: "ピン留め"
        case .delete: "削除"
        }
    }

    var systemImage: String {
        switch self {
        case .toggleRead: "envelope.open"
        case .archive: "archivebox"
        case .junk: "exclamationmark.octagon"
        case .pin: "pin"
        case .delete: "trash"
        }
    }

    /// Whether this action is allowed to auto-fire from a full swipe
    /// (`.swipeActions(allowsFullSwipe:)`) when assigned to a slot whose
    /// declaration order would otherwise make it eligible (SwiftUI only
    /// ever auto-fires the *first* declared action in a `.swipeActions`
    /// group — see `MessageListRow`'s doc comment). `false` for delete/junk
    /// specifically: both move messages out of the visible mailbox with no
    /// extra confirmation step, and design-phase-2 already established
    /// (`docs/design-system.md`'s deviations section) that this app treats
    /// "a swipe alone can never trigger a message-moving action" as a
    /// stronger, deliberate reading of the handoff's "誤操作防止" than a
    /// literal full-swipe-eligible delete would be. Every other action
    /// (既読/未読, アーカイブ, ピン留め) is fully reversible with one more tap,
    /// so a full swipe is fine for those.
    var isGuardedFromFullSwipe: Bool {
        switch self {
        case .delete, .junk: true
        case .toggleRead, .archive, .pin: false
        }
    }
}

/// D8 「スワイプの割り当て」: 左右スワイプそれぞれに短い/長いスワイプの2アクションを
/// 割り当てられる設定。SwiftUI's `.swipeActions` can only auto-fire the
/// *first declared* action in a group on a full swipe (no public API for
/// two distance-based thresholds each firing a different action) — this
/// still approximates "短い/長い" the same way design-phase-2's single-slot
/// version already did: the "短い" action is declared first (closer to the
/// row's edge, reachable by revealing less of the row, and eligible for a
/// full-swipe auto-fire unless `SwipeAction.isGuardedFromFullSwipe`), the
/// "長い" action is declared second (requires revealing further, always
/// tap-only). Four independent keys/slots this time (leading-short/-long,
/// trailing-short/-long) instead of one, since D8 asks for both edges'
/// short/long pair to be configurable, not just the leading edge's.
///
/// Defaults match the previous fixed 1g assignment exactly (right-short=
/// 既読/未読, right-long=アーカイブ, left=削除 for both slots — this app's
/// "右" swipe reveals the *leading* edge, "左" reveals *trailing*, matching
/// SwiftUI's own naming for a left-to-right UI).
///
/// Raw-string-backed (not the enum itself), read directly via `@AppStorage`
/// from both `MessageListRow` and `AccountsListContent`'s settings picker —
/// same reasoning as this type's own previous single-key version: simpler
/// than threading a binding down through `MessageListView`/`MessageListRow`
/// 's already-long initializer parameter lists for a per-device UI
/// preference with no other business logic attached.
enum SwipeActionSettingsStore {
    static let leadingShortActionKey = "swipeActions.leadingShort"
    static let leadingLongActionKey = "swipeActions.leadingLong"
    static let trailingShortActionKey = "swipeActions.trailingShort"
    static let trailingLongActionKey = "swipeActions.trailingLong"

    static let defaultLeadingShort = SwipeAction.toggleRead
    static let defaultLeadingLong = SwipeAction.archive
    static let defaultTrailingShort = SwipeAction.delete
    static let defaultTrailingLong = SwipeAction.delete
}
