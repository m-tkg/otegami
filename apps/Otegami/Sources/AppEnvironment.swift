import Foundation
import GRDB
import MailTransportMailCore
import OtegamiStore
import SyncEngine

/// Root dependency-injection container for the app: the shared database,
/// the sync coordinator (wired to the real `MailCoreIMAPSession` — tests
/// inject `FakeIMAPSession` directly into `SyncEngine`'s own test target
/// instead of going through this type), and the Keychain-backed credential
/// store. Also keeps a live `accounts` list so the sidebar (and anything
/// else that needs "which accounts exist") doesn't have to set up its own
/// top-level `ValueObservation`.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let syncCoordinator: SyncCoordinator
    let credentialStore: KeychainCredentialStore

    private(set) var accounts: [AccountRecord] = []
    @ObservationIgnored private var accountsObservationTask: Task<Void, Never>?

    init() {
        let database: AppDatabase
        do {
            database = try AppDatabase.makeShared()
        } catch {
            // The on-disk database couldn't be opened (corrupt file, out of
            // disk space, ...). Falling back to in-memory keeps the app
            // usable for the current launch rather than crashing outright;
            // the underlying issue would need a real repair/reset flow to
            // recover from permanently, which is out of scope for M1.
            assertionFailure("Failed to open shared database, falling back to in-memory: \(error)")
            guard let inMemory = try? AppDatabase.makeInMemory() else {
                fatalError("Failed to create even an in-memory database: \(error)")
            }
            database = inMemory
        }
        self.database = database
        self.syncCoordinator = SyncCoordinator(database: database) { config in
            MailCoreIMAPSession(config: config)
        }
        self.credentialStore = KeychainCredentialStore()

        startObservingAccounts()
    }

    deinit {
        accountsObservationTask?.cancel()
    }

    private func startObservingAccounts() {
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("createdAt")).fetchAll(db)
        }
        accountsObservationTask = Task { [database] in
            do {
                for try await accounts in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    self.accounts = accounts
                }
            } catch {
                // A failing account-list observation shouldn't be fatal —
                // the sidebar just won't update further until relaunch.
            }
        }
    }
}
