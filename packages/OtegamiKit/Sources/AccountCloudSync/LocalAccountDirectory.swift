import Foundation
import OtegamiStore

/// The local (GRDB + Keychain) side of account-cloud reconciliation,
/// abstracted so `AccountCloudSyncEngine` never touches `AppDatabase`/
/// `KeychainCredentialStore` directly and `AccountCloudSyncEngineTests` can
/// drive it against an in-memory fake instead. The production conformer
/// (`apps/Otegami/Sources/Support/CloudAccountDirectory.swift`) also owns
/// starting the first sync / stopping `IDLE` / registering-unregistering
/// push watches for an account this reconcile pass touched — deliberately
/// not modeled here as separate protocol requirements/callbacks (see that
/// type's doc comment for why): every requirement below is a plain data
/// operation, which keeps this protocol (and therefore
/// `AccountCloudSyncEngine`) simple to reason about and to fake.
public protocol LocalAccountDirectory: Sendable {
    /// Every account this device currently knows about, as of right now.
    func allAccountSnapshots() async -> [CloudAccountSnapshot]

    /// Whether a usable credential already exists locally for `accountId`
    /// (a Keychain password for `.password`, a stored refresh token for
    /// `.oauth2`) — decides whether a cloud-discovered account can start
    /// syncing immediately or needs to wait for iCloud Keychain to catch up
    /// (`insertFromCloud`'s `hasCredential` parameter). `kind` is needed
    /// alongside `authType` for an `.oauth2` account (Task #116 第2段):
    /// which provider's `TokenStore` to check for a stored refresh token
    /// (`.gmail` vs `.microsoft`) isn't decidable from `authType` alone once
    /// more than one OAuth provider exists.
    func hasCredential(accountId: String, authType: AccountAuthType, kind: AccountKind) async -> Bool

    /// A cloud-only account (present in the payload, not found locally, no
    /// tombstone for it) needs to be created locally.
    func insertFromCloud(_ snapshot: CloudAccountSnapshot, hasCredential: Bool) async

    /// Both a local and a cloud copy of this account exist, and the cloud
    /// copy's `updatedAt` won the last-writer-wins comparison — overwrite
    /// the local row's synced metadata (never its credential).
    func updateFromCloud(_ snapshot: CloudAccountSnapshot) async

    /// A tombstone says `accountId` was deleted on another device — remove
    /// it (and everything that cascades from it) locally too.
    func deleteLocally(accountId: String) async
}
