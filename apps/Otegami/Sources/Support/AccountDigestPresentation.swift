import OtegamiStore

/// Shared eligibility and role mapping for the account-digest list.
/// Grouping applies only to an unfiltered cross-account selection.
enum AccountDigestPresentation {
    static func isVisible(
        groupByAccount: Bool,
        accountFilter: String?,
        accountCount: Int,
        selection: SidebarSelection
    ) -> Bool {
        guard groupByAccount, accountFilter == nil, accountCount > 1 else { return false }
        return role(for: selection) != nil
    }

    static func role(for selection: SidebarSelection) -> MailboxRoleRecord? {
        switch selection {
        case .unifiedInbox:
            return .inbox
        case .unifiedRole(let role):
            return role
        case .mailbox:
            return nil
        }
    }

    /// ユーザー要望 (2026-08-08「グループでのアーカイブ処理は、受信箱でのみ
    /// 使える機能にして」): 一括操作をそのフォルダで提供してよいか。
    ///
    /// `.archive` は受信トレイ表示中のみ — アーカイブ済みの一覧
    /// (`.unifiedRole(.archive)`) や送信済み/ゴミ箱でアカウント全体を
    /// 「アーカイブ」しても意味が無く (アーカイブ一覧では全件が既に対象外で
    /// `bulkActionTargets` が空になるだけ、送信済み等では送信メールが
    /// まるごと消える方向に働く)、誤爆したときの被害だけが大きい。
    /// `.markRead`/`.delete`/`.junk` はどのフォルダでも意味を持つので制限
    /// しない。
    static func isBulkActionAvailable(_ action: AccountDigestBulkAction, role: MailboxRoleRecord) -> Bool {
        switch action {
        case .archive: return role == .inbox
        case .markRead, .delete, .junk: return true
        }
    }

    /// ユーザー要望 (2026-08-07「グループに対してのアーカイブは、アーカイブ
    /// されてないものだけを対象にしたい。すべてを既読、も同じく」):
    /// 一括操作が実際に触るスレッドを絞る。
    ///
    /// 既にアーカイブ済み/既読のスレッドまで対象にすると、サーバーへ送っても
    /// 何も変わらない op が `opQueue` に積まれるだけで、実機で未送信 op が
    /// 数千件まで膨らむ一因になっていた (設定→一般→「操作同期の診断」の
    /// 種類別内訳で確認できる)。`.delete`/`.junk` は「もう対象外」と言える
    /// ローカル状態が無いので絞らない — 表示されているスレッドはすべて対象。
    ///
    /// `AccountDigestView` の private メソッドではなくここに置いているのは
    /// `isVisible`/`role` と同じ理由 (テストから直接呼べるようにするため)。
    static func bulkActionTargets(for action: AccountDigestBulkAction, in summaries: [ThreadSummary]) -> [ThreadSummary] {
        switch action {
        case .archive:
            // `ThreadSummary.isArchived` (Task #151) は Gmail の All Mail も
            // アーカイブ扱いとして判定する — `MessageRemoval.commit`側の
            // `mailbox.role != .archive` ガードは Gmail に効かないので、
            // その分もここで落ちる。
            return summaries.filter { !$0.isArchived }
        case .markRead:
            return summaries.filter { $0.thread.unreadCount > 0 }
        case .delete, .junk:
            return summaries
        }
    }
}
