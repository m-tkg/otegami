import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v21〜v30 registrations. See
/// `AppDatabase+MigrationsV1toV10.swift`'s doc comment for why this file
/// exists and the ordering/identifier-stability rules that apply to every
/// migration file in this directory — they apply here unchanged.
extension DatabaseMigrator {
    /// v21 (Gmail フォルダ名文字化け修正): `mailbox.displayPath` was meant
    /// to hold RFC 3501 modified-UTF-7-decoded text (`MailboxInfo
    /// .displayPath`'s doc comment always documented this), but the
    /// decode step was never implemented until `ModifiedUTF7`/this
    /// migration — every `displayPath` written before now is actually
    /// the raw encoded path (e.g. Gmail's "[Gmail]/&MFkweTBmMG4w4TD8MOs-"
    /// instead of "[Gmail]/すべてのメール"). Undetected during
    /// development because dev/mailstack's Dovecot fixtures only ever
    /// used plain-ASCII folder names — modified UTF-7 of pure ASCII text
    /// is the identity transform, so `ModifiedUTF7.decode` silently
    /// no-opped there and the bug only showed up against real Gmail
    /// accounts (`docs/verify.md`'s Gmail フォルダ名文字化け entry).
    mutating func registerAppDatabaseMigrationsV21ToV30() {
        // `path` (the raw IMAP identifier used in SELECT/FETCH) was never
        // wrong and needs no repair — only `displayPath` is recomputed
        // here, from `path`/`delimiter`, using the exact same logic
        // `MailCoreIMAPSession.mailboxInfo(from:)` now applies on every
        // future `listMailboxes()` pass (which would otherwise
        // self-heal this on the next successful sync anyway — see
        // `AccountSyncer.upsertMailboxes`'s unconditional `displayPath`
        // overwrite — but repairing it immediately means a user isn't
        // staring at mojibake folder names until their next sync
        // completes).
        // Raw `Row`/SQL, not `MailboxRecord.fetchAll(db)`/`.update(db)` —
        // deliberately: a migration runs against the schema *as it existed
        // at that version*, but a `FetchableRecord`/`MutablePersistableRecord`
        // conformance always decodes/writes using *today's* Swift struct
        // shape, columns added by any later migration included. `mailbox`
        // gained `isHidden` in v26 (after this one), and `MailboxRecord`
        // already declares that property in current code — decoding via
        // `MailboxRecord.fetchAll(db)` here would fail with "column not
        // found: isHidden" against a v21-stage table that hasn't run v26
        // yet, exactly the same "frozen schema vs. live struct" hazard
        // `v21RepairsDisplayPath` (`AppDatabaseTests.swift`) already
        // exercises for hand-inserted rows, now confirmed to bite a
        // *production* migration's own code too, not just a test's setup.
        registerMigration("v21") { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, path, delimiter, displayPath FROM mailbox")
            for row in rows {
                let id: Int64 = row["id"]
                let path: String = row["path"]
                let delimiter: String? = row["delimiter"]
                let currentDisplayPath: String = row["displayPath"]
                let decodedPath = ModifiedUTF7.decode(path)
                let displayPath: String
                if let delimiter, delimiter != "/" {
                    displayPath = decodedPath.replacingOccurrences(of: delimiter, with: "/")
                } else {
                    displayPath = decodedPath
                }
                guard displayPath != currentDisplayPath else { continue }
                try db.execute(sql: "UPDATE mailbox SET displayPath = ? WHERE id = ?", arguments: [displayPath, id])
            }
        }

        // v22 (D「アカウントのラベル色を変更可能に」): nullable — see
        // `AccountRecord.labelColorKey`'s doc comment. Every pre-existing
        // row gets NULL (SQLite's default for a nullable column added via
        // `ALTER TABLE ... ADD COLUMN` with no `.defaults(to:)`), which
        // `OtegamiAccountColor.color(for:override:)` already treats as
        // "keep using the deterministic auto-assignment" — no backfill
        // needed.
        registerMigration("v22") { db in
            try db.alter(table: "account") { t in
                t.add(column: "labelColorKey", .text)
            }
        }

        // v23 (F「署名テンプレート」): see `SignatureTemplateRecord`'s doc
        // comment for why this is a separate table from `mailTemplate`
        // rather than an extension of it. `accountIds` is `.blob` for the
        // same reason `outboxMessage.toAddresses` is (`v1`'s migration) —
        // GRDB's Codable-record support JSON-encodes a plain Swift array
        // property to a BLOB column automatically.
        registerMigration("v23") { db in
            try db.create(table: "signatureTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("body", .text).notNull()
                t.column("accountIds", .blob).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v24 (F「デフォルト署名（アカウントごと）」): nullable, `onDelete:
        // .setNull` so deleting a signature template automatically clears
        // it from every account that had it as their default — no manual
        // cleanup code needed at the deletion call site (`SyncEngine`'s
        // `.setNull` reliance mirrors `mailTemplate.accountId`'s existing
        // `onDelete: .cascade` pattern from v17, just with a different
        // action since an account's *default signature* going away should
        // leave the account itself intact, unlike a template that loses
        // its owning account). **This column itself is still deliberately
        // not synced via iCloud** (`AccountCloudSync.CloudAccountSnapshot`
        // has no `defaultSignatureId` field) — `signatureTemplate.id` stays
        // a device-local `AUTOINCREMENT` value with no cross-device meaning
        // even after v37 below (unlike `AccountRecord.id`, a UUID chosen
        // once and treated as the stable identity `docs/icloud-sync.md`
        // syncs by), so syncing this column as-is would still point at an
        // unrelated or nonexistent row on another device. **Update (Task
        // #186, v37 below)**: "Syncing the signatures themselves is future
        // work this batch doesn't attempt" — the deferral this comment used
        // to end on — is no longer true; `signatureTemplate`/`mailTemplate`
        // rows themselves (name/body/accountIds/subject) now sync via
        // `TemplateCloudSyncEngine`, keyed on the new `syncId` column v37
        // adds specifically because `id` can't serve that role. Only this
        // per-account *pointer* to a signature (as opposed to the signature
        // itself) remains unsynced.
        registerMigration("v24") { db in
            try db.alter(table: "account") { t in
                t.add(column: "defaultSignatureId", .integer)
                    .references("signatureTemplate", onDelete: .setNull)
            }
        }

        // v25 (アカウントの並び替え): `AccountRecord.sortOrder`'s doc comment
        // has the full picture. Added nullable-free with a `0` SQL default
        // (unlike, say, v22's `labelColorKey`, "0 for everyone" *is* the
        // right shared starting point here, not a per-row "unset" marker),
        // then immediately backfilled to a dense `0, 1, 2, ...` sequence in
        // `createdAt` order — "既存アカウントは現在の表示順 (createdAt 順) で
        // 初期化" — so this migration is a no-op for how any existing
        // install's account list actually looks the moment it runs.
        registerMigration("v25") { db in
            try db.alter(table: "account") { t in
                t.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            let accounts = try AccountRecord.order(Column("createdAt")).fetchAll(db)
            for (index, var account) in accounts.enumerated() {
                account.sortOrder = index
                try account.update(db, columns: [Column("sortOrder")])
            }
        }

        // v26 (メールボックス単位の非表示): `MailboxRecord.isHidden`'s doc
        // comment has the full picture. `false` for every existing
        // mailbox — nothing changes visibility/sync scope for an existing
        // install until the user explicitly hides one via the new
        // per-account "メールボックスの表示設定" screen.
        registerMigration("v26") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "isHidden", .boolean).notNull().defaults(to: false)
            }
        }

        // v27 (Task #52, Gmail アーカイブの定義): `GmailArchiveFilter`が
        // 「Gmail の All Mail のうち INBOX/Sent/Drafts と重複しないもの」を
        // 判定するたび `message.gmailMessageId` で自己結合するため、その
        // 列にインデックスを張る — `message_on_gmailThreadId` (v?, スレッド
        // 組み立て用) と同じ理由で、この列も既存の非インデックス列のままだと
        // フルスキャンになる規模 (All Mail は他のどのメールボックスより大きい)。
        registerMigration("v27") { db in
            try db.create(index: "message_on_gmailMessageId", on: "message", columns: ["gmailMessageId"])
        }

        // v28 (Task #66, カレンダー招待メール対応): `CalendarInviteResponseRecord`'s
        // doc comment has the full picture — one row per `message.id`
        // (`unique()`), replaced wholesale on every re-response rather than
        // accumulating history, so `MessageView`'s invite card can show
        // "すでに回答済み" the next time the same invite email is opened.
        // `onDelete: .cascade` mirrors `attachment.messageId`'s v1 shape:
        // this row is meaningless once its owning `message` row is gone
        // (deleted, or the account itself removed).
        registerMigration("v28") { db in
            try db.create(table: "calendarInviteResponse") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull().unique().indexed()
                    .references("message", onDelete: .cascade)
                t.column("partStat", .text).notNull()
                t.column("respondedAt", .datetime).notNull()
            }
        }

