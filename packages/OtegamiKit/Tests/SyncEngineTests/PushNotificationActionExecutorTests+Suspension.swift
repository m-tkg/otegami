import Foundation
import GRDB
import Testing
import OtegamiKitTestSupport
import OtegamiStore
@testable import SyncEngine

/// 実クラッシュ調査 (TestFlight v1.14.1, iPad, `0xDEAD10CC`) の副作用:
/// `OtegamiApp.swift` now posts GRDB's suspend notification eagerly, which
/// can race `PushNotificationActionExecutor.execute`'s own local-DB write —
/// the only durable record that a "既読にする"/"アーカイブ" tap happened at
/// all. `applyWithSuspensionRetry` exists to give that write a few quick
/// retries rather than silently dropping the action — see its own doc
/// comment for the full reasoning and the residual limitation this doesn't
/// close.
///
/// Exercises `applyWithSuspensionRetry` directly (not through `execute(...)`
/// end to end) — `execute`'s own account/mailbox reads would themselves
/// observe an already-suspended database and return early, never reaching
/// the write this type is actually about.
@Suite("PushNotificationActionExecutor — Task #192 database suspension retry")
struct PushNotificationActionExecutorSuspensionTests {
    /// Mirrors `DatabaseSuspensionTests.makeSuspendableQueue()`/
    /// `AccountSyncerTests+Suspension.swift`'s identical file-backed,
    /// `observesSuspensionNotifications`-enabled setup — GRDB 7.11.1's
    /// in-memory `DatabaseQueue` init never registers the suspend/resume
    /// observers at all, so an in-memory database here would make these
    /// tests inert.
    private func makeSuspendableDatabase() throws -> (database: AppDatabase, path: String) {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.observesSuspensionNotifications = true
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("otegami-push-action-suspension-test-\(UUID().uuidString).sqlite").path
        let dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try dbQueue.write { db in try db.execute(sql: "CREATE TABLE t(a)") }
        return (try AppDatabase(dbQueue), path)
    }

    @Test("retries and succeeds once the database resumes before attempts are exhausted")
    func retriesUntilResumed() async throws {
        // `Database.suspendNotification` is process-global — serialize
        // against every other test in this run that also posts it for real
        // (`DatabaseSuspensionTestLock`'s doc comment).
        try await DatabaseSuspensionTestLock.withLock {
            let (database, path) = try makeSuspendableDatabase()
            defer { try? FileManager.default.removeItem(atPath: path) }

            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
            defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }

            // Resumes shortly after the first (failing) attempt, well within
            // the retry budget below — simulates a suspend flag that
            // clears again quickly, the case this retry exists to recover.
            Task.detached {
                try? await Task.sleep(nanoseconds: 30_000_000)
                NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            }

            let result = try await PushNotificationActionExecutor.applyWithSuspensionRetry(
                database: database, maxAttempts: 5, retryDelayNanoseconds: 20_000_000
            ) { db in
                try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                return true
            }
            #expect(result)

            let count = try await database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") }
            #expect(count == 1)
        }
    }

    @Test("gives up and throws a suspension error once every retry is exhausted")
    func exhaustsRetriesWhileStillSuspended() async throws {
        try await DatabaseSuspensionTestLock.withLock {
            let (database, path) = try makeSuspendableDatabase()
            defer { try? FileManager.default.removeItem(atPath: path) }

            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
            // Deliberately never resumed mid-test — a real background
            // launch that never becomes `.active` has no resume coming
            // either (this function's own doc comment, "known residual
            // limitation"). Still resumed in `defer` so this test doesn't
            // leave the process-wide suspend flag set for whatever test
            // runs next.
            defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }

            // A suspended `DatabasePool`/`DatabaseQueue` refuses to even
            // *begin* a transaction — `updates` itself is never invoked for
            // any of the attempts (confirmed here: `attemptCount` stays 0),
            // matching `DatabaseSuspensionTests`'s "a write against a
            // suspended database throws" behavior one level up.
            let attemptCount = LockedCounter()
            do {
                _ = try await PushNotificationActionExecutor.applyWithSuspensionRetry(
                    database: database, maxAttempts: 3, retryDelayNanoseconds: 5_000_000
                ) { db -> Bool in
                    attemptCount.increment()
                    try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                    return true
                }
                Issue.record("expected every attempt to observe the still-suspended database and throw")
            } catch {
                #expect(DatabaseSuspensionSupport.isSuspensionError(error))
            }
            #expect(attemptCount.value == 0, "a suspended database never even reaches the `updates` closure body")

            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
            let count = try await database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") }
            #expect(count == 0, "no attempt should have left a partial write behind")
        }
    }

    @Test("an ordinary (non-suspension) error is not retried")
    func doesNotRetryOrdinaryErrors() async throws {
        // Doesn't post suspend/resume itself, but still needs the lock —
        // `Database.suspendNotification`/`.resumeNotification` are
        // process-global (`DatabaseSuspensionTestLock`'s doc comment), so a
        // *different* concurrently-running `@Test` in this suite that does
        // post one could otherwise suspend this test's database out from
        // under it (observed: this test flaked with a real "Database is
        // suspended" error before this lock was added).
        try await DatabaseSuspensionTestLock.withLock {
            let (database, path) = try makeSuspendableDatabase()
            defer { try? FileManager.default.removeItem(atPath: path) }

            struct SomeError: Error {}
            let attemptCount = LockedCounter()
            do {
                _ = try await PushNotificationActionExecutor.applyWithSuspensionRetry(
                    database: database, maxAttempts: 3, retryDelayNanoseconds: 5_000_000
                ) { _ -> Bool in
                    attemptCount.increment()
                    throw SomeError()
                }
                Issue.record("expected the thrown error to propagate")
            } catch {
                #expect(error is SomeError)
            }
            #expect(attemptCount.value == 1, "a non-suspension error must fail fast, not retry")
        }
    }
}

/// Minimal `Sendable` mutable counter for closures that need to record a
/// call count from inside a `@Sendable (Database) throws -> T` closure — a
/// plain `var` can't be mutated there under Swift 6 strict concurrency.
/// Mirrors `AccountSyncerTests+Suspension.swift`'s identically-purposed
/// `LockedBox`.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
