import Foundation
import GRDB

/// Mirrors `MailTransport.MailboxRole` without depending on `MailTransport`.
/// See `AccountAuthType` for the rationale.
public enum MailboxRoleRecord: String, Codable, Sendable {
    case inbox
    case all
    case archive
    case drafts
    case flagged
    case junk
    case sent
    case trash
    case none
}

extension MailboxRoleRecord {
    /// Gmail は `\Archive` special-use フォルダを持たないため、「アーカイブ」
    /// カテゴリの実体を Gmail アカウントに限り All Mail (`.all`) とする —
    /// Spark 等の挙動に合わせたマッピング (Task #52, 2)。`.archive`以外の
    /// role は恒等 (マッピング無し) — Gmail アカウントの受信トレイ/送信済み
    /// 等には一切影響しない。`ThreadQuery`/`MessageQuery`の unifiedInbox*
    /// 系がこれを使い、`account.kind == .gmail`かどうかで実際に見る
    /// `mailbox.role`をSQL側で出し分ける (`account.kind != .gmail`のアカウント
    /// は引き続き`self`のまま、つまり`.archive`を見る)。
    var gmailArchiveQueryRole: MailboxRoleRecord {
        self == .archive ? .all : self
    }
}

/// Task #52 追記: Gmail の「アーカイブ」の実体定義 — ユーザー指定の Gmail
/// 検索式 `-in:spam -in:trash -is:sent -in:drafts -in:inbox` と等価な集合。
/// 単純に All Mail (role `.all`) 全件を「アーカイブ済み」扱いにすると、まだ
/// 受信トレイにある未アーカイブメールや、自分の送信コピー・下書きの写しまで
/// 「アーカイブ済み」として出てしまう — Gmail の IMAP モデルでは同じメッ
/// セージが複数ラベル (= 複数 mailbox) に重複して現れるため。スパム/ゴミ箱は
/// そもそも All Mail に含まれない (Gmail 自身の挙動) ので、除外条件は
/// INBOX/Sent/Drafts の3つで足りる。
///
/// 「同一メッセージ」の判定は同一アカウント内の `X-GM-MSGID`
/// (`MessageRecord.gmailMessageId`) 突き合わせ — RFC 822 `Message-ID`
/// ヘッダ (`MessageRecord.messageId`) は欠落/複製されうる一方、
/// `X-GM-MSGID` は Gmail が発行するアカウント内一意な内部識別子で確実。
/// `docs/design-system.md`にこの定義 (ユーザー指定の検索式) を記録。
enum GmailArchiveFilter {
    /// `message`/`mailbox`/`account`がJOIN済みの行に対して足す WHERE断片。
    /// ガード (`mailbox.role = 'all' AND account.kind = 'gmail'`) が偽なら
    /// 常に真 (=除外しない) になるため、Gmail の All Mail 以外のどの
    /// メールボックスにも影響しない — 呼び出し側は`message`/`mailbox`/
    /// `account`という非エイリアスのテーブル名でJOINしていることが前提
    /// (`ThreadQuery`/`MessageQuery`の各SQLで共通)。
    static let excludeUnarchivedSQL = """
        NOT (
            mailbox.role = 'all' AND account.kind = 'gmail'
            AND message.gmailMessageId IS NOT NULL
            AND EXISTS (
                SELECT 1 FROM message AS gmailArchiveDup
                JOIN mailbox AS gmailArchiveDupMailbox ON gmailArchiveDupMailbox.id = gmailArchiveDup.mailboxId
                WHERE gmailArchiveDupMailbox.accountId = mailbox.accountId
                  AND gmailArchiveDupMailbox.role IN ('inbox', 'sent', 'drafts')
                  AND gmailArchiveDup.gmailMessageId = message.gmailMessageId
            )
        )
        """

    /// Task #151 (「アーカイブ済みの可視化」): a single message's own
    /// archived-or-not boolean, for `ThreadSummary.isArchived` — distinct
    /// from `excludeUnarchivedSQL` above (an AND-clause fragment meant to
    /// *filter out* Gmail All Mail duplicates from a query already scoped
    /// to an archive-representing mailbox) in that this evaluates the full
    /// "does this row's own mailbox membership count as archived" predicate
    /// on its own, regardless of what the enclosing query is scoped to.
    /// Non-Gmail: `mailbox.role = 'archive'` directly. Gmail: the message's
    /// mailbox is All Mail (`role = 'all'`) *and* it isn't also filed under
    /// INBOX/Sent/Drafts (same `X-GM-MSGID` dedup `excludeUnarchivedSQL`
    /// already does — reused verbatim rather than re-derived). Same
    /// unaliased `message`/`mailbox`/`account` JOIN precondition as
    /// `excludeUnarchivedSQL`.
    static let messageIsArchivedSQL = """
        (
            mailbox.role = 'archive'
            OR (mailbox.role = 'all' AND account.kind = 'gmail' AND \(excludeUnarchivedSQL))
        )
        """
}

