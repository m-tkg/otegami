/// The result of `IMAPSessionProtocol.fetchEnvelopes(mailboxPath:changedSince:)`
/// — a `CONDSTORE` differential fetch (RFC 7162 §3.1), plus (when the server
/// also supports `QRESYNC`) which previously-known UIDs it reported as
/// vanished (expunged) since `modSeq` (RFC 7162 §3.2.10's `VANISHED`
/// response).
///
/// Added for Task #79 (実機バグ: Web でアーカイブ済みのメールが受信トレイに残り
/// 続ける): `CONDSTORE` alone can only ever report new/changed messages —
/// there is no way to distinguish "unchanged" from "expunged" without
/// `QRESYNC`'s `VANISHED` reporting. Most servers, including Gmail
/// (confirmed: Gmail's IMAP `CAPABILITY` advertises `CONDSTORE` but never
/// `QRESYNC`), don't support it — `vanishedUIDs` is `nil` in that case, and
/// callers must fall back to an independent UID-existence check (e.g.
/// `IMAPSessionProtocol.searchExistingUIDs`) to learn about server-side
/// deletions.
public struct ChangedSinceResult: Sendable, Equatable {
    public var envelopes: [FetchedEnvelope]

    /// UIDs the server reported as vanished (expunged) since `modSeq`, via
    /// `QRESYNC`'s `VANISHED` response. `nil` means "unknown" (the server
    /// doesn't support `QRESYNC`, or `QRESYNC` isn't active for this
    /// session) — *not* "nothing vanished". A non-`nil` value (even an
    /// empty set) means the server actively participated in `QRESYNC` for
    /// this fetch and is authoritative: nothing else vanished this round.
    public var vanishedUIDs: Set<UInt32>?

    public init(envelopes: [FetchedEnvelope], vanishedUIDs: Set<UInt32>? = nil) {
        self.envelopes = envelopes
        self.vanishedUIDs = vanishedUIDs
    }
}
