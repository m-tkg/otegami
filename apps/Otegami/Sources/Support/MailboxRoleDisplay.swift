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
    /// `.all`(「すべてのメール」)を含めていない — Task #52, 2: Gmail は
    /// `\Archive`special-useフォルダを持たず、その All Mail (role`.all`)は
    /// `FolderListSheet.matchesCategory(mailbox:account:role:)`により
    /// 「アーカイブ」カテゴリの一員として扱う (Spark の挙動に合わせた一本化)。
    /// この配列に`.all`を別途残すと、Gmail の All Mail が「アーカイブ」と
    /// 「すべてのメール」の2つのセクションに重複して現れてしまう — それを
    /// 避けるため、`.all`は独立したカテゴリとして持たないことにした
    /// (`docs/design-system.md`にこの判断を記録)。
    static let categoryOrder: [MailboxRoleRecord] = [.inbox, .flagged, .archive, .sent, .drafts, .junk, .trash]
}
