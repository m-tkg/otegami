import Foundation
import GRDB
import Testing
@testable import OtegamiStore

/// Task #192 (実機クラッシュ 0xDEAD10CC 対策). Two things are covered here:
///
/// 1. `DatabaseSuspensionSupport.isSuspensionError(_:)` against a *real*
///    suspended `DatabaseQueue` — not a hand-built `DatabaseError`, so this
///    exercises the actual public GRDB path (`Configuration
///    .observesSuspensionNotifications` + `Database.suspendNotification`/
///    `.resumeNotification`) documented in GRDB 7.11.1's
///    `Documentation.docc/DatabaseSharing.md`, confirming this project's
///    wrapper agrees with what GRDB itself actually throws.
/// 2. `DatabaseSuspensionTracker`'s dedup state machine, in isolation —
///    the "pure logic" `OtegamiApp.handleScenePhaseChange`'s `.background`/
///    `.inactive` → `.active` transitions drive, testable without a
///    SwiftUI host.
@Suite("DatabaseSuspension")
struct DatabaseSuspensionTests {
    /// Builds a **file-backed** `DatabaseQueue` (a fresh temp file per
    /// call) with suspension notifications enabled — the same
    /// `Configuration.observesSuspensionNotifications` flag
    /// `AppDatabase.makeConfiguration(observesSuspensionNotifications:)`
    /// sets for the real shared (App Group) database.
    ///
    /// Deliberately **not** `DatabaseQueue(configuration:)`/`AppDatabase
    /// .makeInMemory()`'s in-memory path — confirmed against GRDB 7.11.1's
    /// own source (`DatabaseQueue.swift`) that its `init(named:
    /// configuration:)` (what an in-memory queue actually goes through)
    /// never calls `setupSuspension()` at all, unlike `init(path:
    /// configuration:)`; only the latter registers the `NotificationCenter`
    /// observers `Database.suspendNotification`/`.resumeNotification` need
    /// to do anything. `configuration.observesSuspensionNotifications =
    /// true` on an in-memory queue is therefore silently inert — this
    /// project's own production code never hits that gap (`AppDatabase
    /// .makeShared` always uses a file-backed `DatabasePool`, and
    /// `.makeInMemory()` never sets the flag at all), but a test asserting
    /// on real suspension behavior specifically needs the file-backed path
    /// to exercise anything.
    private func makeSuspendableQueue() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.observesSuspensionNotifications = true
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("otegami-suspension-test-\(UUID().uuidString).sqlite").path
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    @Test("a write against a suspended database throws an error isSuspensionError(_:) recognizes")
    func recognizesRealSuspensionError() async throws {
        // `Database.suspendNotification` is process-global (see
        // `DatabaseSuspensionTestLock`'s doc comment) — serialize against
        // every other test in this run that also posts it for real.
        try await DatabaseSuspensionTestLock.withLock {
            let dbQueue = try makeSuspendableQueue()
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE t(a)")
            }

            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
            // GRDB's suspend/resume notification handling is itself
            // synchronous (`DatabaseQueue.setupSuspension()` adds a plain
            // `NotificationCenter` observer, no dispatch hop) — no wait needed
            // before the very next access already sees the suspended state.
            defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }

            do {
                try dbQueue.write { db in
                    try db.execute(sql: "INSERT INTO t DEFAULT VALUES")
                }
                Issue.record("expected a suspension error")
            } catch {
                #expect(DatabaseSuspensionSupport.isSuspensionError(error))
            }
        }
    }

    @Test("isSuspensionError(_:) is false for an ordinary error")
    func ordinaryErrorIsNotClassifiedAsSuspension() throws {
        let dbQueue = try makeSuspendableQueue()
        do {
            try dbQueue.write { db in
                try db.execute(sql: "SELECT * FROM nonexistentTable")
            }
            Issue.record("expected a SQL error")
        } catch {
            #expect(!DatabaseSuspensionSupport.isSuspensionError(error))
        }
        struct SomeOtherError: Error {}
        #expect(!DatabaseSuspensionSupport.isSuspensionError(SomeOtherError()))
    }

    @Test("markSuspended() reports true exactly once until markResumed()")
    func trackerDedupsSuspend() async {
        let tracker = DatabaseSuspensionTracker()
        #expect(await tracker.markSuspended())
        // A second suspend while already suspended (the real-world
        // `.active → .inactive → .background` sequence, both legs of which
        // map to "suspend" in `OtegamiApp.handleScenePhaseChange`) must not
        // report "do post again".
        #expect(await tracker.markSuspended() == false)
        #expect(await tracker.markResumed())
        // Symmetric dedup on the resume side.
        #expect(await tracker.markResumed() == false)
    }

    @Test("markResumed() before any markSuspended() is a no-op")
    func trackerStartsResumed() async {
        let tracker = DatabaseSuspensionTracker()
        #expect(await tracker.markResumed() == false)
    }

    @Test("suspend/resume can alternate repeatedly")
    func trackerAlternates() async {
        let tracker = DatabaseSuspensionTracker()
        for _ in 0..<3 {
            #expect(await tracker.markSuspended())
            #expect(await tracker.markResumed())
        }
    }
}
