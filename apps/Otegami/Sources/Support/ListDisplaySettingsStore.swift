import Foundation
import os

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
    /// 参考画像参照) で追加、Task #92→Task #99 で意味が変わったキー — メール
    /// 一覧ヘッダの「アカウントでグループ化」ボタン (iOS only —
    /// `unreadOnlyKey`と同じ場所、`MailScreenView`の
    /// `groupByAccountToggleButton`)。
    ///
    /// **#77時点**: ON で `MessageListView` がアカウントごとのセクション
    /// (色罫線＋表示名＋件数バッジ、`AccountGroupSectionHeader`) に一覧を
    /// インラインで分割する、恒久的な表示設定だった。
    ///
    /// **#92時点**: インライン分割は廃止し、ボタンは`AccountDigestView`
    /// (アカウントごとの件数+直近プレビューを一段挟んで見せる画面)への
    /// **プッシュ遷移**トリガーになった — このキーは一時的に「ダイジェスト
    /// 画面を開いているか」を表すだけの値になり、`MailScreenView`が画面の
    /// 開閉に合わせて書き戻していた。
    ///
    /// **#99時点**: プッシュ遷移をやめ、`unreadOnlyKey`と全く同じ「タップで
    /// on/off反転するだけの永続トグル」に戻した — アプリ再起動後も維持
    /// される。ONのとき`MailScreenView.content`が一覧領域の中身を
    /// `MessageListView`から`AccountDigestView`(埋め込み表示、ナビゲーション
    /// プッシュしない)に切り替える。`MessageListView`はこのキーをもう一切
    /// 読まない。キー名・`UserDefaults`保存の仕組み自体は#77から変えていない。
    ///
    /// **Task #106**: `MailScreenView`のヘッダにあった専用トグルボタン
    /// (`groupByAccountToggleButton`) 自体を廃止し、1a の「すべて」チップ
    /// (`AccountFilterChipRow.AllModeFilterChip`、SwiftUI `Menu`「時系列/
    /// アカウント別」) がこのキーをトグルするようになった — キーの意味・
    /// 保存の仕組みは変わらない。
    ///
    /// 単一アカウントしか無い、またはアカウント絞り込みチップ・単一メール
    /// ボックス選択中でダイジェストが無意味な画面では「すべて」チップ自体を
    /// 出さない (`MailScreenView.isAccountDigestEligible`/`MessageListView
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
        Self.forceReloadFromDiskOnce()
        // `.notice` (not `.debug`): debug/info は log collect のアーカイブに
        // 永続化されず、実機の事後採取 (Task #105 の再現調査) でこの行が
        // 1 行も残らなかった。stored=nil (未保存で既定値が効いた) か
        // 実際に false/true が保存されていたかの区別も調査に必須。
        let stored = UserDefaults.standard.object(forKey: key) as? Bool
        let value = stored ?? defaultValue
        Self.logger.notice("persistedBool(\(key, privacy: .public)) -> \(value, privacy: .public) (stored=\(stored.map(String.init) ?? "nil", privacy: .public), default \(defaultValue, privacy: .public))")
        return value
    }

    /// Task #105 (実機報告「スレッド表示はオフのまま (設定画面も含め) なのに、
    /// アプリを**再起動**した直後の一覧だけがスレッド表示になる。トグルを
    /// 一度オン→オフし直すと直る」): #82 (06c1062, 上の`persistedBool`の doc
    /// comment) は「`@AppStorage`の per-view インスタンスが持つキャッシュ
    /// 値」を疑い、`UserDefaults.standard`への直読みに変えたが、それでも
    /// この症状は直らなかった — 「設定画面 (別インスタンスの`@AppStorage`)
    /// を開けば常に正しい値が見える」という報告は、キャッシュがずれている
    /// 主体がビュー側の`@AppStorage`ではなく、**プロセス起動直後の
    /// `UserDefaults.standard`自身が保持するインメモリキャッシュ**である
    /// 可能性を示す — 同じ`persistedBool`呼び出しでも、一覧の`.task(id:)`が
    /// 起動直後の最初のフレームで読むタイミングと、ユーザーが数秒後に手で
    /// 設定画面を開いて読むタイミングとでは、後者の方が`cfprefsd`との
    /// 同期が済んでいる可能性が高い。
    ///
    /// `CFPreferencesAppSynchronize` はまさにこの「プロセスの起動直後、
    /// まだディスクの内容と同期し切れていないかもしれないキャッシュを
    /// 破棄し、今すぐディスクから読み直す」ためのAPI (通常はApp
    /// Group/ウィジェット拡張のようなマルチプロセス共有の文脈で紹介される
    /// が、このAPI自体はマルチプロセスに限定されない、この呼び出しプロセス
    /// 自身のpreferencesドメインの同期メカニズムそのもの)。プロセスの
    /// 生存期間中に一度だけ呼べば十分 (2回目以降のキャッシュはこのプロセス
    /// 自身の書き込みで正しく更新され続ける — 実際に食い違いうるのは
    /// 「起動してから最初に読むまでの間」だけ) なので、`persistedBool`の
    /// 最初の呼び出し1回だけに限定して無視できるコストに抑える。
    ///
    /// 実機での確定的な再現ができなかった (シミュレータでは`UserDefaults`
    /// の同期が速く、この種のレースを再現できない — `docs/qa-findings.md`
    /// のTask #105節参照) ため、この修正はTask #82/#101と同じ「理論的に
    /// 筋は通るが確証は無い防御的修正」という位置付け — `logger`によるOSLog
    /// 計装を併設し、次に実機で再現したときに`persistedBool`が実際どの値を
    /// 返したかを`log stream`で追えるようにしてある。
    // `nonisolated(unsafe)`: a plain one-shot guard flag, not actor-isolated
    // state. Worst case under a genuine data race (two nearly-simultaneous
    // first calls from different isolation domains) is calling
    // `CFPreferencesAppSynchronize` twice instead of once — harmless, and
    // far cheaper to accept than adding real synchronization for a flag
    // that only ever transitions `false` → `true` once per process.
    private nonisolated(unsafe) static var hasForcedReloadFromDisk = false

    /// Also called explicitly and eagerly from `AppEnvironment.init()`
    /// (before *anything* reads `UserDefaults`, the same "before any
    /// `@AppStorage` reader" ordering the `UserDefaults.registerOtegami
    /// *Defaults()` calls right above it already follow) — `persistedBool`
    /// calling this itself too is just a second, redundant safety net for
    /// any read that could somehow happen first.
    static func forceReloadFromDiskOnce() {
        guard !hasForcedReloadFromDisk else { return }
        hasForcedReloadFromDisk = true
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        Self.logger.notice("forced a CFPreferencesAppSynchronize reload before this process's first persistedBool read")
    }

    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "ListDisplaySettings")
}
