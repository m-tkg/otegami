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

    /// `seed(_:key:)`'s counterpart for `SettingsCloudSyncEngineTests` —
    /// same store, same fake, just a different payload type sharing the
    /// same KVS key namespace (`"settings.v1"` rather than `"accounts.v1"`).
    func seed(_ payload: SettingsCloudPayload, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        lock.withLock { storage[key] = (try? encoder.encode(payload)) ?? Data() }
    }

    /// `currentPayload(key:)`'s `SettingsCloudPayload` counterpart.
    func currentPayload(key: String) -> SettingsCloudPayload? {
        guard let data = data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SettingsCloudPayload.self, from: data)
    }
}

/// A trivial in-memory `LocalSettingsDirectory` — no real `UserDefaults`
/// touched, mirroring `FakeLocalAccountDirectory`'s role for the account
/// engine. `values`/`snapshot` are plain settable properties (not seeded
/// through a method) since, unlike `FakeLocalAccountDirectory`'s account
/// dictionary, a test only ever needs to set the *whole* current state up
/// front rather than incrementally build a collection.
final class FakeLocalSettingsDirectory: LocalSettingsDirectory, @unchecked Sendable {
    private let lock = NSLock()

    /// This device's current settings, as `currentValues()` should report
    /// them right now.
    var values: [String: SettingsCloudValue] {
        get { lock.withLock { _values } }
        set { lock.withLock { _values = newValue } }
    }

    /// This device's own "last synced" bookkeeping — `nil` (the default)
    /// means "never synced on this device", matching a fresh/reinstalled
    /// app with no `lastSyncedSnapshot` marker in `UserDefaults` yet.
    var snapshot: SettingsCloudPayload? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }

    private var _values: [String: SettingsCloudValue] = [:]
    private var _snapshot: SettingsCloudPayload?

    /// Every payload `apply(_:)` was actually called with, in call order —
    /// lets a test assert both *that* a pull happened and *what* it wrote.
    private(set) var appliedPayloads: [SettingsCloudPayload] = []

    func currentValues() async -> [String: SettingsCloudValue] {
        values
    }

    /// Test-only hook, awaited at the very start of `lastSyncedSnapshot()`
    /// — the point `SettingsCloudSyncEngine.reconcile()` reaches right
    /// after it has already captured `localValues` from `currentValues()`
    /// but before it decides push/pull and, if pulling, re-reads
    /// `currentValues()` a second time (`pull(_:becauseOfReason
    /// :observedLocalValues:snapshot:)`'s re-check). Pausing here lets a
    /// test land a concurrent local write (e.g. a UI toggle) in exactly the
    /// window that re-check exists to catch — see `SettingsCloudSyncEngineTests
    /// .concurrentLocalChangeDuringAPullDecisionIsNotDiscarded`. `nil` (the
    /// default) makes this a no-op, matching every other test in this file.
    var onLastSyncedSnapshot: (@Sendable () async -> Void)?

    func lastSyncedSnapshot() async -> SettingsCloudPayload? {
        if let onLastSyncedSnapshot {
            await onLastSyncedSnapshot()
        }
        return snapshot
    }

    func saveSyncedSnapshot(_ payload: SettingsCloudPayload) async {
        snapshot = payload
    }

    func apply(_ payload: SettingsCloudPayload) async {
        lock.withLock {
            _values = payload.values
            appliedPayloads.append(payload)
        }
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

    /// Test-only hook, awaited at the very start of `allAccountSnapshots()`
    /// before it reads `accounts` — lets a test suspend `reconcile()` at a
    /// controlled point (this is `reconcile()`'s one real suspension point
    /// that happens *after* it has already loaded the cloud payload) to
    /// deterministically exercise `AccountCloudSyncEngine`'s actor-
    /// reentrancy race against a concurrent `pushLocalChange`/
    /// `pushLocalDeletion` call — see `AccountCloudSyncEngineTests
    /// .concurrentPushDuringReconcileDoesNotLoseTheUpdate`. `nil` (the
    /// default) makes this method suspend nowhere, exactly as before this
    /// hook existed, so every other test in this file is unaffected.
    var onAllAccountSnapshots: (@Sendable () async -> Void)?

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
        if let onAllAccountSnapshots {
            await onAllAccountSnapshots()
        }
        return lock.withLock { Array(accounts.values) }
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

/// A single-fire async gate — `wait()` suspends until `open()` is called
/// (from anywhere), or returns immediately if `open()` already happened.
/// Used in pairs by `AccountCloudSyncEngineTests
/// .concurrentPushDuringReconcileDoesNotLoseTheUpdate` to deterministically
/// sequence "pause `reconcile()` mid-flight" / "the test now knows
/// `reconcile()` is paused there" / "let `reconcile()` resume" without any
/// timing-sensitive `Task.sleep`.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
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
