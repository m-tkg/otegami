import OtegamiCore

/// How a `STORE` command should combine the given flags with a message's
/// existing flags (RFC 3501 §6.4.6).
public enum FlagOp: Sendable, Codable, Hashable {
    /// `+FLAGS` — add the given flags, leaving others untouched.
    case add
    /// `-FLAGS` — remove the given flags, leaving others untouched.
    case remove
    /// `FLAGS` — replace the message's flags with exactly the given set.
    case replace
}

/// A single flag mutation to apply to a set of UIDs via `store(...)`.
///
/// `uidValidityGeneration` lets `SyncEngine`'s `opQueue` replay be
/// idempotent across a mailbox recreation: if the mailbox's `uidValidity`
/// has changed since the change was enqueued, the adapter/caller should
/// treat the change as stale (the UIDs it refers to no longer mean the same
/// messages) rather than apply it.
public struct FlagChange: Sendable, Codable, Hashable {
    public var uids: UIDSet
    public var op: FlagOp
    public var flags: MessageFlags
    public var uidValidity: UInt32

    public init(uids: UIDSet, op: FlagOp, flags: MessageFlags, uidValidity: UInt32) {
        self.uids = uids
        self.op = op
        self.flags = flags
        self.uidValidity = uidValidity
    }
}