        // v29 (検索画面再構成 Task #86: 検索画面の「保存済み」タブ): クエリ
        // 文字列 + フィルタ (`SearchFilterOption.rawValue`) + アカウント絞り
        // (`nil` = 全部) の組み合わせを、検索フィールドの星タップで明示的に
        // 保存する (`SavedSearchQuery`/`SavedSearchRecord`)。`searchHistory`
        // (v20、実行したクエリを自動記録) とは別テーブル — こちらは
        // 「ユーザーが選んで残した」ものだけが入る。`queryText`に`UNIQUE`を
        // 付けないのは v20 との意図的な違い: 同じクエリ文字列でもフィルタ/
        // アカウントが異なれば別の保存として共存できる必要があるため
        // (`SavedSearchQuery.toggle`のドキュメントコメント参照)。
        registerMigration("v29") { db in
            try db.create(table: "savedSearch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("queryText", .text).notNull()
                t.column("filter", .text).notNull()
                t.column("accountId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "savedSearch_on_createdAt", on: "savedSearch", columns: ["createdAt"])
        }

        // v30 (Task #124, 二重送信防止): `OutboxMessageRecord.sendStartedAt`
        // — `OpQueueProcessor`'s `.send` replay claims this column
        // (`NULL` → now) in one serialized `dbWriter.write` transaction
        // immediately before actually handing the message to SMTP, and
        // only proceeds if it won that claim. That makes a still-`NULL`
        // row the ground truth for "never attempted", and a non-`NULL` row
        // mean "some attempt already owns this send" — a second concurrent
        // `replay()` (or a resumed one after a crash mid-send) sees the
        // claim already taken and refuses to resend rather than risking a
        // duplicate delivery. `NULL` for every existing row: nothing
        // in-flight has actually started until a replay pass claims it.
        registerMigration("v30") { db in
            try db.alter(table: "outboxMessage") { t in
                t.add(column: "sendStartedAt", .datetime)
            }
        }
    }
}
