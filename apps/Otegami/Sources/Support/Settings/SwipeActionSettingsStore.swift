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

    // A「表示・操作改善バッチ」以降の`Text(String)`は自動でローカライズされない
    // ("verbatim"呼び出し) — `docs/localization.md`のパターン1どおり
    // `String(localized:)`で明示的にカタログを引く (`MailListSettingsView`の
    // `Picker`が`Text(action.title)`としてこの`String`を渡すため。以前は
    // ここが未対応で、スワイプ設定ピッカーだけ表示言語を英語にしても日本語の
    // ままになる実バグだった)。
    var title: String {
        switch self {
        case .toggleRead: String(localized: "既読/未読切替")
        case .archive: String(localized: "アーカイブ")
        case .junk: String(localized: "迷惑メールにする")
        case .pin: String(localized: "ピン留め")
        case .delete: String(localized: "削除")
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
}

/// D8 「スワイプの割り当て」: 左右スワイプそれぞれに短い/長いスワイプの2アクションを
/// 割り当てられる設定。しきい値で自動実行バッチ以降、"短い"/"長い" は
/// `MessageListRow`の自前 `DragGesture` が実測するドラッグ距離のしきい値
/// (`shortSwipeThreshold`/`longSwipeThreshold`) そのものに対応する —
/// ドラッグ距離がしきい値を超えた状態で指を離すと、対応するアクションが
/// ボタンを経由せずその場で実行される（旧: SwiftUI 標準の `.swipeActions`
/// はグループ内の最初の1つしかフルスワイプで自動発火できず、"長い" 側は
/// 常にボタンを出してタップさせるしかなかった — 詳細は
/// `MessageListRow`のドキュメントコメントと `docs/design-system.md` 参照）。
/// 四つの独立したキー/スロット (leading-short/-long, trailing-short/-long)
/// で、D8 が要求する「左右それぞれの短い/長いペア」を個別に設定できる。
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
