import Foundation
import GRDB
import OtegamiCore
import os

/// The app's local GRDB database: schema migrations, and the single
/// `DatabaseWriter` every DAO/query in `OtegamiStore` (and `SyncEngine`
/// above it) reads and writes through.
///
/// Production code should go through ``makeShared()``, which places the
/// database file under Application Support. Tests use ``makeInMemory()``
/// (a `DatabaseQueue`, since `DatabasePool` requires a real file for its
/// WAL/mmap machinery) so migrations and queries can be exercised without
/// touching disk.
public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    /// Wraps an already-configured `DatabaseWriter` and runs migrations on
    /// it. Prefer ``makeShared()``/``makeInMemory()`` unless a test needs a
    /// custom writer (e.g. one with a `ValueObservation` scheduler
    /// override).
    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
        Self.logStaleMessageBodyRenderVersionCount(dbWriter)
    }

    /// 2026-07-30 (v36の`messageBody.renderVersion`導入時): 起動のたびに
    /// 「まだ古い版数のまま=次に開いたら遅延再フェッチされる、本文キャッ
    /// シュがどれだけ残っているか」を件数だけ (本文は一切出さない、F15の
    /// 趣旨) notice ログへ — 一括再取得はしない設計なので、この件数は
    /// ユーザーが実際にそのメッセージを開くまでゆっくり減っていく。運用側
    /// が「まだ大量に残っているのに翻訳/表示の不具合報告が来る」ような
    /// ギャップに気づけるようにするためのもの。失敗しても起動を止めない。
    private static func logStaleMessageBodyRenderVersionCount(_ dbWriter: any DatabaseWriter) {
        guard let count = try? dbWriter.read({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messageBody WHERE renderVersion < ?", arguments: [MessageBodyRecord.currentRenderVersion])
        }) else { return }
        guard count > 0 else { return }
        Logger(subsystem: "com.mtkg.otegami", category: "AppDatabase")
            .notice("messageBody: \(count, privacy: .public) row(s) still at a stale renderVersion (current=\(MessageBodyRecord.currentRenderVersion, privacy: .public)), pending lazy re-fetch on next open")
    }

    /// The shared on-disk database, at
    /// `<container>/otegami/otegami.sqlite`.
    ///
    /// `appGroupIdentifier`, when non-`nil` and a container for it actually
    /// exists, places the database in that App Group's shared container
    /// instead of this process's own Application Support directory (M9:
    /// lets the `NotificationService` Extension open the same database —
    /// read-only in practice, since it only ever looks up an
    /// `AccountRecord` — as a concurrent `DatabasePool`/WAL reader; SQLite's
    /// WAL mode supports exactly this multi-process read pattern). Falls
    /// back to the pre-M9 Application Support location when `nil` or the
    /// container can't be resolved (no App Group entitlement configured —
    /// true for `swift test`, previews, and any target that never opted
    /// in), so this stays backward compatible for every caller that
    /// doesn't pass one.
    public static func makeShared(appGroupIdentifier: String? = nil) throws -> AppDatabase {
        let (directory, isSharedContainer) = try sharedDirectory(appGroupIdentifier: appGroupIdentifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami.sqlite")
        // Task #192 (実機クラッシュ 0xDEAD10CC): only a database that actually
        // lives in the App Group's shared container is at risk of iOS
        // killing this process for holding a lock on it while suspended —
        // see `makeConfiguration(observesSuspensionNotifications:)`'s doc
        // comment. `isSharedContainer` is `false` on macOS (no App Group
        // entitlement — `OtegamiAppGroup.identifier` always returns `nil`
        // there) and for every `swift test`/preview target, so this stays a
        // no-op everywhere except the real iOS app and the `NotificationService`
        // Extension, both of which open this exact same shared file.
        let dbPool = try DatabasePool(path: url.path, configuration: makeConfiguration(observesSuspensionNotifications: isSharedContainer))
        return try AppDatabase(dbPool)
    }

    private static func sharedDirectory(appGroupIdentifier: String?) throws -> (directory: URL, isSharedContainer: Bool) {
        if let appGroupIdentifier, !appGroupIdentifier.isEmpty,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return (container.appendingPathComponent("otegami", isDirectory: true), true)
        }
        return (try applicationSupportDirectory(), false)
    }

    /// An in-memory database (no file on disk), for tests and previews.
    public static func makeInMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: makeConfiguration())
        return try AppDatabase(dbQueue)
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("otegami", isDirectory: true)
    }

    /// - Parameter observesSuspensionNotifications: Task #192 (実機クラッシュ
    ///   解析: `EXC_CRASH`/`SIGKILL`, `RUNNINGBOARD` termination code
    ///   `3735883980` = `0xDEAD10CC` — iOS's dedicated code for "killed this
    ///   app for holding a file/SQLite lock while suspended in the
    ///   background"). GRDB's official fix (`Documentation.docc
    ///   /DatabaseSharing.md`'s "How to limit the 0xDEAD10CC exception"
    ///   section, verified against the exact GRDB 7.11.1 tag this project
    ///   pins in `Package.resolved` — not assumed from memory): set
    ///   ``Configuration/observesSuspensionNotifications`` so this
    ///   `DatabasePool` starts listening for ``Database/suspendNotification``/
    ///   ``Database/resumeNotification``. Once suspended, GRDB refuses to
    ///   acquire any *new* SQLite lock — the exact thing that can trigger
    ///   `0xDEAD10CC` — and instead fails the access with
    ///   `SQLITE_INTERRUPT`/`SQLITE_ABORT` (`DatabaseError.isInterruptionError`).
    ///   `AppEnvironment.suspendSharedDatabaseIfNeeded()`/
    ///   `.resumeSharedDatabaseIfNeeded()` (iOS-only — macOS has no shared
    ///   App Group container to race a background suspend over, see
    ///   `OtegamiAppGroup.identifier`'s doc comment) post those two
    ///   notifications from `OtegamiApp.handleScenePhaseChange`;
    ///   `SyncEngine`'s `AccountSyncer`/`OpQueueProcessor` treat the
    ///   resulting interruption errors as "try again once resumed", not a
    ///   real sync failure — see `DatabaseSuspensionSupport
    ///   .isSuspensionError(_:)`'s doc comment. Defaults to `false` so
    ///   `makeInMemory()` (tests/previews, and every target with no App
    ///   Group entitlement) never pays for observers it has no use for.
    private static func makeConfiguration(observesSuspensionNotifications: Bool = false) -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.observesSuspensionNotifications = observesSuspensionNotifications
        return configuration
    }
}

