import Foundation
import OtegamiStore
@testable import AccountCloudSync

/// A trivial in-memory `UbiquitousStoring` — see that protocol's doc
/// comment for why tests never exercise the real iCloud-backed
/// `SystemUbiquitousStore`. Lock-protected plain class, matching
/// `GoogleOAuthTests.FakeRefreshTokenStore`'s pattern for a `Sendable`
/// synchronous test double.
final class FakeUbiquitousStore: UbiquitousStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var setCallCount = 0
    private(set) var synchronizeCallCount = 0

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func set(_ data: Data, forKey key: String) {
        lock.withLock {
            storage[key] = data
            setCallCount += 1
        }
    }

    func removeObject(forKey key: String) {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    @discardableResult
    func synchronize() -> Bool {
        lock.withLock { synchronizeCallCount += 1 }
        return true
    }

    /// Seeds the store directly with a payload, bypassing
    /// `AccountCloudSyncEngine` entirely — simulates "another device
    /// already wrote this before this device's first reconcile". Doesn't
    /// count against `setCallCount` (that's meant to reflect what the
    /// engine itself wrote, not test setup).
    func seed(_ payload: AccountCloudPayload, key: String = "accounts.v1") {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        lock.withLock { storage[key] = (try? encoder.encode(payload)) ?? Data() }
    }

    /// Reads back whatever's currently stored, decoded — lets a test assert
    /// on the payload `AccountCloudSyncEngine` actually wrote.
    func currentPayload(key: String = "accounts.v1") -> AccountCloudPayload? {
        guard let data = data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AccountCloudPayload.self, from: data)
    }
}

/// A trivial in-memory `LocalAccountDirectory` — no `AppDatabase`/Keychain
/// touched. `credentialedAccountIds` stands in for "Keychain already has a
/// password for this id" (or a stored refresh token, for `.oauth2`); tests
/// seed it directly to control `insertFromCloud`'s `hasCredential` branch
/// without any real Keychain involved.
final class FakeLocalAccountDirectory: LocalAccountDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: CloudAccountSnapshot] = [:]
    private var credentialedAccountIds: Set<String> = []

    private(set) var insertedAccounts: [(snapshot: CloudAccountSnapshot, hasCredential: Bool)] = []
    private(set) var updatedAccounts: [CloudAccountSnapshot] = []
    private(set) var deletedAccountIds: [String] = []

    func seedLocalAccount(_ snapshot: CloudAccountSnapshot, hasCredential: Bool = true) {
        lock.withLock {
            accounts[snapshot.accountId] = snapshot
            if hasCredential {
                credentialedAccountIds.insert(snapshot.accountId)
            }
        }
    }

    func setCredential(_ hasCredential: Bool, forAccountId accountId: String) {
        lock.withLock {
            if hasCredential {
                credentialedAccountIds.insert(accountId)
            } else {
                credentialedAccountIds.remove(accountId)
            }
        }
    }

    func currentAccount(_ accountId: String) -> CloudAccountSnapshot? {
        lock.withLock { accounts[accountId] }
    }

    func allAccountSnapshots() async -> [CloudAccountSnapshot] {
        lock.withLock { Array(accounts.values) }
    }

    func hasCredential(accountId: String, authType: AccountAuthType) async -> Bool {
        lock.withLock { credentialedAccountIds.contains(accountId) }
    }

    func insertFromCloud(_ snapshot: CloudAccountSnapshot, hasCredential: Bool) async {
        lock.withLock {
            accounts[snapshot.accountId] = snapshot
            insertedAccounts.append((snapshot, hasCredential))
        }
    }

    func updateFromCloud(_ snapshot: CloudAccountSnapshot) async {
        lock.withLock {
            accounts[snapshot.accountId] = snapshot
            updatedAccounts.append(snapshot)
        }
    }

    func deleteLocally(accountId: String) async {
        lock.withLock {
            accounts.removeValue(forKey: accountId)
            deletedAccountIds.append(accountId)
        }
    }
}

extension CloudAccountSnapshot {
    /// A minimal, otherwise-arbitrary snapshot for tests that only care
    /// about `accountId`/`updatedAt` — every other field is filled with a
    /// fixed placeholder so call sites don't have to spell out fields the
    /// scenario under test doesn't touch.
    static func fixture(
        accountId: String = "account-1",
        displayName: String = "Test Account",
        email: String = "test@example.com",
        authType: AccountAuthType = .password,
        kind: AccountKind = .generic,
        imapHost: String = "imap.example.com",
        updatedAt: Date
    ) -> CloudAccountSnapshot {
        CloudAccountSnapshot(
            accountId: accountId,
            displayName: displayName,
            email: email,
            authType: authType,
            kind: kind,
            imapHost: imapHost,
            imapPort: 993,
            imapSecurity: .tls,
            imapAllowsInsecureTLS: false,
            imapUsername: email,
            smtpHost: nil,
            smtpPort: nil,
            smtpSecurity: nil,
            smtpAllowsInsecureTLS: false,
            smtpUsername: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
