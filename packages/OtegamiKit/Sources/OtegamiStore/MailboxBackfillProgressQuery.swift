import Foundation
import GRDB

/// 「メール取得の進捗」— `mailbox.backfillLowerBound` (古いメールのバック
/// フィル同期カーソル、`MailboxRecord.backfillLowerBound`のdoc comment参照)
/// を人間が読める形に集計する、読み取り専用の診断クエリ。
///
/// 作った理由 (実機報告「『すべてのメール』の未読件数が iOS と macOS で
/// 違う。iOS だと 11 だが macOS では 99+」): 未読件数の計算式自体は両
/// プラットフォームで同一で、差はその端末がローカルに取り込み済みの
/// メール量だった (macOS は全メールボックスのバックフィルが完了済み、
/// iOS 実機は途中)。ところが当時のアプリには**バックフィルの進捗を確認
/// できる画面が1つも無く**、「操作同期の診断」(`OpQueueDiagnosticsView`)
/// が出す「完了」は`OpQueue`の再送処理の話なのに、メール取得も終わって
/// いる意味だと読めてしまった。この型はその取り違えを解消するために、
/// 同じ診断画面へ「メール取得はどこまで遡れているか」を出す。
///
/// `OpQueueDiagnosticsQuery`と同じ立場のクエリ (現状のスナップショットを
/// その場で集計するだけで、何も書き換えない)。バックフィル自体を駆動する
/// のは`SyncCoordinator.runBackfill`で、この型はそれが更新した列を読むだけ。
public enum MailboxBackfillProgressQuery {
    /// メールボックス1つ分の進捗。
    public struct MailboxProgress: Sendable, Equatable, Identifiable {
        public var mailboxId: Int64
        public var displayPath: String
        public var role: MailboxRoleRecord
        /// `MailboxRecord.backfillLowerBound` — この UID 未満はまだ取得して
        /// いない。`1`で完了。
        public var backfillLowerBound: Int64
        public var uidNext: Int64
        /// このメールボックスにローカル保存済みのメッセージ行数。
        public var syncedMessageCount: Int

        public var id: Int64 { mailboxId }

        public var isComplete: Bool { backfillLowerBound <= 1 }

        /// 走査済みの UID 範囲が全体に占める割合 (0...1) — 進捗バー用の
        /// **目安**。UID は歯抜け (削除・expunge) になりうるので実際の
        /// メール件数の比ではないし、`uidNext`はサーバーが次に発行する UID
        /// なので走査対象の全範囲は`1 ..< uidNext`。まだ一度も同期して
        /// いない (`uidNext <= 1`) メールボックスでは割合を出せないため
        /// `nil`を返す — 呼び出し側は「未同期」として扱う。
        public var scannedFraction: Double? {
            let total = uidNext - 1
            guard total > 0 else { return nil }
            let scanned = max(0, min(total, uidNext - backfillLowerBound))
            return Double(scanned) / Double(total)
        }

        public init(
            mailboxId: Int64,
            displayPath: String,
            role: MailboxRoleRecord,
            backfillLowerBound: Int64,
            uidNext: Int64,
            syncedMessageCount: Int
        ) {
            self.mailboxId = mailboxId
            self.displayPath = displayPath
            self.role = role
            self.backfillLowerBound = backfillLowerBound
            self.uidNext = uidNext
            self.syncedMessageCount = syncedMessageCount
        }
    }

    /// アカウント1つ分の集計。
    public struct AccountProgress: Sendable, Equatable, Identifiable {
        public var accountId: String
        /// 対象メールボックス数 (非表示を除く — 下記`progress`のdoc comment)。
        public var mailboxCount: Int
        /// そのアカウントにローカル保存済みのメッセージ行数 (対象メール
        /// ボックスの合計)。
        public var syncedMessageCount: Int
        /// まだ遡り切れていないメールボックス (`backfillLowerBound > 1`) —
        /// 残りの UID 数が多い順。
        public var pendingMailboxes: [MailboxProgress]

        public var id: String { accountId }

        public var isComplete: Bool { pendingMailboxes.isEmpty }

        public init(accountId: String, mailboxCount: Int, syncedMessageCount: Int, pendingMailboxes: [MailboxProgress]) {
            self.accountId = accountId
            self.mailboxCount = mailboxCount
            self.syncedMessageCount = syncedMessageCount
            self.pendingMailboxes = pendingMailboxes
        }
    }

    /// `accountIds`のバックフィル進捗をアカウント別に集計する。
    ///
    /// 非表示メールボックス (`isHidden`) を除くのは`SyncCoordinator
    /// .runBackfill`が同じ条件で対象を選んでいるため — バックフィルが最初
    /// から見ていないメールボックスを「未完了」として並べると、永久に減ら
    /// ない残件として読めてしまう。
    public static func progress(accountIds: [String], db: Database) throws -> [AccountProgress] {
        guard !accountIds.isEmpty else { return [] }
        let placeholders = accountIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT mailbox.id AS mailboxId, mailbox.accountId AS accountId,
                       mailbox.displayPath AS displayPath, mailbox.role AS role,
                       mailbox.backfillLowerBound AS backfillLowerBound, mailbox.uidNext AS uidNext,
                       (SELECT COUNT(*) FROM message WHERE message.mailboxId = mailbox.id) AS syncedMessageCount
                FROM mailbox
                WHERE mailbox.accountId IN (\(placeholders)) AND mailbox.isHidden = 0
                """,
            arguments: StatementArguments(accountIds)
        )

        var byAccount: [String: [MailboxProgress]] = [:]
        for row in rows {
            let accountId: String = row["accountId"]
            byAccount[accountId, default: []].append(
                MailboxProgress(
                    mailboxId: row["mailboxId"],
                    displayPath: row["displayPath"],
                    role: MailboxRoleRecord(rawValue: row["role"]) ?? .none,
                    backfillLowerBound: row["backfillLowerBound"],
                    uidNext: row["uidNext"],
                    syncedMessageCount: row["syncedMessageCount"]
                )
            )
        }

        return byAccount.map { accountId, mailboxes in
            AccountProgress(
                accountId: accountId,
                mailboxCount: mailboxes.count,
                syncedMessageCount: mailboxes.reduce(0) { $0 + $1.syncedMessageCount },
                pendingMailboxes: mailboxes
                    .filter { !$0.isComplete }
                    .sorted { $0.backfillLowerBound > $1.backfillLowerBound }
            )
        }
        .sorted { $0.accountId < $1.accountId }
    }

    public static func progressObservation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[AccountProgress]>> {
        ValueObservation.tracking { db in try progress(accountIds: accountIds, db: db) }
    }
}
