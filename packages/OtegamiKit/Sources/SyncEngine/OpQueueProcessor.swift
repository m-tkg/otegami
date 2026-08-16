import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import os

/// Replays queued offline operations (`opQueue`) against the server, FIFO,
/// over one connection per `replay(account:auth:)` call. Owns no
/// persistent connection of its own — like `AccountSyncer`, it opens,
/// uses, and closes a fresh session per replay pass, since replay is
/// triggered opportunistically (successful reconnect, foreground,
/// incremental sync) rather than run continuously.
public actor OpQueueProcessor {
    /// After this many failed attempts, an op is left in the table (for a
    /// future UI banner to surface — `attempts >= maxAttempts` *is* "failed",
    /// no separate status column needed) but never retried again.
    public static let maxAttempts = 5

    /// Bound on `opQueueReplayLog`'s ring buffer (`OpQueueReplayLogRecord`'s
    /// doc comment) — `replay(account:auth:)` is called from a couple dozen
    /// independent trigger points across the app, so this keeps the table
    /// from growing unbounded even on a device that stays online and busy
    /// for a long time. 50 is generous for "diagnose what happened right
    /// after the user just reproduced the bug" without needing a separate
    /// retention/expiry job. `public` — `OpQueueDiagnosticsView` (app
    /// target) reads it too, both to cap its own query and to describe the
    /// retention policy in its footer text.
    public static let replayLogCap = 50

    /// Exponential backoff between retries of the same op: 30s, 60s, 120s,
    /// 240s, capped at 30 minutes so a long-offline device doesn't end up
    /// waiting hours between attempts once it's back online.
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 30 * 60

    /// Task (opqueue スタック修正、実機報告「Gmail の未送信 op が1055件・
    /// 最古 enqueue 約17時間・attempts が1件も増えない」)の原因: `replayPass`
    /// に一切タイムアウトが無く、`session.connect(auth:)`が返らなければ
    /// `replay(account:auth:)`が永久に抜けられず、`inFlightAccountIds`の
    /// 解放 (`defer`) も永久に来なかった。これがその接続タイムアウトの
    /// デフォルト値 — 正常なネットワークでの TCP+TLS ハンドシェイク+ログイン
    /// に十分な余裕を持たせつつ、ハングを検出してバッチを中断するまでの
    /// 待ち時間として妥当な値として30秒とした。`init`の同名パラメータで
    /// テスト用に短い値へ差し替えられる。
    public static let defaultConnectTimeout: TimeInterval = 30

    /// 1 op あたりの`apply(op:account:session:auth:)`呼び出しのデフォルト
    /// タイムアウト — 上と同じ理由・同じ値。STORE/MOVE/COPY/EXPUNGE、
    /// `.send`のSMTP送信のいずれも正常な接続では数秒〜十数秒で完了するため、
    /// 30秒は十分な余裕がある。
    public static let defaultOpApplyTimeout: TimeInterval = 30

    /// `inFlightAccountIds`のエントリがこの時間以上前から居座っているなら、
    /// 前回の`replay`パスは実質死んでいる (ハング/OSによるサスペンド中の
    /// ソケット破棄などで`defer`の解放が来なかった) とみなし、新しいパスが
    /// 所有権を奪って実行する — `inFlightAccountIdsDoc`にある通り、これが
    /// 無いと該当アカウントの replay は以後永久に`.coalesced`し続け、
    /// 復旧手段が無い (実機で確認された症状そのもの)。
    ///
    /// 5分という値の根拠: 上記2つのタイムアウト (各30秒) のおかげで、
    /// 1回の接続ハングまたは1回の op ハングだけで正常にパスは中断される
    /// ため、通常の (スタックしていない) パスが5分もかけて`inFlightAccountIds`
    /// に居座ることは無い。かつ`.send` op 自体の実行時間 (SMTP送信は通常
    /// 数秒〜数十秒) より十分長く取ってあるので、正常に進行中の
    /// `.send`パスを誤ってスタック扱いして奪い取り、Task #124 の二重送信
    /// 防止をすり抜けて同じメッセージを2回SMTPへ渡してしまう、という
    /// 事態を避けられる。
    public static let defaultStaleInFlightThreshold: TimeInterval = 5 * 60

    /// `replayPass`が1回のパスで処理する due な op 件数の上限。実機の
    /// 1055件のような大きな滞留を「1回のパスで全部処理しきる」設計だと、
    /// フォアグラウンド滞在時間やiOSのバックグラウンド実行猶予 (約30秒)
    /// の中で終わらず、中断されると成功分以外は何も残らない。上限に達し
    /// たら`replayPass`は一旦パスを終えて返し、`replay(account:auth:)`
    /// 側のループがdueが残っている限り次のパスを回す (既存の trailing
    /// pass ループを流用) — 中断されてもそれまでの成功分は確定し、次回の
    /// replay 起動が残りから続きを進められる。100は「1回のフォアグラウンド
    /// 操作で普通に溜まる量を大きく超えつつ、1055件のような滞留でも
    /// 十数パスで解消する」バランスで選んだ値。
    public static let defaultReplayBatchLimit = 100

    public struct ReplayResult: Sendable, Equatable {
        public var succeeded = 0
        /// Discarded because the op's `uidValidity` (or referenced
        /// mailbox) no longer matches current state — see
        /// `SetFlagsOpPayload`'s doc comment.
        public var discardedStale = 0
        /// Failed this pass but still under `maxAttempts`; will be retried
        /// after its backoff window.
        public var retrying = 0
        /// Just crossed `maxAttempts` on this pass; won't be retried again
        /// automatically.
        public var permanentlyFailed = 0
        /// Task #152: destination mailbox ids that need a prioritized
        /// post-operation resync. Source mailboxes are deliberately absent:
        /// the UI has already applied the requested flag/removal locally,
        /// and an immediate source refresh can observe an eventually-
        /// consistent IMAP server's old state and visibly undo that update
        /// until the next manual refresh. A pure `.setFlags` operation
        /// therefore leaves this empty; moves and relocations include only
        /// their destination. A Gmail archive moves nothing (it just unlabels
        /// the source) but still reports All Mail — the message's only
        /// remaining location, and the one holding any placeholder row
        /// `MessageRemoval` parked there. `SyncCoordinator.replayOpQueue`
        /// feeds this into `scheduleTargetedResync`.
        /// Deliberately not populated for `.send`/`.saveDraft`/
        /// `.deleteDraft` — those aren't the "他の受信箱一覧への反映が遅い"
        /// complaint this task addresses, and `.send`'s own Task #124
        /// idempotency guard is unrelated to mailbox-list reflection.
        public var affectedMailboxIds: Set<Int64> = []
    }

    /// Task #124 shared logging category — `PendingSendCoordinator` and
    /// `ComposerView` use the same category so the whole enqueue → schedule
    /// → finalize → replay → SMTP → Sent-append lifecycle for one send can
    /// be read as a single interleaved stream in Console.app.
    static let logger = Logger(subsystem: "com.mtkg.otegami", category: "PendingSend")

    /// Task #152: same "OpReflect" category `OpQueue.opReflectLogger`
    /// (enqueue) and `SyncCoordinator` (targeted resync) use — see
    /// `OpQueue.opReflectLogger`'s doc comment for the full lifecycle this
    /// stitches together in Console.app/`log collect`.
    private static let opReflectLogger = Logger(subsystem: "com.mtkg.otegami", category: "OpReflect")

    /// Not `private`: `OpQueueProcessor+Send.swift`/`OpQueueProcessor
    /// +SaveDraft.swift` (extensions in other files) need direct access —
    /// Swift's `private` is file-scoped even for extensions of the same
    /// type, so a same-module/internal-by-default level is required for
    /// anything those extracted `.send`/`.saveDraft` case handlers touch.
    /// Still not `public`: nothing outside `SyncEngine` needs it.
    let database: AppDatabase
    private let sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    /// M5: opens the SMTP connection a `.send` op replays over. Separate
    /// from `sessionFactory` (IMAP) since a `.send` op needs both — the
    /// shared IMAP `session` this actor already holds open for the whole
    /// batch (for the best-effort Sent-mailbox `APPEND`) plus its own
    /// independent SMTP connection. Not `private` — see `database`'s doc
    /// comment above for why.
    let smtpSessionFactory: @Sendable (SMTPConfig) -> any SMTPSessionProtocol
    /// M5: renders a `ComposeDraft` (an `outboxMessage` row's fields) to
    /// RFC 822 bytes. Injected rather than hardcoded to
    /// `MailTransportMailCore.MailCoreMessageBuilder` for the same reason
    /// `sessionFactory`/`smtpSessionFactory` are injected: `SyncEngine`
    /// stays independent of any specific MIME-building backend (the app
    /// wires the real one; tests inject a trivial pure-Swift stand-in).
    /// Not `private` — see `database`'s doc comment above for why.
    let messageBuilder: @Sendable (ComposeDraft) -> BuiltMessage

    /// Per-instance overrides of the `default*` timeout/threshold/batch
    /// constants above — always the `default*` value in production; tests
    /// inject small values (e.g. a few milliseconds) so the timeout/stale-
    /// takeover/batching tests don't need to actually wait 30s/5min/etc.
    private let connectTimeout: TimeInterval
    private let opApplyTimeout: TimeInterval
    private let staleInFlightThreshold: TimeInterval
    private let replayBatchLimit: Int

    /// Task #124 (二重送信防止): `replay(account:auth:)` is called
    /// opportunistically from a dozen+ independent triggers — swipe
    /// actions, foreground sync, the IDLE loop's post-push callback,
    /// `PendingSendCoordinator`'s countdown finalize — any of which can
    /// overlap for the *same* account. Because this type is an `actor`,
    /// two overlapping calls can still interleave at any `await` inside
    /// `replay(account:auth:)` (actor reentrancy): without this guard,
    /// both could fetch the same still-pending `.send` op before either
    /// had deleted it, and both hand it to SMTP — the actual mechanism
    /// behind the reported "同じメールが2通送信された" bug. Mutating this set
    /// only ever happens at non-suspending points (right at
    /// `replay(account:auth:)`'s entry/exit), so no further race is
    /// possible on the set itself; it makes `replay(account:auth:)` this
    /// actor's single execution owner per account. A second call for an
    /// account already in flight requests one coalesced trailing pass via
    /// `trailingReplayAccountIds`: the active pass may already have fetched
    /// its queue snapshot, so treating the overlap as a no-op can otherwise
    /// strand an operation enqueued after that snapshot until the next IDLE
    /// wake, foreground transition, or manual refresh.
    ///
    /// Task (opqueue スタック修正): `Set<String>`から「accountId → 開始
    /// 時刻」の辞書に変更した。Task #124 の二重送信防止という元の目的は
    /// そのまま維持しつつ (開始直後・age ≈ 0 の通常の重複呼び出しは今まで
    /// どおり coalesce される)、hang/サスペンドで`defer`による解放が永久に
    /// 来なかった場合の復旧手段 (`defaultStaleInFlightThreshold`超過での
    /// 奪い取り、`replay(account:auth:)`本体参照) に開始時刻が必要になった
    /// ため。
    private var inFlightAccountIds: [String: Date] = [:]

    /// Accounts whose in-flight replay received at least one overlapping
    /// replay request. A set deliberately coalesces any number of triggers
    /// into one additional pass; if another trigger arrives during that
    /// trailing pass, the loop runs once more. This never retries failed or
    /// backed-off operations on its own — each pass still applies the usual
    /// `nextRetryAt` filtering.
    private var trailingReplayAccountIds: Set<String> = []

    public init(
        database: AppDatabase,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol,
        smtpSessionFactory: @escaping @Sendable (SMTPConfig) -> any SMTPSessionProtocol = { config in NotImplementedSMTPSession(config: config) },
        messageBuilder: @escaping @Sendable (ComposeDraft) -> BuiltMessage = { _ in
            BuiltMessage(data: Data(), messageId: "<unbuilt@otegami.local>")
        },
        connectTimeout: TimeInterval = OpQueueProcessor.defaultConnectTimeout,
        opApplyTimeout: TimeInterval = OpQueueProcessor.defaultOpApplyTimeout,
        staleInFlightThreshold: TimeInterval = OpQueueProcessor.defaultStaleInFlightThreshold,
        replayBatchLimit: Int = OpQueueProcessor.defaultReplayBatchLimit
    ) {
        self.database = database
        self.sessionFactory = sessionFactory
        self.smtpSessionFactory = smtpSessionFactory
        self.messageBuilder = messageBuilder
        self.connectTimeout = connectTimeout
        self.opApplyTimeout = opApplyTimeout
        self.staleInFlightThreshold = staleInFlightThreshold
        self.replayBatchLimit = replayBatchLimit
    }

    /// Replays every due (`attempts < maxAttempts`, backoff window elapsed)
    /// op for `account`, oldest first. Returns early (without opening a
    /// connection at all) if there's nothing due. A connection-level
    /// failure (dead socket, bad credentials) aborts the remaining batch
    /// and rethrows — those ops' `attempts` are *not* incremented, since
    /// the connection is at fault, not any specific op; a per-op rejection
    /// (stale `uidValidity`, a `NO`/`BAD` IMAP response) doesn't stop the
    /// batch, so one bad op can't jam every op enqueued after it.
    @discardableResult
    public func replay(account: AccountRecord, auth: MailAuth) async throws -> ReplayResult {
        // Task (opqueue スタック修正): a one-time-per-process cleanup of any
        // `.inProgress` replay-log rows left over from a previous process
        // that never reached `finishReplayLog` (crash/force-quit) — see
        // `cleanupStaleInProgressReplayLogsIfNeeded`'s doc comment. Must run
        // *before* `beginReplayLog` inserts this call's own `.inProgress`
        // row below, or it would immediately mark that brand-new row too.
        await cleanupStaleInProgressReplayLogsIfNeeded()

        // Task (opQueue observability, 実機報告「Gmail で既読化/アーカイブ
        // してもサーバに反映されず、再読込でサーバ状態に巻き戻る」の調査
        // 可能化): recorded *before* the coalescing guard below, on every
        // single call — this is what lets the「操作同期の診断」画面
        // distinguish "replay is never being invoked at all" from "it's
        // invoked but keeps coalescing/finding an empty queue". See
        // `OpQueueReplayLogRecord`'s doc comment for the full field
        // rationale.
        let invokedAt = Date()
        let logId = await beginReplayLog(accountId: account.id, invokedAt: invokedAt)

        // Task (opqueue スタック修正): stale in-flight takeover. See
        // `defaultStaleInFlightThreshold`'s doc comment for the full
        // rationale/threshold justification and `inFlightAccountIds`'s doc
        // comment for why this is a dictionary now.
        var tookOverStaleInFlight = false
        if let startedAt = inFlightAccountIds[account.id] {
            let age = invokedAt.timeIntervalSince(startedAt)
            if age < staleInFlightThreshold {
                trailingReplayAccountIds.insert(account.id)
                Self.logger.notice("replay(accountId: \(account.id, privacy: .private)) coalesced — trailing pass requested")
                await finishReplayLog(id: logId, outcome: .coalesced, result: ReplayResult(), error: nil)
                return ReplayResult()
            }
            tookOverStaleInFlight = true
            Self.logger.error("replay(accountId: \(account.id, privacy: .private)) taking over stale in-flight replay (age \(Int(age))s ≥ threshold \(Int(self.staleInFlightThreshold))s) — previous pass presumed dead (hang or OS suspend)")
        }
        inFlightAccountIds[account.id] = invokedAt
        trailingReplayAccountIds.remove(account.id)
        defer {
            inFlightAccountIds.removeValue(forKey: account.id)
            trailingReplayAccountIds.remove(account.id)
        }

        var combined = ReplayResult()
        do {
            // Task (opqueue スタック修正): loops until both "no trailing
            // pass was requested" *and* "the last pass didn't hit its own
            // `replayBatchLimit`" — see `defaultReplayBatchLimit`'s doc
            // comment for why a large backlog needs more than one pass here.
            var hasMoreDue = true
            while hasMoreDue {
                let pass = try await replayPass(account: account, auth: auth)
                combined.succeeded += pass.result.succeeded
                combined.discardedStale += pass.result.discardedStale
                combined.retrying += pass.result.retrying
                combined.permanentlyFailed += pass.result.permanentlyFailed
                combined.affectedMailboxIds.formUnion(pass.result.affectedMailboxIds)
                let requestedTrailingPass = trailingReplayAccountIds.remove(account.id) != nil
                hasMoreDue = pass.hasMoreDue || requestedTrailingPass
            }
        } catch {
            // A connection-level failure (dead socket, bad credentials,
            // a connect/op timeout) or a suspended database aborted the
            // batch mid-pass — see `replayPass`'s doc comment. `combined`
            // still holds whatever prior passes (or ops earlier in the
            // aborting pass) completed before the throw, so this isn't
            // necessarily all-zero.
            await finishReplayLog(id: logId, outcome: .aborted, result: combined, error: error, note: tookOverStaleInFlight ? Self.staleTakeoverNote : nil)
            throw error
        }
        await finishReplayLog(id: logId, outcome: .completed, result: combined, error: nil, note: tookOverStaleInFlight ? Self.staleTakeoverNote : nil)
        return combined
    }

    /// Task (opqueue スタック修正): marker `finishReplayLog` prepends to
    /// `opQueueReplayLog.errorDescription` for a pass that took over a
    /// stale in-flight entry — `outcome` itself stays `.completed`/
    /// `.aborted` (whatever this pass's own result was), so this text is
    /// how the「操作同期の診断」screen distinguishes an ordinary pass from
    /// one that had to forcibly reclaim ownership from a presumed-dead
    /// predecessor.
    private static let staleTakeoverNote = "前回の replay がハング/中断したまま残っていたため、所有権を引き継いで実行しました(スタック検出)。"

    /// Inserts an `opQueueReplayLog` row (`outcome: .inProgress`) and trims
    /// the table to `replayLogCap` — trimming happens here (on every insert,
    /// which always runs) rather than only in `finishReplayLog`, so the ring
    /// buffer stays bounded even across a crash-loop that never reaches
    /// `finishReplayLog`. Returns `nil` (best-effort, `try?`) if the write
    /// itself fails — diagnostics must never be able to block or fail an
    /// actual replay.
    private func beginReplayLog(accountId: String, invokedAt: Date) async -> Int64? {
        try? await database.dbWriter.write { db in
            var record = OpQueueReplayLogRecord(accountId: accountId, invokedAt: invokedAt, outcome: .inProgress)
            try record.insert(db)
            try db.execute(
                sql: """
                DELETE FROM \(OpQueueReplayLogRecord.databaseTableName)
                WHERE id NOT IN (
                    SELECT id FROM \(OpQueueReplayLogRecord.databaseTableName)
                    ORDER BY invokedAt DESC, id DESC LIMIT ?
                )
                """,
                arguments: [OpQueueProcessor.replayLogCap]
            )
            return record.id
        }
    }

    /// Updates the row `beginReplayLog` inserted with its final outcome —
    /// a no-op if `id` is `nil` (the insert itself failed) or the row is
    /// somehow already gone. Best-effort (`try?`), same rationale as
    /// `beginReplayLog`.
    ///
    /// - Parameter note: Task (opqueue スタック修正): an optional
    ///   informational marker (currently only `staleTakeoverNote`) prepended
    ///   to `errorDescription` — combined with `error`'s own text (if any)
    ///   rather than replacing it, since a pass can both take over a stale
    ///   in-flight entry *and* itself abort with a real error.
    private func finishReplayLog(id: Int64?, outcome: OpQueueReplayLogRecord.Outcome, result: ReplayResult, error: Error?, note: String? = nil) async {
        guard let id else { return }
        _ = try? await database.dbWriter.write { db in
            guard var record = try OpQueueReplayLogRecord.fetchOne(db, key: id) else { return }
            record.completedAt = Date()
            record.outcome = outcome.rawValue
            record.succeeded = result.succeeded
            record.discardedStale = result.discardedStale
            record.retrying = result.retrying
            record.permanentlyFailed = result.permanentlyFailed
            record.affectedMailboxCount = result.affectedMailboxIds.count
            let errorText = error.map { (($0 as? SyncEngineError)?.userFacingMessage) ?? String(describing: $0) }
            let parts = [note, errorText].compactMap { $0 }
            record.errorDescription = parts.isEmpty ? nil : parts.joined(separator: " / ")
            try record.update(db)
        }
    }

    /// Task (opqueue スタック修正): whether `cleanupStaleInProgressReplayLogsIfNeeded`
    /// already ran this process lifetime — it should run at most once, not
    /// on every `replay(account:auth:)` call.
    private var didCleanupStaleInProgressReplayLogs = false

    /// アプリ起動後、最初の`replay(account:auth:)`呼び出しで一度だけ、
    /// 前回のプロセスが`.inProgress`のまま終了した (クラッシュ/強制終了)
    /// `opQueueReplayLog`行を`.aborted`+「アプリ終了により中断」として
    /// 確定させる。専用のアプリ起動フックを`OtegamiApp`側に追加しなくても、
    /// 既存の数十箇所ある`replay`呼び出し経路のどれか最初の1回で自然に
    /// 走る。「操作同期の診断」画面が過去分の`.inProgress`行だらけになって
    /// 「未完了 (アプリが途中で終了した可能性)」の表示が積み上がり続ける
    /// のを防ぐ、あくまで表示上の後始末 — `inFlightAccountIds`自体は
    /// プロセスのメモリ上にしか無く新しいプロセスでは自動的に空から
    /// 始まるため、同一プロセス内でのスタック検出 (stale in-flight 奪い取り)
    /// とは独立した目的。Best-effort (`try?`)、`beginReplayLog`と同じ理由。
    private func cleanupStaleInProgressReplayLogsIfNeeded() async {
        guard !didCleanupStaleInProgressReplayLogs else { return }
        didCleanupStaleInProgressReplayLogs = true
        _ = try? await database.dbWriter.write { db in
            try db.execute(
                sql: """
                UPDATE \(OpQueueReplayLogRecord.databaseTableName)
                SET outcome = ?, completedAt = ?, errorDescription = ?
                WHERE outcome = ?
                """,
                arguments: [
                    OpQueueReplayLogRecord.Outcome.aborted.rawValue,
                    Date(),
                    "アプリ終了により中断されました。",
                    OpQueueReplayLogRecord.Outcome.inProgress.rawValue
                ]
            )
        }
    }

    /// `replayPass`'s result plus whether the due queue still has more work
    /// than this pass processed — see `defaultReplayBatchLimit`'s doc
    /// comment. Private/file-local; `replay(account:auth:)`'s loop is the
    /// only consumer, so this doesn't need to be `Sendable`/public the way
    /// `ReplayResult` (a genuine public API type) does.
    private struct ReplayPassOutcome {
        var result: ReplayResult
        var hasMoreDue: Bool
    }

    /// One queue snapshot → connection → apply/delete cycle. Ownership and
    /// overlap coalescing live in `replay(account:auth:)`; keeping one pass
    /// separate keeps each trailing pass on its own session and runs the
    /// existing session-scoped disconnect cleanup at every pass boundary.
    ///
    /// Task (opqueue スタック修正): `session.connect(auth:)` and each op's
    /// `apply(...)` are now both wrapped in `withTimeout(seconds:
    /// timeoutError:operation:)` (`connectTimeout`/`opApplyTimeout`) — a
    /// hung MailCore2 call used to leave this `await` never returning,
    /// which is exactly how the real device ended up with `replay` for one
    /// account never coming back and its `inFlightAccountIds` entry never
    /// releasing. A timeout throws a synthetic `MailTransportError
    /// .connectionFailed`, which `SyncFailureClass.classify` already
    /// treats as connection-level — same abort-the-batch handling this
    /// method already had for a real dead socket, no new failure path to
    /// reason about at the per-op `catch` sites below.
    ///
    /// `dueOps` is also capped at `replayBatchLimit` — see that property's
    /// doc comment (`defaultReplayBatchLimit`) for why a large backlog
    /// needs bounded passes rather than one pass processing everything.
    private func replayPass(account: AccountRecord, auth: MailAuth) async throws -> ReplayPassOutcome {
        var result = ReplayResult()

        let now = Date()
        let allPending = try await database.dbWriter.read { db in
            try OpQueueRecord
                .filter(Column("accountId") == account.id)
                .filter(Column("attempts") < OpQueueProcessor.maxAttempts)
                .order(Column("id"))
                .fetchAll(db)
        }
        let allDueOps = allPending.filter { op in
            guard let nextRetryAt = op.nextRetryAt else { return true }
            return nextRetryAt <= now
        }
        guard !allDueOps.isEmpty else { return ReplayPassOutcome(result: result, hasMoreDue: false) }
        let dueOps = Array(allDueOps.prefix(replayBatchLimit))
        let hasMoreDue = allDueOps.count > dueOps.count

        let session = sessionFactory(account.imapConfig)
        try await Self.withTimeout(
            seconds: connectTimeout,
            timeoutError: MailTransportError.connectionFailed(underlyingDescription: "IMAP接続がタイムアウトしました(\(Int(self.connectTimeout))秒)")
        ) {
            try await session.connect(auth: auth)
        }
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        for op in dueOps {
            do {
                let outcome = try await Self.withTimeout(
                    seconds: opApplyTimeout,
                    timeoutError: MailTransportError.connectionFailed(underlyingDescription: "操作の適用がタイムアウトしました(\(Int(self.opApplyTimeout))秒、kind: \(op.kind))")
                ) {
                    try await self.apply(op: op, account: account, session: session, auth: auth)
                }
                switch outcome {
                case .applied(let affectedMailboxIds):
                    try await delete(op: op)
                    result.succeeded += 1
                    result.affectedMailboxIds.formUnion(affectedMailboxIds)
                case .staleDiscarded:
                    try await recordStaleDiscardAndDelete(op: op)
                    result.discardedStale += 1
                }
            } catch let error as MailTransportError where SyncFailureClass.classify(error) == .connectionLevel {
                throw error
            } catch where DatabaseSuspensionSupport.isSuspensionError(error) {
                // Task #192 (0xDEAD10CC 対策): the shared database is
                // suspended — `recordFailure(op:error:)` right below is
                // itself a `database.dbWriter.write` call, which would just
                // fail the exact same way (and, unlike every other call site
                // in this file, isn't wrapped in `try?`, so that failure
                // would propagate out of this `catch` block uncaught).
                // Every remaining op in `dueOps` would hit the same wall, so
                // treat this like a connection-level failure and abort the
                // whole batch — a normal replay picks the untouched queue
                // back up once the app foregrounds and the database resumes
                // (`OtegamiApp.handleScenePhaseChange`'s `.active` case
                // already calls `replayOpQueue` on every foreground return).
                // Deliberately not counted against `op.attempts`: this
                // wasn't the op's fault.
                throw error
            } catch {
                let attempts = try await recordFailure(op: op, error: error)
                if attempts >= OpQueueProcessor.maxAttempts {
                    result.permanentlyFailed += 1
                } else {
                    result.retrying += 1
                }
            }
        }
        Self.opReflectLogger.notice("replay completed accountId=\(account.id, privacy: .private) succeeded=\(result.succeeded) discardedStale=\(result.discardedStale) retrying=\(result.retrying) permanentlyFailed=\(result.permanentlyFailed) affectedMailboxCount=\(result.affectedMailboxIds.count)")
        return ReplayPassOutcome(result: result, hasMoreDue: hasMoreDue)
    }

    /// Races `operation` against `seconds` and returns whichever finishes
    /// first, throwing `timeoutError()` if the clock wins.
    ///
    /// **Deliberately not** a `withThrowingTaskGroup` race: `SyncCoordinator
    /// .serverSearch(query:accounts:authProvider:timeout:)`'s own doc
    /// comment already worked out why that doesn't actually bound wall-clock
    /// time here — a `TaskGroup`'s body must await every child task before
    /// returning (even ones the caller stopped waiting on, even after
    /// `cancelAll()`), and Swift's cancellation is cooperative: it can't
    /// force a MailCore2 call blocked on a callback that will simply never
    /// fire to return early. A `TaskGroup`-based race would therefore still
    /// hang for exactly the failure mode this exists to catch. Two
    /// independent **unstructured** `Task`s race into a shared
    /// `ReplayRaceBox` instead — whichever settles first wins, and the loser
    /// (almost always the hung `operation`, on the rare occasion this
    /// actually fires) is simply abandoned: still running in the
    /// background, but with nothing left awaiting it, same tradeoff
    /// `serverSearch` accepts for its own per-account race.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: @autoclosure @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ReplayRaceBox<T>()
        Task {
            do {
                let value = try await operation()
                await box.resolve(.success(value))
            } catch {
                await box.resolve(.failure(error))
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await box.resolve(.failure(timeoutError()))
        }
        defer { timeoutTask.cancel() }
        return try await box.wait()
    }

    /// Not `private` — `applySend`/`applySaveDraft`
    /// (`OpQueueProcessor+Send.swift`/`OpQueueProcessor+SaveDraft.swift`)
    /// return this too; see `database`'s doc comment above for why.
    /// Task (opqueue スタック修正): explicit `Sendable` conformance — `apply`
    /// is now called through `withTimeout(seconds:timeoutError:operation:)`,
    /// whose result crosses an unstructured `Task`/`CheckedContinuation`
    /// boundary (see that function's doc comment), so its return type needs
    /// a real `Sendable` conformance rather than relying on the implicit
    /// same-module inference that was enough while every call stayed within
    /// this actor's own isolation.
    enum ApplyOutcome: Sendable {
        /// Task #152: carries the destination mailbox ids safe to refresh
        /// immediately after this op (never its optimistic source) — see
        /// `ReplayResult.affectedMailboxIds`'s doc comment.
        case applied(affectedMailboxIds: Set<Int64>)
        case staleDiscarded
    }

    private func apply(
        op: OpQueueRecord,
        account: AccountRecord,
        session: any IMAPSessionProtocol,
        auth: MailAuth
    ) async throws -> ApplyOutcome {
        switch OpQueueKind(rawValue: op.kind) {
        case .setFlags:
            let payload = try JSONDecoder().decode(SetFlagsOpPayload.self, from: op.payload)
            guard let mailbox = try await mailbox(id: payload.mailboxId), mailbox.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            let change = FlagChange(
                uids: UIDSet(payload.uids),
                op: payload.op,
                flags: MessageFlags(rawValue: payload.flagsRaw),
                uidValidity: UInt32(truncatingIfNeeded: payload.uidValidity)
            )
            try await session.store(mailboxPath: mailbox.path, change: change)
            return .applied(affectedMailboxIds: [])

        case .move:
            let payload = try JSONDecoder().decode(MoveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let destination = try await mailbox(id: payload.destinationMailboxId) else {
                return .staleDiscarded
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: destination.path)
            return .applied(affectedMailboxIds: [payload.destinationMailboxId])

        case .delete:
            let payload = try JSONDecoder().decode(DeleteOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let trash = try await MailboxRoleResolver.resolveOrCreate(role: .trash, accountId: account.id, session: session, database: database) else {
                // No Trash-role mailbox known for this account, and either
                // there was nothing to self-heal towards (see
                // `MailboxRoleResolver.resolveOrCreate`'s doc comment) or the
                // self-heal attempt itself failed. Leave the op pending — a
                // future replay (after a sync discovers Trash, or after
                // whatever blocked `CREATE` is fixed server-side) can still
                // complete it — rather than silently dropping a
                // user-intended delete.
                throw SyncEngineError.noRoleMailbox(role: .trash)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: trash.path)
            return .applied(affectedMailboxIds: Set([trash.id].compactMap { $0 }))

        case .junk:
            let payload = try JSONDecoder().decode(JunkOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let junk = try await MailboxRoleResolver.resolveOrCreate(role: .junk, accountId: account.id, session: session, database: database) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`'s identical
                // Trash-resolution failure above.
                throw SyncEngineError.noRoleMailbox(role: .junk)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: junk.path)
            return .applied(affectedMailboxIds: Set([junk.id].compactMap { $0 }))

        case .unjunk:
            let payload = try JSONDecoder().decode(UnjunkOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let inbox = try await MailboxRoleResolver.mailbox(role: .inbox, accountId: account.id, database: database) else {
                // Same "leave the op pending rather than silently dropping a
                // user-intended action" shape as `.unarchive`'s identical
                // INBOX lookup failure below.
                throw SyncEngineError.noRoleMailbox(role: .inbox)
            }
            // A plain move for every provider, Gmail included — see
            // `OpQueueKind.unjunk`'s doc comment for why this needs no
            // `account.kind` branch even though `.unarchive` does.
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
            return .applied(affectedMailboxIds: Set([inbox.id].compactMap { $0 }))

        case .archive:
            let payload = try JSONDecoder().decode(ArchiveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            if account.kind == .gmail {
                // Gmail has no `\Archive`-flagged folder (see
                // `OpQueueKind.archive`'s doc comment) — "archiving" is
                // un-labeling the source mailbox, not moving anywhere.
                // Gmail auto-retains every non-Spam/Trash message in "All
                // Mail" regardless of label state, so `\Deleted`+`EXPUNGE`
                // on the *source* mailbox only (never Trash, never a COPY)
                // removes it from that label without deleting it.
                let change = FlagChange(
                    uids: UIDSet(payload.uids), op: .add, flags: .deleted,
                    uidValidity: UInt32(truncatingIfNeeded: payload.uidValidity)
                )
                try await session.store(mailboxPath: source.path, change: change)
                try await session.expunge(mailboxPath: source.path)
                // All Mail is where the message now exclusively lives, so it
                // is this op's effective destination even though nothing was
                // moved there — `MessageRemoval.relocationDestinationId` may
                // have parked a placeholder-UID row in it, and only an All
                // Mail sync can adopt that row onto its real UID
                // (`EnvelopePersister.reconcilePendingRelocation`). Without
                // this, All Mail is never resynced on any of the paths that
                // run after an archive (launch/foreground/push/IDLE are all
                // `SyncScope.inboxOnly`), so the placeholder lingered until
                // the user happened to open that mailbox. Source (INBOX) is
                // still deliberately absent — see `ReplayResult
                // .affectedMailboxIds`. A lookup, never a `resolveOrCreate`:
                // All Mail is Gmail's own folder and must never be created
                // here. Not finding one isn't an error either — the unlabel
                // itself already succeeded, and throwing would only retry it
                // into a second `EXPUNGE`.
                let allMail = try await MailboxRoleResolver.mailbox(role: .all, accountId: account.id, database: database)
                return .applied(affectedMailboxIds: Set([allMail?.id].compactMap { $0 }))
            }
            guard let archive = try await MailboxRoleResolver.resolveOrCreate(role: .archive, accountId: account.id, session: session, database: database) else {
                // Same "leave the op pending rather than silently dropping
                // a user-intended action" shape as `.delete`/`.junk`'s
                // identical resolution failure.
                throw SyncEngineError.noRoleMailbox(role: .archive)
            }
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: archive.path)
            return .applied(affectedMailboxIds: Set([archive.id].compactMap { $0 }))

        case .unarchive:
            let payload = try JSONDecoder().decode(UnarchiveOpPayload.self, from: op.payload)
            guard let source = try await mailbox(id: payload.sourceMailboxId), source.uidValidity == payload.uidValidity else {
                return .staleDiscarded
            }
            guard let inbox = try await MailboxRoleResolver.mailbox(role: .inbox, accountId: account.id, database: database) else {
                // No INBOX-role mailbox known yet for this account (should
                // only happen if the very first sync somehow hasn't
                // completed) — leave the op pending rather than silently
                // dropping a user-intended "アーカイブ解除", same shape as
                // every other `resolveOrCreate*`/lookup failure above.
                throw SyncEngineError.noRoleMailbox(role: .inbox)
            }
            if account.kind == .gmail {
                // Gmail: restoring the INBOX label is "add it to INBOX
                // too", never a move — see `OpQueueKind.unarchive`'s doc
                // comment. A plain `COPY`, not `MOVE`/`COPY`+delete+expunge:
                // the message must stay in All Mail exactly as it already
                // is.
                try await session.copy(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
                return .applied(affectedMailboxIds: Set([inbox.id].compactMap { $0 }))
            }
            // Every other provider: the reverse of `.archive`'s own
            // `session.move(...)` call just above — a real move back to
            // INBOX from wherever it currently sits (its Archive-role
            // mailbox).
            try await session.move(mailboxPath: source.path, uids: UIDSet(payload.uids), to: inbox.path)
            return .applied(affectedMailboxIds: Set([inbox.id].compactMap { $0 }))

        case .emptyTrash:
            let payload = try JSONDecoder().decode(EmptyTrashOpPayload.self, from: op.payload)
            guard let mailbox = try await mailboxIfCurrent(id: payload.mailboxId, expectedUidValidity: payload.uidValidity) else {
                return .staleDiscarded
            }
            guard !payload.uids.isEmpty else { return .applied(affectedMailboxIds: []) }
            // No move, no destination — the Trash mailbox this batch
            // targets *is* the mailbox being purged. `EmptyTrash.commit`
            // already hard-deleted these rows locally, so there's nothing
            // to resync here (`ReplayResult.affectedMailboxIds`'s doc
            // comment: only relocation destinations are ever reported).
            let change = FlagChange(
                uids: UIDSet(payload.uids), op: .add, flags: .deleted,
                uidValidity: UInt32(truncatingIfNeeded: payload.uidValidity)
            )
            try await session.store(mailboxPath: mailbox.path, change: change)
            try await session.expunge(mailboxPath: mailbox.path)
            return .applied(affectedMailboxIds: [])

        case .send:
            // Moved to `OpQueueProcessor+Send.swift` (`applySend`) —
            // Task #124's `claimSendStart`/`releaseSendClaim` idempotency
            // guard's timing/ordering is preserved character-for-character,
            // only relocated.
            return try await applySend(op: op, account: account, session: session, auth: auth)

        case .saveDraft:
            // Moved to `OpQueueProcessor+SaveDraft.swift` (`applySaveDraft`)
            // — logic unchanged, only relocated.
            return try await applySaveDraft(op: op, account: account, session: session)

        case .deleteDraft:
            let payload = try JSONDecoder().decode(DeleteDraftOpPayload.self, from: op.payload)
            guard let mailbox = try await mailboxIfCurrent(id: payload.mailboxId, expectedUidValidity: payload.uidValidity) else {
                return .staleDiscarded
            }
            try await deleteMessage(mailboxPath: mailbox.path, uid: payload.uid, uidValidity: payload.uidValidity, session: session)
            return .applied(affectedMailboxIds: [])

        case nil:
            // An unrecognized kind (e.g. a newer app version's op being
            // replayed after a downgrade) — nothing sensible to retry.
            return .staleDiscarded
        }
    }

    private func mailbox(id: Int64) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in try MailboxRecord.fetchOne(db, key: id) }
    }

    /// Role-mailbox lookups (INBOX/Trash/Junk/Archive/Sent/Drafts) and the
    /// self-healing `CREATE` for Trash/Junk/Archive/Drafts now live in
    /// `MailboxRoleResolver` — extracted since this actor used to carry six
    /// lookup functions and four resolve-or-create functions that were
    /// byte-for-byte identical except for the role. See that type's doc
    /// comments for the self-heal semantics this preserves exactly
    /// (including that `.inbox`/`.sent` never self-heal).

    /// Kept as a thin forwarding alias — `AccountSyncer.drafts(among:)`
    /// references this exact name to recognize the same self-heal target
    /// `MailboxRoleResolver.resolveOrCreate(role: .drafts, ...)` now
    /// creates, and that call site is out of scope for this refactor.
    static let draftsMailboxNameToCreate = MailboxRoleResolver.mailboxNameToCreate(for: .drafts) ?? "Drafts"

    /// Returns `mailboxId`'s current `MailboxRecord` only if it still
    /// exists *and* its `uidValidity` still matches `expectedUidValidity`
    /// — `nil` otherwise (mailbox gone, or recreated with a different
    /// uidValidity since `expectedUidValidity` was captured). The same
    /// staleness contract `SetFlagsOpPayload`/`MoveOpPayload`/`DeleteOpPayload`
    /// already encode inline at each of their call sites; factored out here
    /// since `.saveDraft`'s old-copy cleanup, `.deleteDraft`, and `.send`'s
    /// linked-draft cleanup all need the identical check.
    /// Not `private` — `applySend`/`applySaveDraft` call this too; see
    /// `database`'s doc comment above for why.
    func mailboxIfCurrent(id: Int64, expectedUidValidity: Int64) async throws -> MailboxRecord? {
        guard let candidate = try await mailbox(id: id), candidate.uidValidity == expectedUidValidity else { return nil }
        return candidate
    }

    /// Marks `uid` `\Deleted` and expunges it — the replace/delete
    /// primitive `.saveDraft`'s old-copy cleanup, `.deleteDraft`, and
    /// `.send`'s linked-draft cleanup all share. No staleness check here;
    /// callers are expected to have already done theirs via
    /// ``mailboxIfCurrent(id:expectedUidValidity:)``. `uidValidity` is
    /// carried through purely as `FlagChange`'s required field — the real
    /// `MailCoreIMAPSession.store` implementation doesn't actually consult
    /// it (a mailbox is already addressed by path, already `SELECT`-free
    /// per-command over IMAP), only `FakeIMAPSession`'s test recorder does.
    /// Not `private` — `applySend`/`applySaveDraft` call this too; see
    /// `database`'s doc comment above for why.
    func deleteMessage(mailboxPath: String, uid: UInt32, uidValidity: Int64, session: any IMAPSessionProtocol) async throws {
        let change = FlagChange(
            uids: UIDSet([uid]), op: .add, flags: .deleted,
            uidValidity: UInt32(truncatingIfNeeded: uidValidity)
        )
        try await session.store(mailboxPath: mailboxPath, change: change)
        try await session.expunge(mailboxPath: mailboxPath)
    }

    /// Everything `.saveDraft` (`draftMessage(id:)`/`draftAttachments
    /// (draftMessageId:)`) and `.send` (`outboxMessage(id:)`/
    /// `claimSendStart`/`releaseSendClaim`/`outboxAttachments
    /// (outboxMessageId:)`/`deleteOutboxMessage(id:)`, including the
    /// Task #124 二重送信防止 claim/release pair) exclusively needed has
    /// moved with those case handlers into `OpQueueProcessor+SaveDraft.swift`/
    /// `OpQueueProcessor+Send.swift` — nothing else in this file called them.

    private func delete(op: OpQueueRecord) async throws {
        _ = try await database.dbWriter.write { db -> Bool in
            try Self.reopenUnseenSweepGate(for: op, db: db)
            return try op.delete(db)
        }
    }

    /// この op が `PendingOpTargets` のガードを掛けていたメールボックスの
    /// `lastUnseenSweepAt` を `nil` に戻す — op が消えた以上、その UID に
    /// ついてサーバーの言い分はもう古くない。
    ///
    /// `UnseenSweeper` は未送信 op に守られた UID を残数に数えない
    /// (`sweep` の doc comment) ので、op が消えた直後の残数は測り直す価値が
    /// ある。ところが `ReplayResult.affectedMailboxIds` は移動系の**移動元**を
    /// 意図的に外している (サーバーの結果整合性で楽観的更新が巻き戻るのを
    /// 避けるため) ので、アーカイブ元の INBOX はこの後 targeted resync の
    /// 対象にならない。スイープの 15 分ゲートだけが残り、実測の再開が
    /// 最大 15 分遅れていた。
    ///
    /// ここでするのはゲートを外すことだけで、`unseenNotFetchedCount` には
    /// 触らない — 実測は次の `incrementalSync` の仕事。ネットワークも叩か
    /// ないので、上の設計判断を侵さない。恒久失敗した op は `opQueue` に
    /// 残る (= ガードも残る) ため、この経路を通らないのが正しい。
    private static func reopenUnseenSweepGate(for op: OpQueueRecord, db: Database) throws {
        let mailboxIds = PendingOpTargets.targetMailboxIds(of: op)
        guard !mailboxIds.isEmpty else { return }
        try MailboxRecord
            .filter(mailboxIds.contains(Column("id")))
            .updateAll(db, Column("lastUnseenSweepAt").set(to: nil))
    }

    /// User-facing (Japanese) reason `recordStaleDiscardAndDelete` writes
    /// to every `opQueueStaleDiscard` row — every `.staleDiscarded` case in
    /// `apply(op:account:session:auth:)` shares the exact same root cause
    /// (the target mailbox's `uidValidity` no longer matches what this op
    /// was enqueued against), so one shared string is accurate for all of
    /// them; see `SetFlagsOpPayload`'s doc comment for why that makes the
    /// op unsendable rather than just stale.
    private static let staleDiscardReason = "メールボックスの構成が変わったため、この操作をサーバーへ送信できませんでした（フォルダが再作成された可能性があります）。"

    /// Records `op` into `opQueueStaleDiscard` and deletes it from
    /// `opQueue`, atomically (same `db.write` transaction) — the fix for
    /// the `.staleDiscarded` path silently dropping unsendable ops with no
    /// trace at all (実機報告「Gmail で既読化/アーカイブしてもサーバに
    /// 反映されず、再読込でサーバ状態に巻き戻る」の調査で見つかった容疑の
    /// 一つ). Unlike a normal permanently-failed op (`recordFailure`, which
    /// leaves the row in `opQueue` with `attempts >= maxAttempts` for
    /// `FailedOperationsView`'s existing retry/discard UI), a stale op is
    /// deleted outright — its `uidValidity` is gone for good, so "retry"
    /// would just immediately hit the exact same `.staleDiscarded` check
    /// again. `FailedOperationsView` shows `opQueueStaleDiscard` rows
    /// alongside genuinely-retryable permanently-failed ops (read-only,
    /// dismiss-only) so the user still has the same "同期エラー" screen to
    /// notice this in.
    private func recordStaleDiscardAndDelete(op: OpQueueRecord) async throws {
        _ = try await database.dbWriter.write { db -> Bool in
            var discard = OpQueueStaleDiscardRecord(accountId: op.accountId, kind: op.kind, reason: Self.staleDiscardReason)
            try discard.insert(db)
            try Self.reopenUnseenSweepGate(for: op, db: db)
            return try op.delete(db)
        }
    }

    /// Records a failed attempt and returns the new `attempts` count.
    @discardableResult
    private func recordFailure(op: OpQueueRecord, error: Error) async throws -> Int {
        let attempts = op.attempts + 1
        let backoff = min(
            OpQueueProcessor.backoffCap,
            OpQueueProcessor.backoffBase * pow(2, Double(attempts - 1))
        )
        let failed = attempts >= OpQueueProcessor.maxAttempts
        try await database.dbWriter.write { db in
            var record = op
            record.attempts = attempts
            // `SyncEngineError.userFacingMessage` rather than `String
            // (describing:)` directly — preserves `FailedOperationsView`'s
            // existing caption text for `.duplicateSendBlocked` (the one
            // case with real UI copy, not just a technical description;
            // see `SyncEngineError.userFacingMessage`'s doc comment).
            // `String(describing:)` unchanged for every other error type
            // (`MailTransportError`, GRDB's `DatabaseError`, ...).
            record.lastError = (error as? SyncEngineError)?.userFacingMessage ?? String(describing: error)
            record.nextRetryAt = failed ? nil : Date().addingTimeInterval(backoff)
            try record.update(db)
        }
        return attempts
    }

    // `isConnectionLevel(_:)` moved to `SyncFailureClass.classify(_:)` — see
    // that type's doc comment for why it's a standalone type rather than
    // reusing `AccountSyncer`'s own private `FailureClass`.
}

