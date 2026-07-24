import Foundation

/// A deletion marker: `accountId` was removed on some device at
/// `deletedAt`. Kept in the payload (rather than just removing the account
/// from `accounts` and calling it done) so every other device's next
/// `reconcile()` can tell "was never synced here yet" apart from "was
/// synced here, then deleted elsewhere" — without a tombstone, a device
/// that only pulls the payload *after* a deletion would see nothing at all
/// for that id and have no way to know it should delete its own local
/// copy rather than (wrongly) treat it as "never existed, so push mine".
public struct AccountTombstone: Codable, Equatable, Sendable {
    public var accountId: String
    public var deletedAt: Date

    public init(accountId: String, deletedAt: Date) {
        self.accountId = accountId
        self.deletedAt = deletedAt
    }
}

/// The single JSON blob stored under `AccountCloudSyncEngine`'s
/// `"accounts.v1"` key. One key for the whole account list (rather than one
/// key per account) per the plan: `NSUbiquitousKeyValueStore` caps *total*
/// storage at 1MB and any single key's value at 64KB, and a single small
/// JSON document for every account this app will ever plausibly manage
/// (dozens, not thousands) fits comfortably within either limit — see
/// `AccountCloudSyncEngine.maxPayloadBytes`'s doc comment for the guard
/// that keeps a runaway payload from ever actually testing that limit.
public struct AccountCloudPayload: Codable, Equatable, Sendable {
    public var accounts: [CloudAccountSnapshot]
    public var tombstones: [AccountTombstone]

    public init(accounts: [CloudAccountSnapshot] = [], tombstones: [AccountTombstone] = []) {
        self.accounts = accounts
        self.tombstones = tombstones
    }
}
