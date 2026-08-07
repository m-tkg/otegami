import Foundation
import MailTransport
import OtegamiCore

/// Phase 3 (IMAP 接続の再利用): TTL 付きの短命接続プール。
///
/// 現状、`SyncCoordinator`/`AccountSyncer`/`OpQueueProcessor` の同期パスは
/// すべて「`sessionFactory` → `connect` (TLS+LOGIN+ENABLE+NAMESPACE) → 数
/// コマンド → `disconnect`」という使い捨て接続の繰り返しで、フォアグラウンド
/// 復帰1回だけでもアカウントあたり複数回の再接続が起きる (IDLE 再接続 /
/// `replayOpQueue` / `syncAccountIncrementally` / unified inbox prefetch、
/// 加えて本文・添付・cid画像・スレッド要約のたびに1接続)。このプールは
/// `IMAPSessionPool` を経由する `sessionFactory` を差し込むだけで、
/// 呼び出し側 (`withIMAPSession` の `defer { disconnect }` パターンなど) を
/// 一切変更せずに直近の接続を再利用できるようにする。
///
/// 設計の要点:
/// - `IMAPSessionProtocol` にのみ依存 — transport 非依存 (`MailTransportMailCore`
///   を知らない)。
/// - キーはアカウントの同一性 (`IMAPConfig` の host/port/security/TLS +
///   `MailAuth` から取り出した username)。`MailAuth` 自体 (パスワード/OAuth
///   トークン本体) はキーに含めない — OAuth のアクセストークン文字列だけが
///   リフレッシュで変わっても同一アカウントなら再利用してよい、という
///   要求どおり。
/// - 実際に貸し出すのは `PooledIMAPSession` (`IMAPSessionProtocol` 準拠の
///   ラッパー)。`connect(auth:)` は下位セッションが接続済みならプールへの
///   返却経路を通さず no-op、`disconnect()` は実切断ではなくプールへの
///   返却。
/// - TTL (`idleTTL`, デフォルト8秒): 返却から8秒経過したアイドル接続は実
///   `disconnect()` して破棄する。8秒はフォアグラウンド復帰1回の中で連続
///   して起きる複数操作 (IDLE wake → 差分同期 → opQueue replay、または
///   メッセージ一覧の本文/添付/cid画像の連続取得) をカバーしつつ、サーバー
///   側の同時接続数制限に触れないよう無期限には保持しない、という妥協点。
public actor PooledIMAPSessionFactory {
    public typealias SessionFactory = @Sendable (IMAPConfig) -> any IMAPSessionProtocol

    /// アカウントの同一性を表すキー。`IMAPConfig` はもともと `Hashable` で
    /// host/port/security/allowsInsecureTLS を持つが、資格情報 (username)
    /// は `MailAuth` 側にしかないため、`connect(auth:)` の時点で
    /// `MailAuth` から取り出した username と組み合わせてキーにする。
    struct AccountKey: Hashable, Sendable {
        var config: IMAPConfig
        var username: String
    }

    /// 返却済みだがまだ TTL 内の接続済みセッション一本と、その失効タイマー。
    /// `@unchecked Sendable`: 中身の `session` (`any IMAPSessionProtocol`)
    /// 自体は `Sendable` 準拠だが、`expireTask` への書き込みを含む全ての
    /// アクセスがこのファイル内の `PooledIMAPSessionFactory` (actor) の
    /// isolated メソッド経由に限られる — 失効タイマーの `Task` クロージャに
    /// この参照を渡すために手動でこの保証を主張する。
    private final class IdleEntry: @unchecked Sendable {
        let session: any IMAPSessionProtocol
        var expireTask: Task<Void, Never>?
        init(session: any IMAPSessionProtocol) {
            self.session = session
        }
    }

    /// 返却から実切断までの待機時間。テストは短い値を注入して決定的に検証
    /// する (`init(sessionFactory:idleTTL:)`)。
    public static let defaultIdleTTL: TimeInterval = 8

    private let idleTTL: TimeInterval
    private let underlyingFactory: SessionFactory
    private var idleEntries: [AccountKey: IdleEntry] = [:]
    /// 失効タイマーの待機実装。`SyncRetryPolicy.sleep` と同じ「injected
    /// clock/sleeper」パターン — CI ランナーの負荷で `Task.sleep` ベースの
    /// タイマー発火が実時間から大きく遅れ、実時間待ちのテストが flaky に
    /// なった実例 (ci-app、`PooledIMAPSessionFactoryTests` の TTL テスト)
    /// への対処。プロダクションはデフォルトの実 `Task.sleep`、テストは
    /// 即時 return する実装を注入して失効経路を決定的に検証する。
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        sessionFactory: @escaping SessionFactory,
        idleTTL: TimeInterval = PooledIMAPSessionFactory.defaultIdleTTL,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.underlyingFactory = sessionFactory
        self.idleTTL = idleTTL
        self.sleep = sleep
    }

    /// `SyncCoordinator.init(sessionFactory:)` にそのまま渡せるクロージャ。
    /// 呼ぶたびに新しい `PooledIMAPSession` ラッパーを返す — 実際のプール
    /// ロジックはそのラッパーの `connect(auth:)`/`disconnect()` の中で起こる
    /// ので、既存の呼び出し側 (`withIMAPSession` などの
    /// `sessionFactory(config)` → `connect` → ... → `disconnect` という
    /// パターン) は無変更で恩恵を受ける。
    public nonisolated func makeSessionFactory() -> SessionFactory {
        { [self] config in self.makeSession(config: config) }
    }

    public nonisolated func makeSession(config: IMAPConfig) -> PooledIMAPSession {
        PooledIMAPSession(pool: self, config: config)
    }

    /// 実 factory を呼んで新規セッションを1本作る — キャッシュミス時と、
    /// `PooledIMAPSession` の「再利用セッションの最初の操作が
    /// `connectionFailed` だった場合の1回だけの張り替え」の両方から呼ばれる。
    func makeUnderlyingSession(config: IMAPConfig) -> any IMAPSessionProtocol {
        underlyingFactory(config)
    }

    /// `key` に対応する接続済みアイドルセッションがあれば取り出す (その
    /// タイマーもキャンセルする)。`nil` なら呼び出し側が新規に `connect`
    /// する必要がある。
    func checkout(key: AccountKey) -> (any IMAPSessionProtocol)? {
        guard let entry = idleEntries.removeValue(forKey: key) else { return nil }
        entry.expireTask?.cancel()
        return entry.session
    }

    /// `session` をプールへ返却し、`idleTTL` の失効タイマーを開始する。
    /// `discard: true` (Task #206/#211 の pitfall i: `[LIMIT]` レート制限
    /// 応答を受けたセッション) の場合はプールに載せず実切断する。
    func giveBack(key: AccountKey, session: any IMAPSessionProtocol, discard: Bool) async {
        guard !discard else {
            await session.disconnect()
            return
        }
        let entry = IdleEntry(session: session)
        idleEntries[key] = entry
        let ttl = idleTTL
        let sleep = sleep
        entry.expireTask = Task { [weak self] in
            await sleep(ttl)
            guard !Task.isCancelled else { return }
            await self?.expireIfStillIdle(key: key, entry: entry)
        }
    }

    /// タイマー発火時、その `entry` がまだこの `key` の現在のアイドル
    /// エントリである場合だけ実切断する — `checkout`/別の `giveBack` に
    /// 差し替えられていた場合 (`===` で参照比較) は何もしない。
    private func expireIfStillIdle(key: AccountKey, entry: IdleEntry) async {
        guard idleEntries[key] === entry else { return }
        idleEntries.removeValue(forKey: key)
        await entry.session.disconnect()
    }

    /// 保持しているアイドルセッションを全て実切断して破棄する —
    /// `SyncCoordinator.stopAllIdleLoops()` と対になる「バックグラウンド
    /// 遷移時は接続を持ったままにしない」ためのフック
    /// (`OtegamiApp.handleScenePhaseChange` の `.background`/`.inactive` から
    /// 呼ばれる)。
    public func drainAll() async {
        let entries = idleEntries
        idleEntries.removeAll()
        for entry in entries.values {
            entry.expireTask?.cancel()
            await entry.session.disconnect()
        }
    }

    /// テスト専用: 現在プールが保持しているアイドルセッション数。
    var idleSessionCountForTesting: Int { idleEntries.count }
}

