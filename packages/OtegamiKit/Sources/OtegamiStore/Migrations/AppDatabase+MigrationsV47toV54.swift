import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v47〜v54 registrations (the current last batch
/// as of this split). See `AppDatabase+MigrationsV1toV10.swift`'s doc
/// comment for why this file exists and the ordering/identifier-stability
/// rules that apply to every migration file in this directory — they apply
/// here unchanged.
extension DatabaseMigrator {
    /// v47 (実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、
    /// 再読込でサーバ状態に巻き戻る」の調査可能化): `opQueueReplayLog` —
    /// `SyncEngine.OpQueueProcessor.replay`'s execution history
    /// (`OpQueueReplayLogRecord`'s doc comment for the full field-by-field
    /// rationale), backing the settings「操作同期の診断」画面
    /// (`OpQueueDiagnosticsView`). A bounded ring buffer the app trims
    /// itself (`OpQueueProcessor.beginReplayLog`), not via SQL here.
    ///
    /// Index on `invokedAt`: every read of this table orders/filters by it
    /// (`OpQueueDiagnosticsQuery.recentReplayLog`) — a small table in
    /// practice (the ring buffer caps at `OpQueueProcessor.replayLogCap`),
    /// but cheap to add now rather than as a follow-up migration once the
    /// diagnostics screen is slow.
    mutating func registerAppDatabaseMigrationsV47ToV54() {
        registerMigration("v47") { db in
            try db.create(table: "opQueueReplayLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                t.column("invokedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
                t.column("outcome", .text).notNull()
                t.column("succeeded", .integer).notNull().defaults(to: 0)
                t.column("discardedStale", .integer).notNull().defaults(to: 0)
                t.column("retrying", .integer).notNull().defaults(to: 0)
                t.column("permanentlyFailed", .integer).notNull().defaults(to: 0)
                t.column("affectedMailboxCount", .integer).notNull().defaults(to: 0)
                t.column("errorDescription", .text)
            }
            try db.create(index: "opQueueReplayLog_on_invokedAt", on: "opQueueReplayLog", columns: ["invokedAt"])
        }

        // v48 (同調査可能化、続き): `opQueueStaleDiscard` — a record of
        // every `opQueue` row `OpQueueProcessor.replay` discarded as
        // unsendable because the target mailbox's `uidValidity` had changed
        // since enqueue (`OpQueueStaleDiscardRecord`'s doc comment), written
        // just before the corresponding `opQueue` row is deleted, in the
        // same transaction, so the two are never observed out of sync.
        // Surfaced in the existing「同期エラー」画面 (`FailedOperationsView`)'s
        // new section. Same "index the column every read orders/filters by"
        // rationale as v47's `opQueueReplayLog_on_invokedAt` above.
        registerMigration("v48") { db in
            try db.create(table: "opQueueStaleDiscard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("discardedAt", .datetime).notNull()
                t.column("reason", .text).notNull()
            }
            try db.create(index: "opQueueStaleDiscard_on_discardedAt", on: "opQueueStaleDiscard", columns: ["discardedAt"])
        }

        // v49 (実機報告 2026-08-07「メールの unpin が反映されない」):
        // `thread.isPinned` を「dedup 前の全行の OR」から「dedup 後の代表行
        // だけを見る」定義へ変えた (`ThreadAssigner.aggregateUpdateSQL`/
        // `recomputeAggregates(threadId:db:)` — 判断理由はそちらのコメント)。
        // 定義を変えただけでは、既に古い定義で書き込まれた値は**そのスレッド
        // に次の変更が起きるまで残る** — 実機で「ピンが外れないスレッド」が
        // まさにその状態なので、そのままでは修正版を入れても直らない。
        //
        // v35 が `messageCount`/`unreadCount` を dedup 済みの定義へ変えた
        // ときと全く同じ理由・同じ手段 (`recomputeAllAggregates`が
        // `aggregateUpdateSQL`をそのまま流用するので、定義は1箇所のまま)。
        // このマイグレーション自体はスキーマを変えない — 既存行の値を新しい
        // 定義で計算し直すだけ。
        registerMigration("v49") { db in
            try ThreadAssigner.recomputeAllAggregates(db: db)
        }

        // v50 (実機報告「まだローカルにない未読メールが検出できない」):
        // 未読件数はローカルに取り込み済みの行の `COUNT(*)` なので
        // (`MessageQuery.unreadCounts`)、バックフィルが追いついていない
        // メールボックスでは構造的に実際より少なく出る (この文書の落とし穴
        // (l) — 大きいアカウントでは追いつくことが事実上ない)。
        // `UnseenSweeper` が `UID SEARCH UNSEEN` の結果と突き合わせて
        // 「サーバーは未読と言っているがローカルに行が無い」件数を
        // `unseenNotFetchedCount` に持ち、バッジはローカル集計にこれを足す。
        // `lastUnseenSweepAt` はその SEARCH の実行間隔を絞るためだけの列。
        //
        // どちらも既存行のバックフィル (`UPDATE` で初期値を計算し直す処理)
        // は不要 — 0 / NULL がそれぞれ「まだ調べていない」を正しく表し、
        // 最初のスイープが実測値で埋める。
        registerMigration("v50") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "unseenNotFetchedCount", .integer).notNull().defaults(to: 0)
                t.add(column: "lastUnseenSweepAt", .datetime)
            }
        }
    }
}
