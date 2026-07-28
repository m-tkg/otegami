import Foundation

/// B4 「本文プレビューの行数」: なし/1行/2行/3行 — `rawValue` doubles as the actual
/// `lineLimit` passed to the preview `Text` (`0` meaning "show none").
enum PreviewLineCount: Int, CaseIterable, Identifiable {
    case none = 0
    case one = 1
    case two = 2
    case three = 3

    var id: Int { rawValue }

    // A「表示・操作改善バッチ」以降の`Text(String)`は自動でローカライズされない
    // ("verbatim"呼び出し) — `docs/localization.md`のパターン1どおり
    // `String(localized:)`で明示的にカタログを引く (`MailListSettingsView`の
    // `Picker`が`Text(count.title)`としてこの`String`を渡すため。以前は
    // ここが未対応で、表示言語を English にしても本文プレビューの行数
    // ピッカーだけ日本語のままになる実バグだった)。
    var title: String {
        switch self {
        case .none: String(localized: "なし")
        case .one: String(localized: "1行")
        case .two: String(localized: "2行")
        case .three: String(localized: "3行")
        }
    }
}

/// B3/B4 「一覧・表示」設定: list-density preferences, all plain `UserDefaults`
/// keys read directly via `@AppStorage` — same reasoning as
/// `SwipeActionSettingsStore`/`TranslationSettingsStore` (a per-device UI
/// preference with no other business logic attached doesn't need a
/// dependency-injected home).
enum ListDisplaySettingsStore {
    /// B3 「スレッド表示」— ON groups the list by conversation (the app's
    /// normal behavior); OFF shows one row per message. See
    /// `ThreadSummary.init(flatMessage:accountId:)` and `MessageListView`'s
    /// flat-mode doc comment for the query/rendering design.
    ///
    /// Stored as a positive "threading is on" flag rather than the negative
    /// "don't group into threads" it started as: a toggle labelled with a
    /// negation reads backwards ("turn ON 'don't group'"), which is exactly
    /// the confusion this rename removes. Default on — threading is this
    /// app's documented list behavior (`README.md`'s Features section).
    static let threadingKey = "listDisplay.threading"
    static let defaultThreading = true

    /// B4 「送信者のプロフィールアイコンの表示」: initials-on-account-color circular
    /// avatar (`SenderAvatar`) — no external image fetch, ever (privacy:
    /// this task's explicit constraint). Default on: it's a small, low-risk
    /// addition to the existing row layout and is the whole point of
    /// building `SenderAvatar` in the first place.
    static let showAvatarKey = "listDisplay.showAvatar"
    static let defaultShowAvatar = true

    /// B4 「本文プレビューの行数」— see `PreviewLineCount`. Default `.one`
    /// matches this app's pre-existing row layout (`ThreadRowTextStack`'s
    /// single-line snippet), so leaving this setting untouched changes
    /// nothing for an existing user.
    static let previewLineCountKey = "listDisplay.previewLineCount"
    static let defaultPreviewLineCount = PreviewLineCount.one

    /// B5 「本文にも送信者アイコンを出す」: shows `SenderAvatar` next to each
    /// message's header inside `MessageView`/`ThreadDetailView`. Default on,
    /// same rationale as `showAvatarKey`.
    static let showAvatarInDetailKey = "listDisplay.showAvatarInDetail"
    static let defaultShowAvatarInDetail = true

    /// メール一覧ヘッダの「未読のみ表示」トグル (iOS only — `MailScreenView`'s
    /// header, wired into `MessageListView.observeThreads()`'s
    /// `ThreadQuery` calls via `unreadOnly:`). Default off: opting into a
    /// narrower list is a deliberate per-session choice, not something a
    /// first-run user should be surprised by. macOS never presents a control
    /// for this key (`CLAUDE.md`: macOS の3ペインは対象外) — it stays at its
    /// default there, so this doesn't change macOS's own list content.
    static let unreadOnlyKey = "listDisplay.unreadOnly"
    static let defaultUnreadOnly = false

    /// Task #77 (ユーザー要望「アカウントごとにグルーピングする設定」、Spark の
    /// 参考画像参照) で追加、Task #92 (アカウントダイジェスト画面) で意味が
    /// 変わったキー — メール一覧ヘッダの「アカウントでグループ化」ボタン
    /// (iOS only — `unreadOnlyKey`と同じ場所、`MailScreenView`の
    /// `groupByAccountToggleButton`)。
    ///
    /// **#77時点**: ON で `MessageListView` がアカウントごとのセクション
    /// (色罫線＋表示名＋件数バッジ、`AccountGroupSectionHeader`) に一覧を
    /// インラインで分割する、恒久的な表示設定だった。
    ///
    /// **#92以降**: インライン分割は廃止し、ボタンは`AccountDigestView`
    /// (アカウントごとの件数+直近プレビューを一段挟んで見せる画面)への
    /// 遷移トリガーになった — このキーは「一覧をこの場でグルーピングする
    /// か」という恒久設定ではなく、「ダイジェスト画面を(一時的に)開いて
    /// いるか」を表す一時的な値になった(`MailScreenView`がダイジェスト
    /// 画面の開閉に合わせて`true`/`false`を書く)。`MessageListView`は
    /// このキーをもう一切読まない。ボタンの見た目/配置・キー名・
    /// `UserDefaults`保存の仕組み自体は変えていない。
    ///
    /// 単一アカウントしか無い、またはアカウント絞り込みチップ・単一メール
    /// ボックス選択中でダイジェストが無意味な画面ではボタン自体を出さない
    /// (`MailScreenView.showsGroupByAccountToggle`/`MessageListView
    /// .showsAccountAccent`と同じ条件)。Default off:
    /// `unreadOnlyKey`と同じ理由 — 初回起動ユーザーを驚かせない既定に倒す。
    static let groupByAccountKey = "listDisplay.groupByAccount"
    static let defaultGroupByAccount = false

    /// Task #82 (実機報告「OTAインストール後の起動で、設定はオフ表示なのに
    /// 一覧がスレッド表示。トグルをオン→オフすると直る」): reads `key`
    /// directly from `UserDefaults.standard`, bypassing whatever value a
    /// `@AppStorage`-declared property bound to the same key currently
    /// holds in a given `View` instance.
    ///
    /// `@AppStorage`'s own `= default` parameter only ever supplies that one
    /// property's fallback for a key with no stored value at all — it's
    /// otherwise just a thin, per-call-site cache over the same
    /// `UserDefaults` storage. The real-device report above was tracked
    /// down to exactly that cache: `MessageListView`'s `@AppStorage`-backed
    /// `isThreadingEnabled` returned the compiled-in default (`true`) on
    /// the very first post-launch observation despite `threadingKey`
    /// already being persisted as `false` from a previous session, and kept
    /// returning it until *something* wrote to that key again (toggling it
    /// on then off in Settings) — Apple doesn't document `@AppStorage`'s
    /// internal caching precisely enough to say exactly why the first read
    /// can lag, but the fix doesn't need to explain that, only route around
    /// it: any call site that decides *which database query to run* — where
    /// a stale read produces a visibly wrong result for as long as the view
    /// stays alive, unlike a purely cosmetic label — should read straight
    /// from here instead of trusting its own `@AppStorage` property's
    /// current in-memory value, so the very first observation after launch
    /// (and every one after it) is guaranteed to reflect whatever is
    /// actually on disk. The `@AppStorage` property itself is still worth
    /// declaring alongside this: SwiftUI's own change-tracking for that
    /// property is what makes the view re-render (and re-run this fresh
    /// read) the moment the setting changes anywhere else in the app.
    static func persistedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? defaultValue
    }
}