/// `PooledIMAPSessionFactory` が貸し出すラッパー。`IMAPSessionProtocol` の
/// 全メソッドを下位セッション (`underlying`) へフォワードするだけの薄い層
/// だが、`connect(auth:)`/`disconnect()` だけはプールの checkout/giveBack
/// を経由する特別な意味を持つ。
public actor PooledIMAPSession: IMAPSessionProtocol {
    private let pool: PooledIMAPSessionFactory?
    private let config: IMAPConfig
    private var underlying: (any IMAPSessionProtocol)?
    private var accountKey: PooledIMAPSessionFactory.AccountKey?
    private var lastAuth: MailAuth?
    /// このサイクル (`connect` から次の `disconnect` まで) で `underlying`
    /// がプールから再利用されたものかどうか。「再利用セッションの最初の
    /// 操作が `connectionFailed` なら1回だけ新規接続へ張り替えて同じ操作を
    /// 再発行する」の対象を、再利用直後の最初の呼び出しだけに絞るために
    /// 使う。
    private var wasReused = false
    /// このサイクルで既に1回以上コマンドを試したかどうか — 上記の張り替え
    /// を「最初の操作」だけに限定するためのガード。張り替え後は
    /// `wasReused = false` に落として、以降の失敗は普通に呼び出し側へ伝える
    /// (無限リトライを避ける)。
    private var hasAttemptedOperationSinceConnect = false
    /// pitfall i: このサイクル中に `[LIMIT]` を含む `serverError` を一度でも
    /// 受け取ったか。受け取っていれば `disconnect()` はプールへ返却せず
    /// 実切断する。
    private var encounteredRateLimit = false

    /// `IMAPSessionProtocol` 準拠のために必要な初期化子。このコードベースの
    /// 実際の呼び出し元は常に `sessionFactory(config)` というクロージャ経由
    /// でセッションを得ており (`PooledIMAPSessionFactory.makeSessionFactory()`
    /// が返すクロージャは内部で `init(pool:config:)` を使う)、この
    /// プロトコル要件としての初期化子が直接呼ばれることはない —
    /// `MailCoreIMAPSession`/`FakeIMAPSession` も同様に、ジェネリックな
    /// `T(config:)` 経由で構築される箇所はコードベース中に存在しない。
    /// この経路で構築されたインスタンスはプールに属さないため、
    /// `connect(auth:)` は常に `.notConnected` で失敗する。
    public init(config: IMAPConfig) {
        self.pool = nil
        self.config = config
    }

    init(pool: PooledIMAPSessionFactory, config: IMAPConfig) {
        self.pool = pool
        self.config = config
    }

    public func connect(auth: MailAuth) async throws {
        guard underlying == nil else {
            // すでにこのサイクルで接続済み (新規 connect 直後、または
            // checkout 直後) — 下位セッションは接続済みのため no-op。
            return
        }
        guard let pool else {
            throw MailTransportError.notConnected
        }

        let key = PooledIMAPSessionFactory.AccountKey(config: config, username: Self.username(from: auth))
        accountKey = key
        lastAuth = auth
        hasAttemptedOperationSinceConnect = false
        encounteredRateLimit = false

        if let reused = await pool.checkout(key: key) {
            underlying = reused
            wasReused = true
            return
        }

        wasReused = false
        let fresh = await pool.makeUnderlyingSession(config: config)
        try await fresh.connect(auth: auth)
        underlying = fresh
    }

    public func disconnect() async {
        guard let underlying else { return }
        self.underlying = nil
        guard let pool, let accountKey else {
            await underlying.disconnect()
            return
        }
        await pool.giveBack(key: accountKey, session: underlying, discard: encounteredRateLimit)
    }

    private static func username(from auth: MailAuth) -> String {
        switch auth {
        case .password(let username, _): username
        case .xoauth2(let username, _): username
        }
    }

    /// 通常のフォワーディングに加え、二つのプール固有の振る舞いを実装する:
    /// - 再利用セッションの最初の操作が `.connectionFailed` で失敗した場合、
    ///   1回だけ新規接続に張り替えて同じ操作を再発行する (返却〜再利用の
    ///   間にサーバー側で切断されていた場合の自然なリトライ)。
    /// - `.serverError` の説明文に `[LIMIT]` を含む場合 (pitfall i のレート
    ///   制限応答) は `encounteredRateLimit` を立て、`disconnect()` に
    ///   このセッションを破棄させる。
    private func perform<T>(_ operation: (any IMAPSessionProtocol) async throws -> T) async throws -> T {
        guard let underlying else { throw MailTransportError.notConnected }
        do {
            let result = try await operation(underlying)
            hasAttemptedOperationSinceConnect = true
            return result
        } catch {
            markRateLimitedIfNeeded(error)
            if wasReused, !hasAttemptedOperationSinceConnect, isConnectionFailed(error),
               let pool, let auth = lastAuth {
                hasAttemptedOperationSinceConnect = true
                wasReused = false
                let fresh = await pool.makeUnderlyingSession(config: config)
                try await fresh.connect(auth: auth)
                self.underlying = fresh
                return try await operation(fresh)
            }
            hasAttemptedOperationSinceConnect = true
            throw error
        }
    }

    private func markRateLimitedIfNeeded(_ error: Error) {
        guard let mailError = error as? MailTransportError, case .serverError(let description) = mailError else { return }
        if description.contains("[LIMIT]") {
            encounteredRateLimit = true
        }
    }

    private func isConnectionFailed(_ error: Error) -> Bool {
        guard let mailError = error as? MailTransportError, case .connectionFailed = mailError else { return false }
        return true
    }

    // MARK: - IMAPSessionProtocol forwarding

    public func capabilities() async throws -> Set<IMAPCapability> {
        try await perform { try await $0.capabilities() }
    }

    public func listMailboxes() async throws -> [MailboxInfo] {
        try await perform { try await $0.listMailboxes() }
    }

    public func select(_ mailboxPath: String) async throws -> MailboxStatus {
        try await perform { try await $0.select(mailboxPath) }
    }

    public func createMailbox(path: String) async throws {
        try await perform { try await $0.createMailbox(path: path) }
    }

    public func status(_ mailboxPath: String) async throws -> MailboxStatus {
        try await perform { try await $0.status(mailboxPath) }
    }

    public func fetchEnvelopes(mailboxPath: String, uids: UIDRange, batchSize: Int) async throws -> [FetchedEnvelope] {
        try await perform { try await $0.fetchEnvelopes(mailboxPath: mailboxPath, uids: uids, batchSize: batchSize) }
    }

    public func fetchEnvelopes(mailboxPath: String, uids: UIDSet) async throws -> [FetchedEnvelope] {
        try await perform { try await $0.fetchEnvelopes(mailboxPath: mailboxPath, uids: uids) }
    }

    public func fetchRecentEnvelopes(mailboxPath: String, count: Int, batchSize: Int, status: MailboxStatus) async throws -> [FetchedEnvelope] {
        try await perform { try await $0.fetchRecentEnvelopes(mailboxPath: mailboxPath, count: count, batchSize: batchSize, status: status) }
    }

    public func fetchEnvelopes(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceResult {
        try await perform { try await $0.fetchEnvelopes(mailboxPath: mailboxPath, changedSince: modSeq) }
    }

    public func fetchFlags(mailboxPath: String, changedSince modSeq: UInt64) async throws -> ChangedSinceFlagsResult {
        try await perform { try await $0.fetchFlags(mailboxPath: mailboxPath, changedSince: modSeq) }
    }

    public func searchExistingUIDs(mailboxPath: String, uids: UIDRange) async throws -> Set<UInt32> {
        try await perform { try await $0.searchExistingUIDs(mailboxPath: mailboxPath, uids: uids) }
    }

    public func searchMessages(mailboxPath: String, query: String) async throws -> Set<UInt32> {
        try await perform { try await $0.searchMessages(mailboxPath: mailboxPath, query: query) }
    }

    public func searchUnseenUIDs(mailboxPath: String) async throws -> Set<UInt32> {
        try await perform { try await $0.searchUnseenUIDs(mailboxPath: mailboxPath) }
    }

    public func fetchFlags(mailboxPath: String, uids: UIDRange) async throws -> [UInt32: MessageFlags] {
        try await perform { try await $0.fetchFlags(mailboxPath: mailboxPath, uids: uids) }
    }

    public func fetchFlags(mailboxPath: String, uids: UIDSet) async throws -> [UInt32: MessageFlags] {
        try await perform { try await $0.fetchFlags(mailboxPath: mailboxPath, uids: uids) }
    }

    public func fetchBody(mailboxPath: String, uid: UInt32) async throws -> MessageBodyContent {
        try await perform { try await $0.fetchBody(mailboxPath: mailboxPath, uid: uid) }
    }

    public func fetchMessageBody(mailboxPath: String, uid: UInt32, partId: String?) async throws -> Data {
        try await perform { try await $0.fetchMessageBody(mailboxPath: mailboxPath, uid: uid, partId: partId) }
    }

    public func store(mailboxPath: String, change: FlagChange) async throws {
        try await perform { try await $0.store(mailboxPath: mailboxPath, change: change) }
    }

    public func append(mailboxPath: String, messageData: Data, flags: MessageFlags) async throws -> UInt32? {
        try await perform { try await $0.append(mailboxPath: mailboxPath, messageData: messageData, flags: flags) }
    }

    public func move(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        try await perform { try await $0.move(mailboxPath: mailboxPath, uids: uids, to: destinationPath) }
    }

    public func copy(mailboxPath: String, uids: UIDSet, to destinationPath: String) async throws {
        try await perform { try await $0.copy(mailboxPath: mailboxPath, uids: uids, to: destinationPath) }
    }

    public func expunge(mailboxPath: String) async throws {
        try await perform { try await $0.expunge(mailboxPath: mailboxPath) }
    }

    /// `IDLE` はこのプールを経由しない設計 (`AccountSyncer` の IDLE ループは
    /// 生 factory を別に受け取る — `docs/architecture.md` の配線参照) だが、
    /// `PooledIMAPSession` 自体は `IMAPSessionProtocol` に準拠する必要が
    /// あるため実装は用意する。ストリームなので `perform` の単発リトライ/
    /// レート制限判定は通さず、単純に下位セッションへフォワードする。
    public nonisolated func idle(mailboxPath: String) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let underlying = await self.underlying else {
                    continuation.finish(throwing: MailTransportError.notConnected)
                    return
                }
                do {
                    for try await event in underlying.idle(mailboxPath: mailboxPath) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
