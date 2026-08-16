import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore

/// 検索の IMAP サーバーサイド SEARCH フォールバック: 検索は基本的に完全
/// ローカル DB (`OtegamiStore.SearchQuery`, `docs/architecture.md`) だが、
/// ローカルにまだ同期されていない古いメール・本文未ダウンロードのメールは
/// それでは見つからない。この actor はユーザーが `SearchScreenView` の
/// 「サーバーで検索」を明示的にタップしたとき (自動発動しない) だけ、
/// 1アカウント分の同期対象メールボックスを実際に IMAP `SEARCH` し、
/// ローカルに無かったヒットだけ最小限 (`ENVELOPE`) を取り込む。
///
/// `BackfillSyncer`と同じ役割分担: 接続の生成・`select`・切断のライフ
/// サイクルは呼び出し側 (`SyncCoordinator.serverSearch`) が持ち、この
/// actor は「既に`connect`済みのセッションを受け取り、対象メールボックスを
/// 列挙して`SEARCH`→未ローカルの`FETCH`まで行う」ことだけを担う —
/// `SyncCoordinator`側でアカウントごとの並行実行・全体タイムアウト・
/// アカウント単位の失敗許容を組み立てられるようにするための分離。
public actor ServerSearchService {
    /// メールボックス1つあたりの採用上限 (UID の大きい方から)。IMAP の
    /// `SEARCH`自体は件数無制限にUIDを返しうるため、無制限に`ENVELOPE`を
    /// 取り込むと1回のタップで数百〜数千件の`FETCH`が走りかねない —
    /// `docs/architecture.md`の pitfall (d)「`VANISHED`/`UID SEARCH`の
    /// 結果セットを実体化するときは上限件数を設ける」と同じ理由。UID の
    /// 大小を「新しい順」の近似として使う (`SEARCH`の戻り値自体には日付
    /// 情報が無い) のは`BackfillSyncer`が「UID range を古さの指標として
    /// 使う」のと同じ判断。
    public static let defaultMaxHitsPerMailbox = 100

    private let database: AppDatabase
    private let maxHitsPerMailbox: Int

    public init(database: AppDatabase, maxHitsPerMailbox: Int = ServerSearchService.defaultMaxHitsPerMailbox) {
        self.database = database
        self.maxHitsPerMailbox = maxHitsPerMailbox
    }

    /// `account`の同期対象メールボックス (`MailboxRecord.isHidden == false`)
    /// を対象に`query`を`SEARCH`し、ヒットの`ThreadSummary`を新しい順で
    /// 返す。`session`は呼び出し側が既に`connect`済み — この actor は
    /// `select`/`SEARCH`/`FETCH`だけを行い、接続の生成・切断には一切
    /// 関与しない (`BackfillSyncer.backfillOneBatch`と同じ分担)。
    ///
    /// 1メールボックスの`select`/`SEARCH`/`FETCH`のいずれかが失敗すると
    /// そのまま投げる (途中のメールボックスだけ黙ってスキップしない) —
    /// 個々のメールボックス失敗を握りつぶすと「実際には接続/認証が壊れて
    /// いるのに一部だけヒットが返ってきた」という誤解を招きかねないため、
    /// アカウント単位の失敗許容は呼び出し側 (`SyncCoordinator.serverSearch`)
    /// に一本化している。
    ///
    /// Gmail アカウントは All Mail (`role == .all`) だけを対象にする —
    /// Gmail は同じ物理メッセージを複数メールボックス (INBOX + All Mail
    /// 等) に二重登録するため、素朴に全メールボックスを検索すると同じ
    /// メールが複数ヒットとして現れてしまう。All Mail は Spam/Trash を
    /// 除く全メールを保持する (`docs/architecture.md`のGmailアーカイブ
    /// 定義参照) ので、「Spam/Trashはサーバー検索の対象外」という既知の
    /// 制限と引き換えに、重複解消ロジック (`ThreadQuery.deduplicate`、
    /// `OtegamiStore`の internal API) を持ち込まずに済んでいる。All Mail
    /// がまだローカルに一覧化されていない場合は素朴に全メールボックスへ
    /// フォールバックする。
    public func search(
        account: AccountRecord,
        query: String,
        session: any IMAPSessionProtocol
    ) async throws -> [ThreadSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let mailboxes = try await database.dbWriter.read { db in
            try MailboxQuery.request(accountId: account.id, includeHidden: false).fetchAll(db)
        }
        let targets = Self.searchTargets(mailboxes: mailboxes, isGmail: account.kind == .gmail)
        guard !targets.isEmpty else { return [] }

        var hitMessageIds = Set<Int64>()
        for mailbox in targets {
            try Task.checkCancellation()
            guard let mailboxId = mailbox.id else { continue }

            _ = try await session.select(mailbox.path)
            let uids = try await session.searchMessages(mailboxPath: mailbox.path, query: trimmed)
            guard !uids.isEmpty else { continue }
            let capped = Set(uids.sorted(by: >).prefix(maxHitsPerMailbox))
            let cappedUIDs = capped.map { Int64($0) }

            let localMessages = try await database.dbWriter.read { db in
                try MessageRecord
                    .filter(Column("mailboxId") == mailboxId)
                    .filter(cappedUIDs.contains(Column("uid")))
                    .fetchAll(db)
            }
            hitMessageIds.formUnion(localMessages.compactMap(\.id))

            let localUIDs = Set(localMessages.map(\.uid))
            let missingUIDs = capped.filter { !localUIDs.contains(Int64($0)) }
            guard !missingUIDs.isEmpty else { continue }

            let envelopes = try await session.fetchEnvelopes(mailboxPath: mailbox.path, uids: UIDSet(Array(missingUIDs)))
            guard !envelopes.isEmpty else { continue }
            try await database.dbWriter.write { db in
                // 未送信のローカル変更がある UID は取り込まない
                // (`PendingOpTargets`の doc comment) — アーカイブしたばかりで
                // まだサーバーへ送れていないメールが、サーバー検索の結果
                // として一覧に戻ってこないようにする。
                let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: account.id, db: db)
                for envelope in envelopes {
                    try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: account.id, pendingTargets: pendingTargets, db: db)
                }
            }
            let missingUIDsAsInt64 = missingUIDs.map { Int64($0) }
            let newMessages = try await database.dbWriter.read { db in
                try MessageRecord
                    .filter(Column("mailboxId") == mailboxId)
                    .filter(missingUIDsAsInt64.contains(Column("uid")))
                    .fetchAll(db)
            }
            hitMessageIds.formUnion(newMessages.compactMap(\.id))
        }

        guard !hitMessageIds.isEmpty else { return [] }
        let idsArray = Array(hitMessageIds)
        let messages = try await database.dbWriter.read { db in
            try MessageRecord.filter(idsArray.contains(Column("id"))).fetchAll(db)
        }
        return messages
            .sorted { lhs, rhs in
                let lhsDate = lhs.date ?? lhs.internalDate
                let rhsDate = rhs.date ?? rhs.internalDate
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.uid > rhs.uid
            }
            .map { ThreadSummary(flatMessage: $0, accountId: account.id) }
    }

    /// Which mailboxes `search(account:query:session:)` actually issues a
    /// `SEARCH` against — split out as a pure function so the Gmail
    /// All-Mail-only optimization (this type's own doc comment) is
    /// unit-testable without a `FakeIMAPSession`/`AppDatabase` at all.
    ///
    /// 実機報告「削除したメールが検索に出てくる」: Gmail は All Mail が
    /// Spam/Trash を含まないため既に対象外 (この型の doc comment 参照)。
    /// 非Gmailは素朴に全メールボックスを対象にしていたため、ゴミ箱・迷惑
    /// メールの中身までサーバー検索でヒット→ローカルに取り込まれてしまって
    /// いた — `SearchQuery`のローカル検索 (`scopeClause`) と同じ理由で
    /// role trash/junk のメールボックスを除外する (`isHidden`はこの時点で
    /// 既に`MailboxQuery.request(includeHidden: false)`が除外済み)。
    static func searchTargets(mailboxes: [MailboxRecord], isGmail: Bool) -> [MailboxRecord] {
        guard isGmail, let allMail = mailboxes.first(where: { $0.role == .all }) else {
            return mailboxes.filter { $0.role != .trash && $0.role != .junk }
        }
        return [allMail]
    }
}
