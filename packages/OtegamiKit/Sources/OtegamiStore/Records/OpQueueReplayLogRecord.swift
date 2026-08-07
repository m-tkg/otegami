import Foundation
import GRDB

/// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、再読込で
/// サーバ状態に巻き戻る」の調査用: `SyncEngine.OpQueueProcessor.replay`が
/// 実際にいつ呼ばれ、何件処理しどう終わったかを、Mac 接続なしでこの端末
/// だけから確認できるようにするための永続記録 (設定の「操作同期の診断」
/// 画面が読む)。`OtegamiStore`側にレコード型を置くのは`OpQueueRecord`と
/// 同じ理由 — `SyncEngine → OtegamiStore`の依存方向を保ったまま、
/// `SyncEngine`(書き込み側)とアプリ側の診断画面(読み取り側)の両方から
/// 同じ型を参照できるようにするため。
///
/// `invokedAt`は`OpQueueProcessor.replay(account:auth:)`が呼ばれた瞬間
/// (Task #124 の二重実行防止コアレス判定より前) に書き込む — こうすると
/// 「replay がそもそも呼ばれていない」ケースと「呼ばれてはいるが毎回
/// コアレス/空振りしている」ケースをこの表だけで区別できる。`completedAt`
/// が`nil`のまま残っている行は、そのパスの途中でアプリが強制終了/
/// クラッシュしたことを示唆する (`outcome == .inProgress`のまま)。
///
/// 直近`OpQueueProcessor.replayLogCap`件のリングバッファ — 呼び出し元は
/// 数十箇所あり (`OtegamiApp`/`MessageListView`/`ThreadDetailView`/...)、
/// 高頻度に呼ばれうるため無制限には保持しない。
public struct OpQueueReplayLogRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "opQueueReplayLog"

    public var id: Int64?
    public var accountId: String
    public var invokedAt: Date
    public var completedAt: Date?
    /// `Outcome.rawValue` — 生のカラムだが読み書きは常に`Outcome`経由。
    public var outcome: String
    public var succeeded: Int
    public var discardedStale: Int
    public var retrying: Int
    public var permanentlyFailed: Int
    public var affectedMailboxCount: Int
    /// 接続レベルの失敗/DB一時停止で`replayPass`自体が例外を投げて中断
    /// した場合のみ non-nil。`SyncEngineError.userFacingMessage`優先、
    /// それ以外は`String(describing:)` — `OpQueueProcessor.recordFailure`
    /// が`OpQueueRecord.lastError`に書くのと同じ変換規則。
    public var errorDescription: String?

    public init(
        id: Int64? = nil,
        accountId: String,
        invokedAt: Date,
        completedAt: Date? = nil,
        outcome: Outcome,
        succeeded: Int = 0,
        discardedStale: Int = 0,
        retrying: Int = 0,
        permanentlyFailed: Int = 0,
        affectedMailboxCount: Int = 0,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.invokedAt = invokedAt
        self.completedAt = completedAt
        self.outcome = outcome.rawValue
        self.succeeded = succeeded
        self.discardedStale = discardedStale
        self.retrying = retrying
        self.permanentlyFailed = permanentlyFailed
        self.affectedMailboxCount = affectedMailboxCount
        self.errorDescription = errorDescription
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public enum Outcome: String, Sendable {
        /// 行を挿入した直後、まだ完了していない状態 — この状態のまま
        /// 残っている行は、アプリがこのパスの途中で終了したことを示す。
        case inProgress
        /// Task #124 の二重実行防止コアレスにより、このパスは実際には
        /// 何もしなかった (`OpQueueProcessor.replay`のtrailing pass
        /// coalescing)。
        case coalesced
        /// 少なくとも1パス走り、正常に完了した。`succeeded`等が全部0なら
        /// 「呼ばれたが送るものが無かった (キューが空)」ことを意味する —
        /// これも「呼ばれた」ことの証拠として区別する価値がある。
        case completed
        /// 接続レベルの失敗、またはDB一時停止でパス自体が例外を投げて
        /// 中断した。`errorDescription`に詳細。
        case aborted
    }

    /// `outcome`をtypedな`Outcome`として読む — 未知の生文字列 (将来の
    /// アプリバージョンが書いた値をこのバージョンが読む場合) は`nil`。
    public var parsedOutcome: Outcome? { Outcome(rawValue: outcome) }
}
