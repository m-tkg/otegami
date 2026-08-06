import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v39〜v46 registrations (the current last
/// batch as of this split). See `AppDatabase+MigrationsV1toV10.swift`'s
/// doc comment for why this file exists and the ordering/identifier-
/// stability rules that apply to every migration file in this directory
/// — they apply here unchanged.
extension DatabaseMigrator {
    /// v39 (古いメールのバックフィル同期): adds `mailbox.backfillLowerBound`
    /// — see `MailboxRecord.backfillLowerBound`'s doc comment for the full
    /// cursor semantics `BackfillSyncer` drives. `ADD COLUMN ... NOT NULL
    /// DEFAULT 1` first (a single constant default, `1`, meaning "nothing
    /// left to backfill" — safe for every existing row until the loop
    /// below corrects it), then a per-mailbox backfill loop derives the
    /// *real* starting cursor for every mailbox that already has synced
    /// mail: its current local minimum UID. That minimum is exactly the
    /// boundary `AccountSyncer.performInitialSync`/`MailboxSyncer
    /// .performWindowedResync`'s own "most recent N messages" window left
    /// unfetched below it — the same value those two call sites derive
    /// fresh (via `BackfillSyncer.resetCursor`) every time they run *after*
    /// this migration, but which needs a one-time derivation here for
    /// every mailbox that was already synced *before* this feature shipped
    /// (an ordinary incremental sync never re-derives it — see
    /// `BackfillSyncer`'s doc comment for why a persisted cursor is
    /// required at all rather than recomputing this on every backfill
    /// pass). A mailbox with no locally-synced mail (`MIN(uid)` is `NULL`)
    /// or whose local minimum is already `1` is left at the default —
    /// there is nothing older to fetch.
    ///
    /// Raw SQL throughout (not `MailboxRecord`'s `Codable` fetch/update):
    /// every column this touches (`mailbox.id`, `message.mailboxId`,
    /// `message.uid`) already existed well before v39, so referencing them
    /// by raw name here is safe regardless of columns added by migrations
    /// after this one — same reasoning as v35's identical raw-SQL choice.
    mutating func registerAppDatabaseMigrationsV39ToV46() {
        registerMigration("v39") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "backfillLowerBound", .integer).notNull().defaults(to: 1)
            }
            for mailboxId in try Int64.fetchAll(db, sql: "SELECT id FROM mailbox") {
                let minUID = try Int64.fetchOne(
                    db,
                    sql: "SELECT MIN(uid) FROM message WHERE mailboxId = ? AND uid > 0",
                    arguments: [mailboxId]
                )
                guard let minUID, minUID > 1 else { continue }
                try db.execute(sql: "UPDATE mailbox SET backfillLowerBound = ? WHERE id = ?", arguments: [minUID, mailboxId])
            }
        }
    }
}
