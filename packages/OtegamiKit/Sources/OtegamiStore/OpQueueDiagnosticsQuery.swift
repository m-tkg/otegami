import Foundation
import GRDB

/// Query helpers for `OpQueueReplayLogRecord`/`OpQueueStaleDiscardRecord`/
/// the live `opQueue` backlog — 実機報告「Gmail で既読化/アーカイブしても
/// サーバに反映されない」調査用の設定画面「操作同期の診断」
/// (`OpQueueDiagnosticsView`) が使う。`OpQueueQuery`と分けたのは、あちらが
/// 「今すぐユーザーが再試行/破棄できるop」というアクション対象のクエリ
/// なのに対し、こちらは「過去に何が起きたか/今どれだけ溜まっているか」
/// という読み取り専用の観測用クエリのため。
public enum OpQueueDiagnosticsQuery {
    public static func recentReplayLog(limit: Int, db: Database) throws -> [OpQueueReplayLogRecord] {
        try OpQueueReplayLogRecord
            .order(Column("invokedAt").desc, Column("id").desc)
            .limit(limit)
            .fetchAll(db)
    }

    public static func recentStaleDiscards(limit: Int, db: Database) throws -> [OpQueueStaleDiscardRecord] {
        try OpQueueStaleDiscardRecord
            .order(Column("discardedAt").desc, Column("id").desc)
            .limit(limit)
            .fetchAll(db)
    }

    public static func recentStaleDiscardsObservation(limit: Int) -> ValueObservation<ValueReducers.Fetch<[OpQueueStaleDiscardRecord]>> {
        ValueObservation.tracking { db in try recentStaleDiscards(limit: limit, db: db) }
    }

    /// アカウント別の未送信`opQueue`行数・最古 enqueue 時刻・attempts の
    /// 内訳 (未試行/再試行待ち/恒久失敗) をその場で集計する。診断画面が
    /// 「未送信が溜まり続けているのに replay ログが動いていない」ような
    /// 食い違いを1画面で確認できるようにするためのもの — replay ログ
    /// 自体は履歴 (過去に何が起きたか) を保持するだけなので、現在の
    /// スナップショットはこちらから毎回ライブに引く。
    public struct PendingSummary: Sendable, Equatable {
        public var accountId: String
        public var count: Int
        public var oldestCreatedAt: Date
        public var neverAttemptedCount: Int
        public var retryingCount: Int
        public var permanentlyFailedCount: Int

        public init(accountId: String, count: Int, oldestCreatedAt: Date, neverAttemptedCount: Int, retryingCount: Int, permanentlyFailedCount: Int) {
            self.accountId = accountId
            self.count = count
            self.oldestCreatedAt = oldestCreatedAt
            self.neverAttemptedCount = neverAttemptedCount
            self.retryingCount = retryingCount
            self.permanentlyFailedCount = permanentlyFailedCount
        }
    }

    public static func pendingSummaryByAccount(accountIds: [String], maxAttempts: Int, db: Database) throws -> [PendingSummary] {
        let ops = try OpQueueRecord
            .filter(accountIds.contains(Column("accountId")))
            .fetchAll(db)
        var byAccount: [String: [OpQueueRecord]] = [:]
        for op in ops {
            byAccount[op.accountId, default: []].append(op)
        }
        return byAccount.map { accountId, ops in
            PendingSummary(
                accountId: accountId,
                count: ops.count,
                oldestCreatedAt: ops.map(\.createdAt).min() ?? Date(),
                neverAttemptedCount: ops.filter { $0.attempts == 0 }.count,
                retryingCount: ops.filter { $0.attempts > 0 && $0.attempts < maxAttempts }.count,
                permanentlyFailedCount: ops.filter { $0.attempts >= maxAttempts }.count
            )
        }.sorted { $0.accountId < $1.accountId }
    }

    public static func pendingSummaryByAccountObservation(accountIds: [String], maxAttempts: Int) -> ValueObservation<ValueReducers.Fetch<[PendingSummary]>> {
        ValueObservation.tracking { db in try pendingSummaryByAccount(accountIds: accountIds, maxAttempts: maxAttempts, db: db) }
    }
}