extension AppDatabase {
    /// v1: `account` / `mailbox` / `message` / `messageReference` are what
    /// M1 (this migration's original purpose) actually reads and writes.
    /// `messageBody` / `attachment` / `thread` / `opQueue` and the FTS5
    /// index are defined now (so later milestones don't need a schema
    /// migration just to add a table the plan already specified) but stay
    /// empty until M2+.
    ///
    /// The v1〜v38 registrations themselves live in
    /// `Migrations/AppDatabase+MigrationsV1toV10.swift` and its three
    /// siblings (split out purely for file size — Phase 4 OtegamiKit
    /// 内部整理); see that file's doc comment for the ordering/identifier
    /// rules that make the split safe. `static let`, not `static var`:
    /// every existing caller (`AppDatabase.init`, `AppDatabaseTests`) only
    /// ever reads this and calls `.migrate(...)` on the result, never
    /// mutates it, so there's no need to rebuild the same ~40 migration
    /// closures on every access — `DatabaseMigrator` is a `Sendable`
    /// value type, so a single lazily-computed, cached instance shared
    /// across every caller (including concurrent ones) is safe.
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerAppDatabaseMigrationsV1ToV10()
        migrator.registerAppDatabaseMigrationsV11ToV20()
        migrator.registerAppDatabaseMigrationsV21ToV30()
        migrator.registerAppDatabaseMigrationsV31ToV38()
        return migrator
    }()
}