/// The default `smtpSessionFactory` for callers that never queue a `.send`
/// op (every M1–M4 test/call site) — throws `.notImplemented` rather than
/// requiring every existing `OpQueueProcessor(database:sessionFactory:)`
/// call to start naming an SMTP factory it doesn't use.
public actor NotImplementedSMTPSession: SMTPSessionProtocol {
    public init(config: SMTPConfig) {}
    public func connect(auth: MailAuth) async throws {
        throw MailTransportError.notImplemented("No smtpSessionFactory configured for this OpQueueProcessor")
    }
    public func disconnect() async {}
    public func sendMessage(messageData: Data, from: EmailAddress, recipients: [EmailAddress]) async throws {
        throw MailTransportError.notImplemented("No smtpSessionFactory configured for this OpQueueProcessor")
    }
}

/// Single-slot rendezvous point `OpQueueProcessor.withTimeout(seconds:
/// timeoutError:operation:)` uses to let two independent, unstructured
/// `Task`s race for a result — whichever calls `resolve(_:)` first wins;
/// the other's call is silently dropped. `wait()` may be called before or
/// after `resolve(_:)` (both `operation` and the timeout timer run
/// concurrently with the caller's own `await box.wait()`, so either order
/// is possible): a `resolve(_:)` that arrives first stashes its result in
/// `settled` for `wait()` to pick up immediately; a `wait()` that arrives
/// first parks a continuation for `resolve(_:)` to resume later.
private actor ReplayRaceBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var settled: Result<T, Error>?

    func wait() async throws -> T {
        if let settled { return try settled.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<T, Error>) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
