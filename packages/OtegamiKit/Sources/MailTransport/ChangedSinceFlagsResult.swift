import OtegamiCore

/// The result of `IMAPSessionProtocol.fetchFlags(mailboxPath:changedSince:)`
/// — the flags-only counterpart of `ChangedSinceResult` (`fetchEnvelopes(
/// mailboxPath:changedSince:)`'s result): a `CONDSTORE` differential fetch
/// requesting only `FLAGS`, not the full `ENVELOPE`/`BODYSTRUCTURE`/size a
/// changed message's full envelope carries, plus (when the server also
/// supports `QRESYNC`) which previously-known UIDs it reported as vanished
/// (expunged) since `modSeq` (RFC 7162 §3.2.10's `VANISHED` response) — same
/// meaning as `ChangedSinceResult.vanishedUIDs`.
///
/// `MailboxSyncer.incrementalSync`'s CONDSTORE branch uses this instead of
/// the full-envelope overload when nothing about this mailbox needs the
/// heavier fetch (see that method's own doc comment for the exact
/// condition): most CONDSTORE passes only ever discover flag changes to
/// messages already synced locally, for which only `flagsByUID` (fed
/// through a flags-only DB update) is needed — a UID this reports that
/// isn't already known locally still needs a real, scoped envelope
/// re-fetch, since reconciling a pending-relocation placeholder (Task #120)
/// requires `messageId`, which a flags-only fetch never has.
public struct ChangedSinceFlagsResult: Sendable, Equatable {
    public var flagsByUID: [UInt32: MessageFlags]

    /// Same meaning as `ChangedSinceResult.vanishedUIDs` — `nil` means
    /// "unknown" (no `QRESYNC`), not "nothing vanished".
    public var vanishedUIDs: Set<UInt32>?

    public init(flagsByUID: [UInt32: MessageFlags], vanishedUIDs: Set<UInt32>? = nil) {
        self.flagsByUID = flagsByUID
        self.vanishedUIDs = vanishedUIDs
    }
}
