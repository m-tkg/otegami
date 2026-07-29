import OtegamiStore

/// 画面構造改修バッチ (Task #33, 3): カテゴリ優先グルーピング
/// (`FolderListSheet.categorySections`) のセクション見出し、その「横断ビュー」
/// 行、`MessageListView.title`(横断ビューを開いた時のナビゲーションタイトル)
/// が共有する role → 表示名/アイコンのマッピング。`SidebarView`/
/// `FolderListSheet.FolderMailboxRow`が既に持つ「role → アイコン」の switch
/// と一部重複するが、それらは1メールボックス行 (`MailboxRecord`) 単位、こちら
/// は role 単位 (`MailboxRoleRecord`) の見出し/横断ビュー専用 — 対象が違う
/// ので独立させている。
extension MailboxRoleRecord {
    /// カテゴリ優先メニューのセクション見出し、および横断ビューのタイトルに
    /// 使う日本語名。`.none`(ユーザーが作成した独自フォルダ)は role による
    /// カテゴリ分けの対象外 ── 「その他」セクションにまとめる
    /// (`FolderListSheet.categorySections`のdoc comment参照)。
    var categoryDisplayName: String {
        switch self {
        case .inbox: String(localized: "受信トレイ")
        case .flagged: String(localized: "フラグ付き")
        case .archive: String(localized: "アーカイブ")
        case .sent: String(localized: "送信済み")
        case .drafts: String(localized: "下書き")
        case .junk: String(localized: "迷惑メール")
        case .trash: String(localized: "ゴミ箱")
        case .all: String(localized: "すべてのメール")
        case .none: String(localized: "その他")
        }
    }

    /// `SidebarView.icon(for:)`/`FolderListSheet.FolderMailboxRow.icon(for:)`
    /// と同じ SF Symbols マッピング — 3箇所で重複しているが、対象 (mailbox行 x2
    /// vs role見出し x1) が違うのでいずれも独立させたまま (どれか1つを変えても
    /// 他2つが自動で追従する必要はない、というのがこのアプリの既存の判断)。
    var categorySystemImage: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "exclamationmark.octagon"
        case .archive: "archivebox"
        case .flagged: "flag"
        case .all: "envelope.badge.fill"
        case .none: "folder"
        }
    }

    /// ハンバーガーメニューのカテゴリセクションが並べる**既定**順序・対象
    /// role の固定リスト — `.none`(ユーザー独自フォルダ)は含まない (上記の
    /// 理由どおり、「その他」セクションで別途扱う)。受信トレイを先頭にする
    /// のは既存の統合受信トレイの並び (メニュー最上部)を踏襲するため。
    /// ユーザーが並び替え設定 (`FolderCategoryOrderStore`) で変更していない
    /// 限り、実際の描画順もこの配列そのもの。
    ///
    /// Task #141: `.all`(「すべてのメール」)を`.archive`の隣に追加した ——
    /// Task #52, 2 時点では「Gmail の All Mail が『アーカイブ』と『すべて
    /// のメール』の2箇所に重複して現れる」ことを避けるためあえて含めて
    /// いなかったが、今回はその重複を許容する判断に変更した (Gmail のみ
    /// 該当。定義・理由は`docs/design-system.md`の Task #141 節、クエリ側
    /// の実装は`ThreadQuery.unifiedInboxRequest`/`MessageQuery
    /// .unifiedInboxUnreadCount`の doc comment参照)。
    static let categoryOrder: [MailboxRoleRecord] = [.inbox, .flagged, .archive, .all, .sent, .drafts, .junk, .trash]
}
