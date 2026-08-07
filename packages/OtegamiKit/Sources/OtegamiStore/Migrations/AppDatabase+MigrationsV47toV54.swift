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
    }
}
