/// A range of IMAP UIDs (RFC 3501 §9, `uid-set`), used to scope `UID FETCH`/
/// `UID STORE` requests. Modeled as a closed range with an "open-ended"
/// sentinel rather than raw `Range<UInt32>` because IMAP itself uses `*` to
/// mean "the largest UID in the mailbox, whatever that turns out to be".
public struct UIDRange: Sendable, Codable, Hashable {
    public var lowerBound: UInt32

    /// `nil` represents IMAP's `*` (open-ended upper bound).
    public var upperBound: UInt32?

    public init(lowerBound: UInt32, upperBound: UInt32?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// A single UID.
    public static func uid(_ uid: UInt32) -> UIDRange {
        UIDRange(lowerBound: uid, upperBound: uid)
    }

    /// `lowerBound:*` — everything from `lowerBound` onward. Used for
    /// "fetch new mail since I last synced" (`UID FETCH uidNext:*`).
    public static func from(_ lowerBound: UInt32) -> UIDRange {
        UIDRange(lowerBound: lowerBound, upperBound: nil)
    }

    /// `1:*` — the entire mailbox.
    public static let all = UIDRange(lowerBound: 1, upperBound: nil)
}

/// A discrete, possibly non-contiguous set of UIDs, used where a range
/// isn't expressive enough (e.g. the exact UIDs seen in a `FETCH` response
/// batch, before issuing a follow-up `UID STORE`).
public struct UIDSet: Sendable, Codable, Hashable {
    public var uids: [UInt32]

    public init(_ uids: [UInt32]) {
        self.uids = uids
    }
}
