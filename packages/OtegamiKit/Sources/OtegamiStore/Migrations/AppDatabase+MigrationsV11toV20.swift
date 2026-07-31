import Foundation
import GRDB
import OtegamiCore

/// `AppDatabase.migrator`'s v11〜v20 registrations. See
/// `AppDatabase+MigrationsV1toV10.swift`'s doc comment for why this file
/// exists and the ordering/identifier-stability rules that apply to every
/// migration file in this directory — they apply here unchanged.
extension DatabaseMigrator {
    /// v11 (iCloud account sync): `account.updatedAt` — see
    /// `AccountRecord.updatedAt`'s doc comment. Added nullable (SQLite
    /// `ALTER TABLE ADD COLUMN` can't express "default to another
    /// column's value") and immediately backfilled from `createdAt`,
    /// the same two-step pattern v7 used for `message.fromText`.
    mutating func registerAppDatabaseMigrationsV11ToV20() {
        registerMigration("v11") { db in
            try db.alter(table: "account") { t in
                t.add(column: "updatedAt", .datetime)
            }
            try db.execute(sql: "UPDATE account SET updatedAt = createdAt WHERE updatedAt IS NULL")
        }

        // v12: per-mailbox sync failure visibility (the "部分同期失敗の
        // UI 可視化" follow-up). `AccountSyncer`'s per-mailbox
        // `do`/`catch` used to swallow one mailbox's sync failure entirely
        // (`continue`, no record anywhere) so the rest of the account's
        // mailboxes weren't blocked — see `MailboxRecord.lastSyncError`'s
        // doc comment for the full rationale. Both columns nullable, same
        // "record it, clear it on success" shape `opQueue.lastError` already
        // uses.
        registerMigration("v12") { db in
            try db.alter(table: "mailbox") { t in
                t.add(column: "lastSyncError", .text)
                t.add(column: "lastSyncErrorAt", .datetime)
            }
        }

        // v13 (account edit UI): account-level sync failure visibility —
        // see `AccountRecord.lastSyncError`'s doc comment for why this is a
        // separate column from v12's mailbox-scoped one (a connect-level
        // failure, e.g. a wrong password after editing an account, happens
        // *before* any mailbox is even selected).
        registerMigration("v13") { db in
            try db.alter(table: "account") { t in
                t.add(column: "lastSyncError", .text)
                t.add(column: "lastSyncErrorAt", .datetime)
            }
        }

        // v14: Drafts IMAP sync + draft attachments. `draftMessage` gains a
        // "known server copy" reference (`serverMailboxId`/`serverUid`/
        // `serverUidValidity`) — set once a local draft has been `APPEND`ed
        // to the account's Drafts mailbox (`OpQueueKind.saveDraft`'s replay),
        // and carried forward as "the old copy to replace" when a
        // server-origin draft is edited and re-saved (`ComposerView`'s
        // `.serverDraft` load path). `serverMailboxId` references `mailbox`
        // with `onDelete: .setNull` (not `.cascade`) — losing the account's
        // Drafts mailbox record (e.g. re-synced with a new `MailboxRecord`
        // id after some server-side reshuffle) shouldn't take the draft's
        // text down with it, only its "this is where the server copy lives"
        // pointer.
        //
        // `draftAttachment` mirrors `outboxAttachment`'s shape exactly (same
        // "bytes already staged on disk before the row exists" contract —
        // see `OutboxAttachmentRecord`'s doc comment) for the `ComposerView
        // .saveDraft()` / `OpQueueProcessor`'s `.saveDraft` replay path.
        //
        // `outboxMessage` gains the same three-column "known server Drafts
        // copy" reference as `draftMessage`, populated when `ComposerView
        // .send()` is invoked from a Composer that was resumed from a draft
        // (local or server-origin) — `OpQueueProcessor`'s `.send` replay
        // reads these to best-effort delete the now-redundant Drafts copy
        // once the message has actually been sent (`docs/roadmap.md`'s
        // "送信完了時に...下書きが残るのは典型的なバグ").
        registerMigration("v14") { db in
            try db.alter(table: "draftMessage") { t in
                t.add(column: "serverMailboxId", .integer).references("mailbox", onDelete: .setNull)
                t.add(column: "serverUid", .integer)
                t.add(column: "serverUidValidity", .integer)
            }

            try db.create(table: "draftAttachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("draftMessageId", .integer).notNull()
                    .indexed()
                    .references("draftMessage", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("size", .integer).notNull().defaults(to: 0)
            }

            try db.alter(table: "outboxMessage") { t in
                t.add(column: "draftServerMailboxId", .integer).references("mailbox", onDelete: .setNull)
                t.add(column: "draftServerUid", .integer)
                t.add(column: "draftServerUidValidity", .integer)
            }
        }

        // v15 (on-device translation engine, docs/translation.md):
        // `message.detectedLanguage` is a BCP-47 code (e.g. `"en"`, `"ja"`)
        // written by `SyncEngine.BodyFetcher` right after a body fetch, via
        // `MessageLanguageDetector` (`NLLanguageRecognizer` — no LLM
        // involved, see that type's doc comment for why). Nullable: `nil`
        // until the body has been fetched at least once (like `snippet`),
        // and also `nil` when the recognizer isn't confident enough to
        // commit to a language for very short/ambiguous text.
        //
        // `messageTranslation` is `MessageTranslator`'s cache — one row per
        // *message*, not per (message, targetLanguage) pair, since this
        // app only ever translates a message in one direction (its
        // detected language, into whichever language the reply-drafting
        // flow needs, is never simultaneously cached both ways for the
        // same message). `paragraphs` is a JSON-encoded
        // `[TranslatedParagraph]` (GRDB's usual "`Codable` array property
        // stored as JSON in a `.blob` column" pattern — see
        // `MessageRecord.fromAddresses`), aligned 1:1 with
        // `ParagraphSplitter.split(_:)`'s output over the source text, so
        // 1i's "段落長押しでその段落だけ原文表示" can look up paragraph
        // *N*'s original text by index. `engineIdentifier` records which
        // `TranslationService` implementation produced this row (e.g.
        // `"foundation-models"`, `"fake"`) — `MessageTranslator` treats a
        // cached row from a different engine identifier as stale and
        // re-translates, so swapping engines (or, per the on-device
        // model's own versioning, a future "the model changed enough that
        // old translations should be invalidated" event tracked via this
        // same field) doesn't silently keep serving pre-change output.
        registerMigration("v15") { db in
            try db.alter(table: "message") { t in
                t.add(column: "detectedLanguage", .text)
            }

            try db.create(table: "messageTranslation") { t in
                t.column("messageId", .integer).notNull().primaryKey()
                    .references("message", onDelete: .cascade)
                t.column("sourceLanguage", .text).notNull()
                t.column("targetLanguage", .text).notNull()
                t.column("translatedText", .text).notNull()
                t.column("paragraphs", .blob).notNull()
                t.column("engineIdentifier", .text).notNull()
                t.column("translatedAt", .datetime).notNull()
            }
        }

        // v16 (ピン留め): `message.isPinnedLocal` is the single source of
        // truth this app orders by — always updated the moment a user pins/
        // unpins a message (`MessageListView`/`ThreadDetailView`'s pin
        // action). `AccountSyncer.upsert` additionally mirrors the server's
        // current `\Flagged` bit into this column on every resync (so
        // another client's flag change surfaces here too), and the
        // pin-toggle action itself also flips the IMAP flag via the
        // existing `setFlags` opQueue path.
        //
        // Task #212 (実機フィードバック「サーバのフラグと連動は設定から
        // 消して、内部的には連動 on として動いてほしい」): this used to be
        // opt-in via a `PinSettingsStore.syncWithFlaggedKey` toggle (default
        // off — "既定はローカル独自のフラグ"); that toggle and its
        // Settings-UI row were removed, and the sync above is now
        // unconditional.
        //
        // `thread.isPinned` is the OR-aggregate over its messages'
        // `isPinnedLocal` ("スレッド内の1通でもピン留めされたらそのスレッド自体が
        // 最上位に"), maintained by `ThreadAssigner.recomputeAggregates`
        // alongside `unreadCount`/`messageCount` — not a live join, so
        // `ThreadQuery`'s ordering can sort by it directly.
        registerMigration("v16") { db in
            try db.alter(table: "message") { t in
                t.add(column: "isPinnedLocal", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "thread") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "thread_on_isPinned_lastMessageDate", on: "thread", columns: ["isPinned", "lastMessageDate"])
        }

        // v17 (C8 テンプレート): reusable compose templates. Managed globally
        // (not per-account) with an *optional* per-template account scope —
        // `accountId == nil` means "available from every account's
        // Composer"; a non-nil value restricts it to that one account
        // (`t.column("accountId", .text)...references("account", onDelete:
        // .cascade)` — deleting an account quietly drops only *that*
        // account's own scoped templates, never a global one). This is the
        // "interpretation B" the plan called out as the more practical of
        // the two readings of "アカウントごとに設定できる" (per-template scope
        // vs. a per-account default template): a single flat list is far
        // simpler to build a settings CRUD screen and a Composer picker
        // around than two parallel concepts, while still satisfying the
        // literal requirement — most users will want the same signature-
        // style templates everywhere and occasionally one that only makes
        // sense from a specific (e.g. work) account.
        registerMigration("v17") { db in
            try db.create(table: "mailTemplate") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("subject", .text)
                t.column("body", .text).notNull()
                t.column("accountId", .text)
                    .indexed()
                    .references("account", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v18 (新画面構成: 検索演算子 `to:`/`cc:`): plain-text mirrors of
        // `toAddresses`/`ccAddresses`, exactly mirroring v7's `fromText`
        // addition (see `MessageRecord.toText`/`.ccText`'s doc comment for
        // why `SearchQuery`'s new operator matching can't query the JSON
        // `.blob` address columns directly). Backfilled the same way v7
        // backfilled `fromText`.
        registerMigration("v18") { db in
            try db.alter(table: "message") { t in
                t.add(column: "toText", .text)
                t.add(column: "ccText", .text)
            }
            let messages = try MessageRecord.fetchAll(db)
            for var message in messages {
                message.toText = FTSIndexer.composeFromText(message.toAddresses)
                message.ccText = FTSIndexer.composeFromText(message.ccAddresses)
                try message.update(db, columns: [Column("toText"), Column("ccText")])
            }
        }

        // v19 (新画面構成: メール本文画面「…」メニューの「スレッドをミュート」):
        // see `ThreadRecord.isMuted`'s doc comment for what this flag does
        // (and, importantly, does not — push suppression) and why.
        registerMigration("v19") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "isMuted", .boolean).notNull().defaults(to: false)
            }
        }

        // v20 (新画面構成: 検索履歴): the last N raw query strings a user
        // actually ran, most-recent-first, tappable to re-run
        // (`SearchHistoryQuery`/`SearchScreenView`). Deliberately its own
        // tiny table rather than reusing `mailTemplate`'s "flat list +
        // optional accountId scope" shape — search history has no per-
        // account scoping concept (a query searches across whichever scope
        // the search screen has selected at the time, independent of what
        // was selected when it was first typed) and needs `queryText` to be
        // unique so re-running an existing entry bumps its `updatedAt`
        // (moves it to the top) instead of accumulating duplicate rows.
        registerMigration("v20") { db in
            try db.create(table: "searchHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("queryText", .text).notNull().unique()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "searchHistory_on_updatedAt", on: "searchHistory", columns: ["updatedAt"])
        }
    }
}
