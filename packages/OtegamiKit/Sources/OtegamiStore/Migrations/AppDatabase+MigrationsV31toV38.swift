import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v31〜v38 registrations (the current last
/// batch as of this split). See `AppDatabase+MigrationsV1toV10.swift`'s
/// doc comment for why this file exists and the ordering/identifier-
/// stability rules that apply to every migration file in this directory
/// — they apply here unchanged. New migrations beyond v38 should be
/// appended to the end of this file's function body (keeping this as the
/// "current tail" file), or started in a new
/// `AppDatabase+MigrationsVxxToVyy.swift` file registered after this one
/// in `AppDatabase.swift`'s `migrator`, whichever keeps files reasonably
/// sized.
extension DatabaseMigrator {
    /// v31 (Task #154, 実機報告「ゴミ箱カテゴリに Gmail が2行出る」):
    /// `MailboxRecord.roleIsAuthoritative`'s doc comment has the full
    /// picture — `false` for every existing mailbox until the next sync
    /// re-`upsertMailboxes`es it with a real value (same self-healing
    /// shape as `role` itself, which this migration doesn't touch).
    mutating func registerAppDatabaseMigrationsV31ToV38() {
        registerMigration("v31") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "roleIsAuthoritative", .boolean).notNull().defaults(to: false)
            }
        }

        // v32 (Task #156, #129のHTML送信配線): `OutboxMessageRecord.htmlBody`'s
        // doc comment has the full picture — `NULL` for every existing row
        // (nothing in-flight at migration time was composed with the rich
        // text editor's HTML rendering captured), non-`NULL` only for a row
        // `ComposerView.send()` writes from here on. No backfill needed:
        // an already-queued send with a `NULL` htmlBody just replays as the
        // plain `text/plain` message it always was (`OpQueueProcessor`'s
        // `.send` case passes `outbox.htmlBody` straight through to
        // `ComposeDraft.htmlBody`, which is optional).
        registerMigration("v32") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "htmlBody", .text)
            }
        }

        // v33 (Task #161, #129/#156のフォローアップ「下書きの
        // htmlBody未対応」を解消): `DraftMessageRecord.htmlBody`'s doc
        // comment has the full picture — same "NULL for every existing
        // row, no backfill needed" shape as v32's identical column on
        // `outboxMessage`.
        registerMigration("v33") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "htmlBody", .text)
            }
        }

        // v34 (Task #162, 実機フィードバック「署名が本文に混ざって編集しづらい」):
        // `DraftMessageRecord.signatureId`'s doc comment has the full
        // picture — `NULL` for every existing row (no backfill), non-`NULL`
        // only for a row `ComposerView.saveDraft()` writes from here on.
        registerMigration("v34") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "signatureId", .integer)
            }
        }

        // v35 (Task #168, 実機フィードバック「一覧のスレッド通数バッジが
        // 実際の通数と食い違う」（Gmail、Oktaの通知メール）): a54f585 made
        // `thread.messageCount`/`unreadCount` dedup-aware (Gmail の INBOX と
        // All Mail の二重行を1通として数える) for every future write to
        // those columns via `ThreadAssigner.recomputeAggregates(threadId:
        // db:)`/`.apply(_:accountId:db:)`, but never backfilled threads
        // whose stored value was already written with the old (dedup前の)
        // count before that fix shipped — a thread stays wrong until its
        // membership changes again and triggers a fresh write. This
        // migration recomputes every existing thread's aggregates once,
        // via `ThreadAssigner.recomputeAllAggregates(db:)` (a single `UPDATE
        // thread SET ...` statement reusing the exact same dedup SQL
        // `apply`'s per-batch path already uses — one definition, not three).
        // Raw SQL inside that helper, not `ThreadRecord`/`MessageRecord`
        // fetch-then-update — deliberately, for the same "frozen schema vs.
        // live Codable struct shape" reason v21's migration documents:
        // every column this UPDATE touches (`thread.messageCount`,
        // `message.gmailMessageId`, `mailbox.role`, etc.) already existed
        // well before v34, so referencing them by raw column name here is
        // safe regardless of columns added by migrations after this one.
        registerMigration("v35") { db in
            try ThreadAssigner.recomputeAllAggregates(db: db)
        }

        // v36 (実機フィードバック: HTML本文の quoted-printable ソフト改行
        // 消化漏れ — `MailCoreIMAPSession+Mapping.swift`の`html(from:)`修正
        // 後も、同じメールでまだ翻訳が失敗した): 修正は**新規フェッチにしか
        // 効かない** — 既存の`messageBody`行には修正前の壊れたhtmlがその
        // まま残っている (Task #134と全く同じ制約)。全件に`DEFAULT 0`で
        // `renderVersion`列を足すだけで済ませる — SQLite側が既存行全てへ
        // 自動適用するので、手動のfetch-then-updateバックフィルは不要
        // (`MessageBodyRecord.currentRenderVersion`のdoc comment参照)。
        // `0`は`MessageBodyRecord.currentRenderVersion`(1)より必ず古い値
        // になるので、既存行は次にそのメッセージを開いた瞬間 `MessageView
        // .load()`のキャッシュ利用ガードにより「本文キャッシュ未取得」と
        // 同等に扱われ、遅延的に (そのメッセージだけ) 再フェッチされる —
        // 起動時に全件を一括再取得することはしない (数千件規模になりうる
        // ため)。
        registerMigration("v36") { db in
            try db.alter(table: "messageBody") { t in
                t.add(column: "renderVersion", .integer).notNull().defaults(to: 0)
            }
        }

        // v37 (Task #186, iCloud で設定全般を同期): `signatureTemplate`/
        // `mailTemplate` gain a `syncId` — a `UUID` string generated once
        // per row, immutable for its lifetime — as the cross-device-stable
        // identity `TemplateCloudSyncEngine` (`AccountCloudSync`) reconciles
        // on. The existing `id` (`AUTOINCREMENT`, referenced by
        // `account.defaultSignatureId`/`Composer`'s in-memory selection/
        // `LastSignatureSettingsStore`'s per-account `UserDefaults` key)
        // stays exactly what the v24 migration's comment above already
        // explains it must stay — a device-local row number with no
        // cross-device meaning — so it is deliberately *not* part of the
        // synced payload; only `syncId` ever leaves this device. This
        // finally implements the "Syncing the signatures themselves is
        // future work this batch doesn't attempt" deferral that v24's
        // comment flagged.
        //
        // Two-step `ADD COLUMN` (nullable first, backfill, no `NOT NULL`
        // constraint added after) rather than a single `.notNull()` column
        // definition: SQLite's `ADD COLUMN ... NOT NULL` requires a single
        // *constant* default for every existing row, but each row needs its
        // *own* fresh UUID — the same reason `v18`'s `toText`/`ccText`
        // backfill above is a nullable column plus a Swift-side per-row
        // loop, not a one-shot SQL default. A `UNIQUE` index (not a `NOT
        // NULL` constraint) is what actually keeps this column populated
        // going forward: `SignatureTemplateRecord.init`/`MailTemplateRecord
        // .init` both default `syncId` to a fresh `UUID().uuidString`, so
        // every row inserted after this migration always has one; the
        // column stays nullable at the SQLite level purely so this
        // migration doesn't need a same-transaction "add NOT NULL" step
        // GRDB's `alter(table:)` doesn't expose directly.
        registerMigration("v37") { db in
            try db.alter(table: "signatureTemplate") { t in
                t.add(column: "syncId", .text)
            }
            try db.alter(table: "mailTemplate") { t in
                t.add(column: "syncId", .text)
            }
            // Raw SQL, not `SignatureTemplateRecord`/`MailTemplateRecord`'s
            // `Codable` fetch — those Swift structs declare `syncId` as a
            // non-optional `String` (matching every row *after* this
            // migration finishes), but right after the `ADD COLUMN` above
            // every existing row's `syncId` is still SQL `NULL`; decoding
            // through the Codable record at that intermediate point would
            // throw before this loop ever gets to backfill it.
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM signatureTemplate") {
                try db.execute(sql: "UPDATE signatureTemplate SET syncId = ? WHERE id = ?", arguments: [UUID().uuidString, id])
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM mailTemplate") {
                try db.execute(sql: "UPDATE mailTemplate SET syncId = ? WHERE id = ?", arguments: [UUID().uuidString, id])
            }
            // A `UNIQUE` index, not `NOT NULL` — see this migration's doc
            // comment above for why the column itself stays nullable at the
            // SQLite level. SQLite treats multiple `NULL`s in a `UNIQUE`
            // index as non-conflicting, so this is safe even though the
            // column has no `NOT NULL` constraint of its own.
            try db.create(index: "signatureTemplate_on_syncId", on: "signatureTemplate", columns: ["syncId"], unique: true)
            try db.create(index: "mailTemplate_on_syncId", on: "mailTemplate", columns: ["syncId"], unique: true)
        }

        // v38 (Task #193, 実機バグ「10年以上前に送った送信済みメールが、
        // 6時間前くらいの日付で受信箱に表示される」): a MailCore2 bug this
        // app used to inherit verbatim — `EnvelopeDateSentinel`'s doc
        // comment has the full root cause — could stamp `message.date`
        // with whatever moment a message was *fetched* rather than its real
        // `Date:` header, for any message whose header was missing or
        // malformed one. `MailCoreIMAPSession+Mapping.envelope(from:
        // fetchedAt:)`'s fix stops this for every future fetch, but does
        // nothing for a `date` already written that way, or for a thread a
        // so-corrupted row already merged into via `Threader`'s subject-
        // fallback pass (a years-old message that *looked* freshly sent
        // easily lands inside that pass's 7-day window against whatever
        // recent thread shares its subject and a participant). This
        // migration runs `ThreadAssigner.repairSentinelDates(db:)` once for
        // every existing install — see that function's doc comment for how
        // it identifies an already-corrupted row (there's no stored
        // "fetched at" moment to check against, only `updatedAt`) and how
        // it re-threads it.
        registerMigration("v38") { db in
            try ThreadAssigner.repairSentinelDates(db: db)
        }
    }
}
