import Foundation
import GRDB

/// 実機報告「iCloud のメールをアーカイブしたのに受信箱に残る」の根本原因
/// への対応。Archive/Trash/Junk は `SyncScope.inboxOnly` (IDLE wake・
/// バックグラウンド定期同期のデフォルト) の対象外で、同期される機会は
/// 「そのメールボックスへ実際に操作した直後の targeted resync」くらいしか
/// ない。しかもそのメールボックスがまだ一度も差分同期を経ていない
/// (`uidValidity == 0`) 状態で targeted resync が走ると
/// `MailboxSyncer.incrementalSync` は「直近ウィンドウを取り直すだけ」の
/// full-resync 経路に入り、サーバーで消えたメッセージをローカルからも消す
/// vanished-UID 検知を一度も経由しない。その後そのメールボックスをユーザー
/// が開かない・そこへの操作もしない限り、ローカルに残ったゴースト行は
/// 永久に自己修復しない。
///
/// この型は、そういう「普段開かれないメールボックス」を低頻度 (既定 24
/// 時間ごと) で選び出す純粋な読み取りクエリ — 実際に同期を回すのは
/// 呼び出し側 (`AppEnvironment.syncAllAccountsOnce`) が
/// `SyncCoordinator.syncAccountIncrementally(scope: .mailboxes(paths:),
/// forceReconcileVanishedUIDs: true)` を呼ぶことで行う。一度でもこの経路
/// で通常の差分同期 (vanished-UID 検知を含む) を通れば、`lastSyncedAt` が
/// 更新されて次の 24 時間はこの選定から外れ、以後は同じ選定ロジックが
/// 定期的に自己修復の機会を作り続ける。
public enum StaleNonInboxMailboxQuery {
    /// 対象ロール — INBOX のように高頻度に同期される/`sent`・`drafts`の
    /// ように他クライアントからの消滅が実運用上ほぼ起きない役割は含めない。
    public static let targetRoles: Set<MailboxRoleRecord> = [.archive, .trash, .junk]

    /// この間隔以上 `lastSyncedAt` が更新されていない (または一度も同期
    /// されていない) メールボックスを対象とする。INBOX の高頻度同期とは
    /// 別枠の、低頻度な自己修復用なので1日に1回で十分 — サーバー側の
    /// `UID SEARCH`/`FETCH` 負荷をかけすぎないことを優先する。
    public static let staleThreshold: TimeInterval = 24 * 60 * 60

    /// `accountId` の Archive/Trash/Junk のうち、`staleThreshold` 以上
    /// 同期されていない (または未同期の) メールボックスの IMAP path 一覧。
    public static func stalePaths(accountId: String, now: Date = Date(), db: Database) throws -> [String] {
        try MailboxRecord
            .filter(Column("accountId") == accountId)
            .filter(targetRoles.map(\.rawValue).contains(Column("role")))
            .fetchAll(db)
            .filter { mailbox in
                guard let lastSyncedAt = mailbox.lastSyncedAt else { return true }
                return now.timeIntervalSince(lastSyncedAt) >= staleThreshold
            }
            .map(\.path)
    }
}
