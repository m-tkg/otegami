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

    /// 1 アカウントに対してこのプールが同時に張ってよい実接続の本数。
    ///
    /// 実機報告 (Gmail の `Too many simultaneous connections`、
    /// `MailTransportError.tooManyConnections`) を受けて入れた上限。それ
    /// までこのプールは「直近の 1 本を再利用する」だけで本数の制御を一切
    /// 持たず、`checkout` が空振りするたびに無条件で新しい接続を張って
    /// いた。フォアグラウンド復帰時には IDLE・全アカウント同期・opQueue
    /// replay・本文取得・先読み・バックフィル・cid インライン画像の取得が
    /// 同時に走るので、実際に上限へ届いていた。
    ///
    /// 4 という値の根拠: Gmail のアカウントあたりの上限は 15。そのうち
    /// このプールを**通らない**接続がいくつかある — フォアグラウンドの
    /// IDLE ループがアカウントあたり 1 本 (`idleSessionFactory` は非プール)、
    /// 通知拡張が別プロセスでさらに 1 本、アカウント設定の接続テストが
    /// 1 本。加えて他のメールクライアントや Gmail の Web UI が同じアカ
    /// ウントを開いていることもある。プール経由をこの本数に抑えておけば、
    /// それらを足しても上限に対して十分な余裕が残る。
    public static let defaultMaxConcurrentConnections = 4

    /// スロットが空くのを待てる上限時間。ここを無期限にすると、万一
    /// スロットの解放漏れが起きたときに UI ごと固まってしまう。超えた
    /// 場合は `.tooManyConnections` として扱い、呼び出し側の既存の
    /// リトライ・エラー表示に乗せる。
    public static let defaultAcquireTimeout: TimeInterval = 30

    private let idleTTL: TimeInterval
    private let maxConcurrentConnections: Int
    private let acquireTimeout: TimeInterval
    private let underlyingFactory: SessionFactory
    private var idleEntries: [AccountKey: IdleEntry] = [:]

    /// このプールが `key` のアカウントに対していま握っている実接続の本数。
    ///
    /// `giveBack` でアイドルに戻っただけでは減らさない — サーバーから見れば
    /// 接続はまだ生きており、同時接続数を消費し続けているため。実際に
    /// `disconnect()` したとき (TTL 失効 / `discard` / `drainAll`) だけ減る。
    private var openConnectionCounts: [AccountKey: Int] = [:]

    /// 空きスロットを待っている取得要求の FIFO 待ち行列。
    private var waiters: [AccountKey: [Waiter]] = [:]

    /// 待ち手には「スロットが空いた」だけでなく、可能なら「そのまま使える
    /// 接続済みセッション」も渡す。使用中のセッションが返却された瞬間に
    /// 待ち手がいる場合、それを一旦アイドルに寝かせて相手に張り直させるのは
    /// 純粋な無駄 (しかもスロットが空かないので相手は進めない)。
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<(any IMAPSessionProtocol)?, any Error>
    }
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
        maxConcurrentConnections: Int = PooledIMAPSessionFactory.defaultMaxConcurrentConnections,
        acquireTimeout: TimeInterval = PooledIMAPSessionFactory.defaultAcquireTimeout,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.underlyingFactory = sessionFactory
        self.idleTTL = idleTTL
        self.maxConcurrentConnections = max(1, maxConcurrentConnections)
        self.acquireTimeout = acquireTimeout
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
    ///
    /// 再利用されたセッションはスロットを既に握っているので、ここでは
    /// `openConnectionCounts` を触らない — アイドルの間もサーバー側では
    /// 接続が生きており、その分は最初に張ったときから数え続けている。
    func checkout(key: AccountKey) -> (any IMAPSessionProtocol)? {
        guard let entry = idleEntries.removeValue(forKey: key) else { return nil }
        entry.expireTask?.cancel()
        return entry.session
    }

    // MARK: - 同時接続数のスロット

    /// 新しい実接続を張ってよくなるまで待つ。空きがあれば即座に返る。
    ///
    /// 戻り値が非 `nil` なら「スロットに加えて、そのまま使える接続済み
    /// セッションも引き継いだ」という意味 — 呼び出し側は新規に `connect`
    /// せずそれを使う。`nil` なら自分で張る。
    ///
    /// スロットの総数は移譲のときに増減しない (`openConnectionCounts` を
    /// 減らしてから増やし直すのではなく、そのまま次の待ち手へ渡す) ので、
    /// 解放と取得の間に別のタスクが割り込んで上限を超えることがない。
    func acquireConnectionSlot(key: AccountKey) async throws -> (any IMAPSessionProtocol)? {
        if openConnectionCounts[key, default: 0] < maxConcurrentConnections {
            openConnectionCounts[key, default: 0] += 1
            return nil
        }

        // 同じアカウントのアイドル接続があるなら、待たずにそれを引き継ぐ
        // — `checkout` が空振りしたあとでも、その後に別の借り手が返却した
        // 直後ならここで拾える。
        if let entry = idleEntries.removeValue(forKey: key) {
            entry.expireTask?.cancel()
            return entry.session
        }

        let id = UUID()
        let timeout = acquireTimeout
        let sleep = sleep
        let timeoutTask = Task { [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOutWaiter(key: key, id: id)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(any IMAPSessionProtocol)?, any Error>) in
            waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
        }
    }

    /// 待ち手がいれば先頭の 1 人に `session` (スロットごと) を渡し、`true`
    /// を返す。いなければ何もせず `false`。
    private func handOffToWaiter(key: AccountKey, session: (any IMAPSessionProtocol)?) -> Bool {
        guard var queue = waiters[key], !queue.isEmpty else { return false }
        let waiter = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: session)
        return true
    }

    /// 実接続を 1 本閉じたときに呼ぶ。待っている取得要求があれば、空いた
    /// スロットをそのまま先頭の待ち手へ渡す (接続自体はもう無いので、
    /// 相手は自分で張り直す)。
    func releaseConnectionSlot(key: AccountKey) {
        guard !handOffToWaiter(key: key, session: nil) else { return }

        let current = openConnectionCounts[key, default: 0]
        if current <= 1 {
            openConnectionCounts[key] = nil
        } else {
            openConnectionCounts[key] = current - 1
        }
    }

    /// `acquireTimeout` を過ぎても順番が回ってこなかった取得要求を諦めさせる。
    /// 既に `releaseConnectionSlot` に起こされていた場合は待ち行列から消えて
    /// いるので、ここでは何もしない (二重 resume を避ける)。
    private func timeOutWaiter(key: AccountKey, id: UUID) {
        guard var queue = waiters[key], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(
            throwing: MailTransportError.tooManyConnections(
                underlyingDescription: "IMAP connection slot unavailable after \(Int(acquireTimeout))s"
            )
        )
    }

    /// `session` をプールへ返却し、`idleTTL` の失効タイマーを開始する。
    /// `discard: true` の場合はプールに載せず実切断する — 立つ条件は
    /// `PooledIMAPSession.mustDiscardOnDisconnect` の doc comment 参照
    /// (`[LIMIT]` レート制限応答、またはキャンセルで中断されたセッション)。
    func giveBack(key: AccountKey, session: any IMAPSessionProtocol, discard: Bool) async {
        guard !discard else {
            await session.disconnect()
            releaseConnectionSlot(key: key)
            return
        }
        // スロットの空きを待っている borrower がいるなら、アイドルに寝かせず
        // そのまま引き渡す。ここで寝かせてしまうと、待ち手はスロットが空く
        // まで進めない一方でこの接続は誰にも使われない、という取り違えが
        // 起きる (使用中の本数は上限のままなので待ち行列も進まない)。
        guard !handOffToWaiter(key: key, session: session) else { return }

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
        releaseConnectionSlot(key: key)
    }

    /// 保持しているアイドルセッションを全て実切断して破棄する —
    /// `SyncCoordinator.stopAllIdleLoops()` と対になる「バックグラウンド
    /// 遷移時は接続を持ったままにしない」ためのフック
    /// (`OtegamiApp.handleScenePhaseChange` の `.background`/`.inactive` から
    /// 呼ばれる)。
    public func drainAll() async {
        let entries = idleEntries
        idleEntries.removeAll()
        for (key, entry) in entries {
            entry.expireTask?.cancel()
            await entry.session.disconnect()
            releaseConnectionSlot(key: key)
        }
    }

    /// テスト専用: 現在プールが保持しているアイドルセッション数。
    var idleSessionCountForTesting: Int { idleEntries.count }

    /// テスト専用: `key` に対していま握っている実接続の本数。
    func openConnectionCountForTesting(key: AccountKey) -> Int {
        openConnectionCounts[key, default: 0]
    }
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
    /// このセッションを `disconnect()` 時にプールへ返さず実切断すべきか。
    /// 立つのは 2 つの場合:
    ///
    /// - pitfall i: このサイクル中に `[LIMIT]` を含む `serverError` を一度
    ///   でも受け取った (Gmail のレート制限応答)。
    /// - 実機バグ (キャンセルが効かない) の対応で入った
    ///   `MailCoreIMAPSession.runCancellable` によるキャンセル: MailCore2 の
    ///   `MCOperation::cancel()` はフラグを立てるだけで、実行中のソケット
    ///   読み取りを中断しない (`MCOperation.cpp`)。つまりキャンセルで
    ///   `await` を抜けた時点でも、下位セッションはまだサーバーとの
    ///   コマンドの途中かもしれない — その状態のセッションを再利用すると、
    ///   次の操作が前のコマンドの残りの応答を読んでしまう。返却せず切って
    ///   捨てるのが唯一安全な扱い。
    private var mustDiscardOnDisconnect = false

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
        mustDiscardOnDisconnect = false

        if let reused = await pool.checkout(key: key) {
            underlying = reused
            wasReused = true
            return
        }

        // 新規の実接続はここでアカウント別の上限に従う。空きが無ければ
        // 待つ (`PooledIMAPSessionFactory.defaultMaxConcurrentConnections`
        // の doc comment 参照)。取得できたスロットは、このセッションが実
        // 切断されるまで握り続ける。
        let inherited = try await pool.acquireConnectionSlot(key: key)
        if let inherited {
            // 待っている間に誰かが接続を返してきた (または直前にアイドルへ
            // 戻っていた) ので、張り直さずそれを使う。`checkout` 経由の
            // 再利用と同じ扱いにして、最初の操作が失敗したときの1回だけの
            // 張り替えも効くようにする。
            underlying = inherited
            wasReused = true
            return
        }

        wasReused = false
        let fresh = await pool.makeUnderlyingSession(config: config)
        do {
            try await fresh.connect(auth: auth)
            underlying = fresh
        } catch {
            // v1.14.2 UAF 修正 (3): `fresh.connect` が例外を投げても、下位
            // 実装 (`MailCoreIMAPSession`) は TCP/TLS ハンドシェイクまで
            // 進んでから LOGIN で失敗しているかもしれない — その場合ソケット
            // は開いたままで、明示的に `disconnect()` を投げない限り deinit
            // 経由の `SessionLingerBox` 任せになる。`Task.detached` から呼ぶ
            // のは、このメソッド自身を呼んでいる Task がここで再送出する
            // `error` によりキャンセルされた経路である場合、ここに素直に
            // `await fresh.disconnect()` と書くと disconnect オペレーション
            // 自体もキャンセルされて何も送信されないため (`MailCoreIMAPSession
            // .runVoid` は `Task` のキャンセルを継承する) — 呼び出し元の
            // キャンセル状態を継承しない `Task.detached` にすることで、この
            // disconnect だけは最後まで実行させる。
            Task.detached { await fresh.disconnect() }
            // 接続が張れなかったのでスロットは即返す。ここで返さないと、
            // 接続不能なアカウントがスロットを食い潰したままになる。
            await pool.releaseConnectionSlot(key: key)
            throw error
        }
    }

    public func disconnect() async {
        guard let underlying else { return }
        self.underlying = nil
        guard let pool, let accountKey else {
            await underlying.disconnect()
            return
        }
        await pool.giveBack(key: accountKey, session: underlying, discard: mustDiscardOnDisconnect)
    }

    private static func username(from auth: MailAuth) -> String {
        switch auth {
        case .password(let username, _): username
        case .xoauth2(let username, _): username
        }
    }

    /// 通常のフォワーディングに加え、プール固有の振る舞いを実装する:
    /// - 再利用セッションの最初の操作が `.connectionFailed` で失敗した場合、
    ///   1回だけ新規接続に張り替えて同じ操作を再発行する (返却〜再利用の
    ///   間にサーバー側で切断されていた場合の自然なリトライ)。
    /// - `.serverError` の説明文に `[LIMIT]` を含む場合 (pitfall i のレート
    ///   制限応答)、または操作が `CancellationError` を投げた場合は
    ///   `mustDiscardOnDisconnect` を立て、`disconnect()` にこのセッションを
    ///   破棄させる (それぞれの理由はそのプロパティの doc comment 参照)。
    private func perform<T>(_ operation: (any IMAPSessionProtocol) async throws -> T) async throws -> T {
        guard let underlying else { throw MailTransportError.notConnected }
        do {
            let result = try await operation(underlying)
            hasAttemptedOperationSinceConnect = true
            return result
        } catch {
            markMustDiscardIfNeeded(error)
            if wasReused, !hasAttemptedOperationSinceConnect, isConnectionFailed(error),
               let pool, let auth = lastAuth {
                hasAttemptedOperationSinceConnect = true
                wasReused = false
                // v1.14.2 UAF 修正 (3): 張り替え前の `underlying` (この操作が
                // `.connectionFailed` で失敗した、死んでいたはずの再利用
                // セッション) を捨てる前に明示的に disconnect() する。すでに
                // 死んでいる接続への LOGOUT は失敗するだけだろうが、
                // `MailCoreIMAPSession.disconnect()` 側は `connectAttempted`
                // さえ立っていれば安全に no-op 的に振る舞う (fix 3 参照) の
                // で、ここで呼んでおけば少なくとも MailCore2 側の内部状態が
                // 正規の切断経路を一度は通る。`Task.detached` にするのは
                // `IMAPSessionPool.swift`'s `connect(auth:)` の catch と同じ
                // 理由 (呼び出し元 Task のキャンセルを継承させない)。
                let stale = underlying
                Task.detached { await stale.disconnect() }
                let fresh = await pool.makeUnderlyingSession(config: config)
                try await fresh.connect(auth: auth)
                self.underlying = fresh
                return try await operation(fresh)
            }
            hasAttemptedOperationSinceConnect = true
            throw error
        }
    }

    private func markMustDiscardIfNeeded(_ error: Error) {
        if error is CancellationError {
            mustDiscardOnDisconnect = true
            return
        }
        guard let mailError = error as? MailTransportError else { return }
        switch mailError {
        case .serverError(let description):
            if description.contains("[LIMIT]") {
                mustDiscardOnDisconnect = true
            }
        case .tooManyConnections:
            // Gmail の同時接続数上限。`[LIMIT]` 判定に引っかからない別文言
            // ("Too many simultaneous connections") なので明示的に拾う —
            // 上限に当たったセッションをプールへ戻すと、次の借り手が同じ
            // 詰まった接続を掴んで同じ失敗を繰り返す。
            mustDiscardOnDisconnect = true
        default:
            break
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
