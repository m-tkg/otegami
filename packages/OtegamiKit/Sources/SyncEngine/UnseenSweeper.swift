import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import os

/// 実機報告「まだローカルにない未読メールが検出できない」— 未読件数が実際より
/// 少なく出る問題への対処。
///
/// otegami の未読件数はローカルに取り込み済みの行の `COUNT(*)` なので
/// (`MessageQuery.unreadCounts`)、そのメールボックスをまだ全部取り込めていない
/// 端末では構造的に少なく出る。`BackfillSyncer` が古い方へ遡ってはいるが、
/// 1 パス 2 バッチ・500 UID・5 分間隔なので、大きいアカウントでは事実上いつまでも
/// 追いつかない (`docs/architecture.md` の落とし穴 (l))。しかも**足りていること
/// 自体をアプリが知る手段が無かった**。
///
/// `UID SEARCH UNSEEN` (`IMAPSessionProtocol.searchUnseenUIDs`) はこの穴を 1 往復で
/// 塞ぐ — 返ってくる UID 集合が、
///
/// - **正しい未読件数**そのもの (`STATUS` では取れない — MailCore2 の
///   `folderInfoOperation` に `UNSEEN` は無い)、かつ
/// - **どの UID を取れば一覧が件数に追いつくか**の指示
///
/// の両方になる。この型は両方を使う: ローカルに行が無い UID を新しい順に上限つきで
/// 取り込み、取り切れなかった残りを `MailboxRecord.unseenNotFetchedCount` に残す
/// (バッジはローカル集計にこれを足す)。取り込みが進むほど残りは減り、追いついた
/// メールボックスでは 0 に収束する。
public struct UnseenSweeper: Sendable {
    /// 1 回のスイープで取り込む未読メールの上限。`SEARCH UNSEEN` の結果に上限は
    /// 無い (`IMAPSessionProtocol.searchUnseenUIDs` の doc comment — 上限は呼び出し側
    /// の責任) ので、未読が数千件あるアカウントで全部を一気に `FETCH` しないための
    /// 歯止め。取り切れなかった分は次のスイープが続きを取る (新しい順なので、
    /// ユーザーが最初に見る側から埋まる)。
    public static let maxFetchPerSweep = 500

    /// `SEARCH UNSEEN` を投げ直す最短間隔。サーバー側でメールボックス全体を
    /// 走査させる問い合わせなので、`incrementalSync` のたびに投げるには重すぎる。
    /// バックフィルの 5 分周期より長く取ってある — こちらは「件数を合わせる」ための
    /// 補正であって、新着そのものは通常の incremental sync が拾うため。
    public static let sweepInterval: TimeInterval = 15 * 60

    /// スイープ 1 回の結果。呼び出し側 (`MailboxSyncer`) はログにしか使わない。
    public struct SweepResult: Sendable, Equatable {
        /// サーバーが未読だと報告した総数 = `SEARCH UNSEEN` の結果件数。
        public var serverUnseenCount: Int
        /// うち、ローカルに行が無かった件数 (取り込み前)。未送信 op に
        /// 守られているぶんも含む生の数。
        public var missingCount: Int
        /// このスイープで実際に取り込んだ件数。
        public var fetchedCount: Int
        /// 取り込み後も残っている未取得の未読数 = 保存された
        /// `MailboxRecord.unseenNotFetchedCount`。
        public var remainingCount: Int
        /// うち、未送信 op に守られているため残数から除いた件数
        /// (`sweep` の doc comment 参照)。切り分け用にログへ出すだけで、
        /// 保存はしない。
        public var blockedByPendingOpsCount: Int
    }

    private let database: AppDatabase

