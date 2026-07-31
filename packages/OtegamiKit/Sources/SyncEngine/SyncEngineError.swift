import OtegamiStore

/// `SyncEngine`-internal failure conditions that don't fit `MailTransport
/// .MailTransportError` — that type is deliberately transport-agnostic (its
/// own doc comment: `SyncEngine` never needs to know which backend library
/// is behind it), so these three conditions used to get shoehorned into it
/// instead:
/// - `.noRoleMailbox` was `MailTransportError.mailboxNotFound(path: "(no
///   X-role mailbox known)")` at four call sites in `OpQueueProcessor`/
///   `OpQueueProcessor+SaveDraft` — a plain English description jammed into
///   `path`, a field that's supposed to carry an actual IMAP mailbox path.
/// - `.duplicateSendBlocked` was `MailTransportError.serverError
///   (underlyingDescription:)` carrying a hardcoded Japanese UI sentence —
///   the only Japanese string anywhere in `SyncEngine` (every other message
///   here is an English, log-facing `underlyingDescription`).
/// - `.pendingRelocation` was the same `MailTransportError.serverError
///   (underlyingDescription:)` shape, duplicated near-verbatim across
///   `BodyFetcher`/`SyncCoordinator` (4 call sites).
public enum SyncEngineError: Error, Sendable, Equatable {
    /// Thrown when an op needs a role mailbox (Trash/Junk/Archive/Drafts/
    /// INBOX) that isn't known locally and, for the roles that self-heal,
    /// `MailboxRoleResolver.resolveOrCreate` couldn't create one either —
    /// see that method's doc comment. The op stays queued (this is a
    /// per-op failure, not a connection-level batch abort) so a later
    /// replay can still complete it once the mailbox becomes known.
    case noRoleMailbox(role: MailboxRoleRecord)

    /// Task #124 (二重送信防止): `OpQueueProcessor.applySend`'s
    /// `claimSendStart(outboxMessageId:)` guard refused to hand this
    /// `outboxMessage` to SMTP a second time — see that method's doc
    /// comment for the crash-mid-send scenario this protects against.
    case duplicateSendBlocked

    /// Task #120: the message this call was asked to fetch a body/
    /// attachment/raw-source for is a `MessageRecord.isPendingRelocation`
    /// placeholder row with no real server UID yet — nothing a network
    /// round trip can accomplish until a later sync reconciles it onto its
    /// real UID (`AccountSyncer.reconcilePendingRelocation`). `messageId`
    /// is `nil` where the caller only has a UID to check, not an id
    /// (`SyncCoordinator.fetchAttachment`'s `messageUID <= 0` guard).
    case pendingRelocation(messageId: Int64?)
}

extension SyncEngineError: CustomStringConvertible {
    /// Log-facing, English, no PII — the same role every `MailTransportError
    /// .underlyingDescription` plays (that type's own doc comment: "callers
    /// should not pattern-match on it"). See `userFacingMessage` for the one
    /// case (`.duplicateSendBlocked`) that also has an already-shipped UI
    /// string to preserve.
    public var description: String {
        switch self {
        case .noRoleMailbox(let role):
            "no \(Self.displayName(for: role))-role mailbox known"
        case .duplicateSendBlocked:
            "duplicate send blocked (Task #124 idempotency guard — outboxMessage already claimed by another send attempt)"
        case .pendingRelocation(let messageId):
            if let messageId {
                "message \(messageId) is pending local relocation; no server UID yet"
            } else {
                "message is pending local relocation; no server UID yet"
            }
        }
    }

    /// Matches the casing each of the four call sites this consolidates
    /// used in its own literal string (`"Trash"`/`"Junk"`/`"Archive"`/
    /// `"Drafts"`, and `"INBOX"` for `.unarchive`'s destination) rather
    /// than `MailboxRoleRecord.rawValue`'s lowercase (`"trash"`, ...).
    private static func displayName(for role: MailboxRoleRecord) -> String {
        switch role {
        case .inbox: "INBOX"
        case .trash: "Trash"
        case .junk: "Junk"
        case .archive: "Archive"
        case .drafts: "Drafts"
        case .all, .flagged, .sent, .none: role.rawValue
        }
    }
}

extension SyncEngineError {
    /// The text `OpQueueProcessor.recordFailure` puts in `OpQueueRecord
    /// .lastError`, which `FailedOperationsView`'s secondary caption shows
    /// verbatim (`apps/Otegami/Sources/Features/Sidebar
    /// /FailedOperationsView.swift`). Kept alongside the case itself
    /// (rather than pushed out to that app-target view, which would need
    /// its own `SyncEngineError` switch just to reproduce one already-
    /// shipped sentence) so removing the Japanese string from the *thrown*
    /// error type doesn't also change what a user actually sees for the
    /// one case (`.duplicateSendBlocked`) that had real UI copy, not just
    /// a technical description. `.noRoleMailbox`/`.pendingRelocation` never
    /// had bespoke UI copy — both were already just `description`-shaped
    /// technical strings shown in that same caption — so they fall back to
    /// `description` unchanged.
    public var userFacingMessage: String {
        switch self {
        case .duplicateSendBlocked:
            "送信を開始済みのため再送信をスキップしました(二重送信防止)。「同期エラー」から内容を確認し、必要なら手動で再送してください。"
        case .noRoleMailbox, .pendingRelocation:
            description
        }
    }
}
