import Foundation

/// Task #192: GRDB's `Database.suspendNotification`/`.resumeNotification`
/// are posted through the process-wide `NotificationCenter.default` —
/// hardcoded inside GRDB itself (`DatabaseQueue.setupSuspension()`), not
/// something a test can scope to just its own `DatabaseQueue`. Swift
/// Testing runs `@Test` functions concurrently by default — including,
/// under `swift test`, across different test targets sharing one test
/// process — so two tests that both suspend a real database at the same
/// moment would otherwise suspend (or resume) *each other's* database out
/// from under them, exactly the kind of flake this lock exists to prevent
/// (confirmed by observation: `DatabaseSuspensionTests`' real-suspension
/// test is reliable alone but was seen to fail under the full `swift test`
/// run before this lock was added).
///
/// A `flock()`-based file lock — not, say, an `actor` — because it also
/// serializes across separate *processes* should `swift test` ever run
/// test targets that way, not just concurrent `Task`s within one process.
///
/// Shared by `OtegamiStoreTests` (`DatabaseSuspensionTests`) and
/// `SyncEngineTests` (`AccountSyncerTests`/`OpQueueProcessorTests`) via
/// this `OtegamiKitTestSupport` target — a plain (non-test) target, since
/// SwiftPM doesn't allow a `testTarget` to depend on another `testTarget`,
/// mirroring `OAuthKitTestSupport`'s role of holding code shared between
/// `GoogleOAuthTests` and `MicrosoftOAuthTests`. Both consuming test
/// targets point at the same well-known temp path, so they actually
/// serialize against one another too, not just against tests within their
/// own target.
public enum DatabaseSuspensionTestLock {
    private static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("otegami-database-suspension-test.lock").path

    /// 2026-08-06 (ci-app「Test OtegamiKit」が無出力のままハングする実障害
    /// の根本原因、`docs/ci.md`の同名の節参照): 以前ここは素の
    /// `flock(fd, LOCK_EX)` (同期ブロッキング syscall) を `async` 関数の
    /// 中で直接呼んでいた。これは Swift Concurrency の協調スレッドプール
    /// (幅 ≒ コア数) のワーカースレッドを 1 本まるごと固定する — この
    /// ロックを取り合うテストは 4 件あり (`DatabaseSuspensionTests` /
    /// `AppDatabaseTests` / `AccountSyncerTests+Suspension` /
    /// `OpQueueProcessorTests+Retry`)、Swift Testing の既定並行実行で
    /// 同時に走り出すと「保持 1 + `flock` 待ち 3」でスレッドを 3 本塞ぐ。
    /// CI の macOS ランナー (3-4 vCPU、プール幅 3-4) ではこれで**全ワーカー
    /// スレッドが埋まり、保持側の `body()` 内の continuation を再開する
    /// スレッドが永遠に無くなる** = プロセス全体の恒久デッドロック。停止
    /// 位置がテスト実行のスケジューリング次第で毎回変わり、コア数の多い
    /// ローカル機では再現しないという観測とも一致する
    /// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` でプール幅を 1 に絞ると
    /// ローカルでも決定的に再現し、`sample` のスタックで唯一のワーカーが
    /// この `flock` で停止していることを確認済み)。
    ///
    /// 対策: `LOCK_NB` (非ブロッキング) で試行し、取れなければ
    /// `Task.sleep` (スレッドを手放す待機) でリトライする。ロックの意味論
    /// (プロセス内・プロセス間の両方で排他) は変えず、待機中に協調プール
    /// のスレッドを一切占有しないようにする。
    public static func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        precondition(fd >= 0, "failed to open the database-suspension test lock file at \(path)")
        defer { close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
