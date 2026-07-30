import OtegamiStore

/// カテゴリ優先グルーピング (受信トレイ/アーカイブ/送信済み等の role ごとに
/// 各アカウントの該当メールボックスをまとめる表示) の共有ロジック。
///
/// Task #181 (macOS サイドバーにも同じカテゴリ構造を追加) で、それまで
/// `FolderListSheet` (iOS ハンバーガーメニュー) の private メソッド群
/// (`mailboxEntries(for:)`/`matchesCategory(mailbox:account:role:)`/
/// `dedupedByAccount(_:)`/`unreadCountForAllMailCategory(entries:)`) に
/// 閉じていたロジックをここへ抽出した — `SidebarView` (macOS) も全く同じ
/// 「role → 各アカウントの該当メールボックス」変換・重複排除・Gmail の
/// アーカイブ特例・「すべてのメール」の未読集計を必要とするため、
/// `CLAUDE.md`の「カテゴリの定義や並び順を2箇所に複製しない」方針に沿って
/// 1箇所に集約した。呼び出し側 (`FolderListSheet`/`SidebarView`) はそれぞれ
/// 自分の `@State` (`mailboxesByAccountId`/`unreadByMailboxId`) を引数として
/// 渡すだけで、保持自体はしない。
struct MailboxCategoryEntry: Identifiable {
    let account: AccountRecord
    let mailbox: MailboxRecord
    let mailboxId: Int64

    var id: Int64 { mailboxId }
}

enum MailboxCategoryGrouping {
    /// 全アカウントを横断して`role`のメールボックスを集める — `account`ごとに
    /// 独立して保持されている`mailboxesByAccountId`から、カテゴリ優先の
    /// セクションが必要とする形 (どのアカウントの、どのメールボックスか) へ
    /// フラット化する。
    static func entries(
        for role: MailboxRoleRecord,
        accounts: [AccountRecord],
        mailboxesByAccountId: [String: [MailboxRecord]]
    ) -> [MailboxCategoryEntry] {
        accounts.flatMap { account -> [MailboxCategoryEntry] in
            let matches = (mailboxesByAccountId[account.id] ?? [])
                .filter { matchesCategory(mailbox: $0, account: account, role: role) }
            return dedupedByAccount(matches).compactMap { mailbox in
                mailbox.id.map { MailboxCategoryEntry(account: account, mailbox: mailbox, mailboxId: $0) }
            }
        }
    }

    /// Task #154 (実機報告「ゴミ箱カテゴリに Gmail が2行出る」防御層):
    /// 根治 (`AccountSyncer.upsertMailboxes`) は次回同期以降のDBを正すが、
    /// まだ同期していない既存インストールの残存データ (旧DB) に対しては
    /// この表示ロジック自体でも同一アカウント内の重複行を1つへ畳む。
    /// SPECIAL-USE/IMAP-guaranteed なメールボックス (`roleIsAuthoritative
    /// == true`) を name-guessed なものより優先し、同等の候補同士では
    /// 最小`id`を選ぶ (決定的な選択にするため)。
    static func dedupedByAccount(_ matches: [MailboxRecord]) -> [MailboxRecord] {
        guard let winner = matches.min(by: { lhs, rhs in
            if lhs.roleIsAuthoritative != rhs.roleIsAuthoritative {
                return lhs.roleIsAuthoritative && !rhs.roleIsAuthoritative
            }
            return (lhs.id ?? .max) < (rhs.id ?? .max)
        }) else { return [] }
        return [winner]
    }

    /// Task #52, 2: Gmail は`\Archive`special-useフォルダを持たないため、
    /// 「アーカイブ」カテゴリの実体を Gmail アカウントに限り All Mail
    /// (role`.all`)とする — 表示側 (どのメールボックスを「アーカイブ」行
    /// として出すか) のマッピング。対になる`OtegamiStore.MailboxRoleRecord
    /// .gmailArchiveQueryRole`/`GmailArchiveFilter`は、その行を実際に開いた
    /// 時のスレッド一覧側の定義 (Gmail 検索式と等価な集合) を担う — 役割が
    /// 違うので別々に実装している。
    static func matchesCategory(mailbox: MailboxRecord, account: AccountRecord, role: MailboxRoleRecord) -> Bool {
        if mailbox.role == role { return true }
        if role == .archive, mailbox.role == .all, account.kind == .gmail { return true }
        return false
    }

    /// 「すべてのメール」カテゴリ見出しの未読バッジ — 他カテゴリの`entries`
    /// ベース集計と違い、Gmail 以外のアカウントは`entries(for: .all, ...)`
    /// に現れない (per-account 展開行を持たない、`matchesCategory`のdoc
    /// comment参照) ので、その分をアカウントの全 mailbox 横断で別途足し込む。
    /// Gmail アカウントは`entries`(All Mail mailboxのみ) に含まれる値を
    /// そのまま使う (`mailboxesByAccountId`から二重に拾って二重計上しない
    /// ため)。
    static func unreadCountForAllMailCategory(
        entries: [MailboxCategoryEntry],
        accounts: [AccountRecord],
        mailboxesByAccountId: [String: [MailboxRecord]],
        unreadByMailboxId: [Int64: Int]
    ) -> Int {
        let gmailTotal = entries.reduce(0) { $0 + (unreadByMailboxId[$1.mailboxId] ?? 0) }
        let nonGmailTotal = accounts
            .filter { $0.kind != .gmail }
            .reduce(0) { total, account in
                let mailboxIds = (mailboxesByAccountId[account.id] ?? []).compactMap(\.id)
                return total + mailboxIds.reduce(0) { $0 + (unreadByMailboxId[$1] ?? 0) }
            }
        return gmailTotal + nonGmailTotal
    }
}