    /// `BackfillSyncer` と同じ "Backfill" カテゴリ — どちらも「ローカルの取り込みが
    /// どこまで追いついたか」の話なので、Console.app で 1 本の流れとして読める方が
    /// 切り分けしやすい。
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "Backfill")

    public init(database: AppDatabase) {
        self.database = database
    }

    /// `lastUnseenSweepAt` から `sweepInterval` 経っていないメールボックスを弾く。
    /// `now` はテスト用の注入点 (既定は現在時刻)。
    public static func isDue(_ mailbox: MailboxRecord, now: Date = Date()) -> Bool {
        guard let last = mailbox.lastUnseenSweepAt else { return true }
        return now.timeIntervalSince(last) >= sweepInterval
    }

    /// `mailboxRecord` (呼び出し側が `select` 済み) を 1 回スイープする。
    /// `mailboxRecord.id` が無ければ `nil`。
    ///
    /// 取り込みは `BackfillSyncer.backfillOneBatch` と同じ作法 —
    /// `PendingOpTargets` を必ず渡す (未送信のローカル変更がある UID をサーバー
    /// 由来のエンベロープで上書きしない、`docs/architecture.md` の落とし穴 (m))。
    ///
    /// 残数の定義には同じガードが効く: **未送信 op に守られている UID は、
    /// サーバーが未読だと報告していても数えない。** 実機報告
    /// 「Gmail のメールを既読にしてアーカイブしたのにバッジが 1 のまま
    /// 消えない」の修正。既読化 (`setFlags`) とアーカイブ (`archive`) の op が
    /// まだ replay されていない間、サーバーの受信トレイにはそのメールが
    /// まだ未読で居るので `SEARCH UNSEEN` が返す。ローカル行は
    /// `MessageRemoval.commit` が消しており、`PendingOpTargets` が作り直しも
    /// ブロックする — つまり「行が無い」状態が op の replay まで続く。
    /// ここでその UID を残数に数えると `unseenNotFetchedCount` が 1 に
    /// 張り付き、**対応するメッセージ行がどこにも無いのでユーザーには
    /// 消しようがない**バッジが残る。op が恒久失敗すれば永久に残る。
    ///
    /// ガードの原則 (落とし穴 (m)) は「未送信のローカル変更がある UID に
    /// ついては、サーバー側の状態はまだ古いと分かっているので取り込まない」
    /// であり、件数の側だけサーバーを信じる理由は無い。
    @discardableResult
    public func sweep(
        mailboxRecord: MailboxRecord,
        mailboxPath: String,
        accountId: String,
        session: any IMAPSessionProtocol
    ) async throws -> SweepResult? {
        guard let mailboxId = mailboxRecord.id else { return nil }

        try Task.checkCancellation()

        let serverUnseenUIDs = try await session.searchUnseenUIDs(mailboxPath: mailboxPath)

        // ローカルに行が無い UID だけを残す。既にある行は (既読/未読どちらであれ)
        // ローカル集計の側が数えるので、ここで数えると二重になる。
        let missingUIDs = try await database.dbWriter.read { db in
            try Self.uidsMissingLocally(serverUnseenUIDs, mailboxId: mailboxId, db: db)
        }

        // 未送信 op に守られている UID は `EnvelopePersister.upsert` が
        // 必ず弾く (下の `pendingTargets` 渡し) ので、`FETCH` するだけ往復の
        // 無駄になる。取り込み対象から先に落としておく。
        let blockedBeforeFetch = try await database.dbWriter.read { db -> Set<UInt32> in
            let pendingTargets = try PendingOpTargets.forMailbox(
                mailboxId: mailboxId, accountId: accountId, db: db
            )
            guard !pendingTargets.isEmpty else { return [] }
            return missingUIDs.filter { pendingTargets.blocks(uid: Int64($0)) }
        }

        // 新しい順 — ユーザーが最初に目にする側から埋める。
        let toFetch = Array(
            missingUIDs.subtracting(blockedBeforeFetch).sorted(by: >).prefix(Self.maxFetchPerSweep)
        )

        var fetchedCount = 0
        if !toFetch.isEmpty {
            let envelopes = try await session.fetchEnvelopes(
                mailboxPath: mailboxPath, uids: UIDSet(toFetch)
            )
            fetchedCount = try await database.dbWriter.write { db -> Int in
                let pendingTargets = try PendingOpTargets.forMailbox(mailboxId: mailboxId, accountId: accountId, db: db)
                for envelope in envelopes {
                    try EnvelopePersister.upsert(
                        envelope: envelope, mailboxId: mailboxId, accountId: accountId,
                        pendingTargets: pendingTargets, db: db
                    )
                }
                return envelopes.count
            }
        }

        // 残りは「取り込み前に足りなかった数 − 実際に取り込めた数」ではなく、
        // 取り込み後にもう一度ローカルと突き合わせて数え直す — サーバーが
        // `SEARCH` の後で消した UID を実測のまま反映するため。
        //
        // ガードは書き込み時点で取り直す (`MailboxSyncer` のフラグ適用と同じ
        // 作法) — `FETCH` を待っている間に op が replay されて消えていれば、
        // その UID はもう守られておらず、残数に数えるのが正しい。
        let (remaining, blockedCount) = try await database.dbWriter.write { db -> (Int, Int) in
            let pendingTargets = try PendingOpTargets.forMailbox(
                mailboxId: mailboxId, accountId: accountId, db: db
            )
            let stillMissing = try Self.uidsMissingLocally(serverUnseenUIDs, mailboxId: mailboxId, db: db)
            let blocked = stillMissing.filter { pendingTargets.blocks(uid: Int64($0)) }
            let remaining = stillMissing.count - blocked.count
            guard var mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else {
                return (remaining, blocked.count)
            }
            mailbox.unseenNotFetchedCount = remaining
            mailbox.lastUnseenSweepAt = Date()
            try mailbox.update(db, columns: [Column("unseenNotFetchedCount"), Column("lastUnseenSweepAt")])
            return (remaining, blocked.count)
        }

        Self.logger.info(
            """
            unseen sweep: \(mailboxPath, privacy: .public) \
            serverUnseen=\(serverUnseenUIDs.count, privacy: .public) \
            missing=\(missingUIDs.count, privacy: .public) \
            fetched=\(fetchedCount, privacy: .public) \
            blocked=\(blockedCount, privacy: .public) \
            remaining=\(remaining, privacy: .public)
            """
        )

        return SweepResult(
            serverUnseenCount: serverUnseenUIDs.count,
            missingCount: missingUIDs.count,
            fetchedCount: fetchedCount,
            remainingCount: remaining,
            blockedByPendingOpsCount: blockedCount
        )
    }

    /// SQLite のホスト変数上限 (`SQLITE_MAX_VARIABLE_NUMBER`, 既定 999) を
    /// 越えないための `IN (...)` 分割サイズ。未読は数千件になりうるので、
    /// 一度に流し込むと `too many SQL variables` で落ちる。
    private static let uidLookupChunkSize = 500

    /// `uids` のうち、このメールボックスにローカル行が無いものだけを返す。
    /// `message` を全件読まずに済むよう「ローカルにあるもの」を引いて差集合を取る
    /// (`uidLookupChunkSize` ごとに分割)。
    private static func uidsMissingLocally(
        _ uids: Set<UInt32>, mailboxId: Int64, db: Database
    ) throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        var localUIDs: Set<Int64> = []
        for chunk in Array(uids).chunked(into: uidLookupChunkSize) {
            let found = try Int64.fetchSet(
                db,
                MessageRecord
                    .select(Column("uid"), as: Int64.self)
                    .filter(Column("mailboxId") == mailboxId)
                    .filter(chunk.map { Int64($0) }.contains(Column("uid")))
            )
            localUIDs.formUnion(found)
        }
        return uids.filter { !localUIDs.contains(Int64($0)) }
    }
}