/// A synced mailbox (IMAP folder). One row per `(accountId, path)`; upserted
/// idempotently by `SyncEngine` on every `listMailboxes()` pass.
public struct MailboxRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "mailbox"

    public var id: Int64?
    public var accountId: String

    /// The raw IMAP path (server hierarchy delimiter), e.g. `"INBOX"` or
    /// `"[Gmail]/Sent Mail"`. Used as the identifier in IMAP commands.
    public var path: String
    /// Human-presentable path (delimiter normalized to `"/"`). See
    /// `MailTransport.MailboxInfo.displayPath`.
    public var displayPath: String
    public var delimiter: String?
    public var role: MailboxRoleRecord
    /// Task #154 (migration v31): mirrors `MailTransport.MailboxInfo
    /// .roleIsAuthoritative` — `true` when `role` came from a SPECIAL-USE
    /// attribute or IMAP's guaranteed `"INBOX"` path, `false` when it came
    /// from `MailboxRole.inferred(fromDisplayPath:)`'s name-guess fallback
    /// (or `role == .none`). `AccountSyncer.upsertMailboxes` writes this
    /// fresh on every sync (no `.noOverwrite`, unlike `isHidden`) so it
    /// self-heals the same way `role` itself does. `FolderListSheet
    /// .mailboxEntries(for:)` uses it to prefer an authoritative mailbox
    /// when the #119 name-guess fallback still mis-fires a second match for
    /// the same role within one account (see that method's doc comment).
    public var roleIsAuthoritative: Bool
    /// `MailTransport.MailboxAttributes.rawValue`.
    public var attributesRaw: Int

    /// RFC 3501 §2.3.1.1. Stored as `Int64` (SQLite has no unsigned
    /// integer type); `UInt32` values always fit.
    public var uidValidity: Int64
    public var uidNext: Int64
    /// RFC 7162 `HIGHESTMODSEQ`; `0` when the server doesn't support
    /// `CONDSTORE`/`QRESYNC` (unused until M3).
    public var highestModSeq: Int64
    public var messageCount: Int
    public var lastSyncedAt: Date?
    /// Set by `AccountSyncer` when this mailbox's most recent sync attempt
    /// (initial or incremental) threw — a human-readable `String(describing:)`
    /// of the error, mirroring `OpQueueRecord.lastError`'s shape. Both `nil`
    /// together mean "last attempt succeeded" (or this mailbox has never
    /// been synced); `AccountSyncer` clears both back to `nil` the moment a
    /// later sync of this mailbox succeeds, so a lingering non-`nil` value
    /// always reflects the *current* state, not just history. Previously,
    /// per-mailbox sync failures were swallowed entirely (`AccountSyncer`'s
    /// per-mailbox `do`/`catch` just `continue`d) — see `docs/qa-findings.md`
    /// and `docs/verify.md` on why that made a real-device partial-sync bug
    /// hard to diagnose. Surfaced to the user via `MailboxSyncFailuresView`
    /// (sidebar banner), the same "record it, don't silently continue"
    /// pattern `opQueue.lastError`/`FailedOperationsView` already established
    /// for queued-operation failures.
    public var lastSyncError: String?
    public var lastSyncErrorAt: Date?

    /// メールボックス単位の非表示 (migration v26)。ON の間、このメールボックスは
    /// ハンバーガー/サイドバーのツリーに出ず (`MailboxQuery.request(accountId:
    /// includeHidden:)`)、統合受信トレイの集計からも外れる
    /// (`ThreadQuery.unifiedInboxRequest`/`unifiedInboxFlatSummaries`,
    /// `MessageQuery.unifiedInboxUnreadCount` の `mailbox.isHidden = 0`
    /// 条件)。**同期も止まる** (`AccountSyncer.performIncrementalSync`'s
    /// `.all` スコープが除外する — 電池・通信の節約が目的、判断理由は
    /// `docs/settings.md` 参照)。**移動先ピッカーからは除外しない** — 操作対象
    /// としては引き続き有効という判断も同じドキュメントに記録した。
    /// `AccountSyncer.upsertMailboxes` は `IMAP LIST` の結果を毎回この列も
    /// 含めて upsert するが、`Column("isHidden").noOverwrite` で既存の値を
    /// 保護しているため、通常の再一覧化でユーザーの選択が消えることはない。
    public var isHidden: Bool

    public init(
        id: Int64? = nil,
        accountId: String,
        path: String,
        displayPath: String,
        delimiter: String? = nil,
        role: MailboxRoleRecord,
        roleIsAuthoritative: Bool = false,
        attributesRaw: Int = 0,
        uidValidity: Int64 = 0,
        uidNext: Int64 = 0,
        highestModSeq: Int64 = 0,
        messageCount: Int = 0,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        lastSyncErrorAt: Date? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.accountId = accountId
        self.path = path
        self.displayPath = displayPath
        self.delimiter = delimiter
        self.role = role
        self.roleIsAuthoritative = roleIsAuthoritative
        self.attributesRaw = attributesRaw
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.messageCount = messageCount
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.lastSyncErrorAt = lastSyncErrorAt
        self.isHidden = isHidden
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
