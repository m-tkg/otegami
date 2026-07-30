import Foundation

/// Task #192: GRDB's `Database.suspendNotification`/`.resumeNotification`
/// are posted through the process-wide `NotificationCenter.default` —
/// hardcoded inside GRDB itself (`DatabaseQueue.setupSuspension()`), not
/// something a test can scope to just its own `DatabaseQueue`. Swift
/// Testing runs `@Test` functions concurrently by default — including,
/// under `swift test`, across different test targets sharing one test
/// process — so two tests that both suspend a real database at the same
/// moment would otherwise suspend (or resume) *each other's* database out
/// from under them, exactly the kind of flake this lock exists to prevent.
///
/// A `flock()`-based file lock — not, say, an `actor` — because it also
/// serializes across separate *processes* should `swift test` ever run
/// test targets that way, not just concurrent `Task`s within one process.
/// `OtegamiStoreTests` (`DatabaseSuspensionTests`) has an identical copy
/// of this same type, for the same reason `FailingStoreSession`-style test
/// doubles are duplicated per test target rather than shared — the two
/// targets don't import each other's test code — pointed at the same
/// well-known temp path so both actually serialize against one another
/// too, not just against tests within their own target.
enum DatabaseSuspensionTestLock {
    private static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("otegami-database-suspension-test.lock").path

    static func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        precondition(fd >= 0, "failed to open the database-suspension test lock file at \(path)")
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
