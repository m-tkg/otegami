import Foundation
import GRDB
import MailTransport
import OtegamiStore

/// Resolves an account's well-known role mailboxes (INBOX/Trash/Junk/
/// Archive/Sent/Drafts), and — for the roles that support it — self-heals
/// by `CREATE`-ing one server-side when none is known locally yet.
///
/// Extracted from `OpQueueProcessor`, which used to carry six
/// byte-for-byte-identical-except-for-role lookup functions
/// (`inboxMailbox`/`trashMailbox`/`junkMailbox`/`archiveMailbox`/
/// `sentMailbox`/`draftsMailbox`) plus four byte-for-byte-identical-except-
/// for-role-name self-healing functions (`resolveOrCreateTrashMailbox`/
/// `resolveOrCreateJunkMailbox`/`resolveOrCreateArchiveMailbox`/
/// `resolveOrCreateDraftsMailbox`). Kept as a plain `enum` namespace (no
/// stored state) rather than a type instance, since every operation here is
/// a pure function of its arguments.
enum MailboxRoleResolver {
    /// Plain lookup: this account's mailbox for `role`, or `nil` if none is
    /// known locally yet. Used for every role, including `.inbox`/`.sent`,
    /// which never self-heal (see `resolveOrCreate(role:accountId:session:
    /// database:)`'s doc comment for why only some roles do).
    static func mailbox(role: MailboxRoleRecord, accountId: String, database: AppDatabase) async throws -> MailboxRecord? {
        try await database.dbWriter.read { db in
            try MailboxRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("role") == role.rawValue)
                .fetchOne(db)
        }
    }

    /// The mailbox name `resolveOrCreate(role:accountId:session:database:)`
    /// asks the server to `CREATE` when no mailbox of that role is known —
    /// plain flat names, no parent, the same names a server without
    /// `SPECIAL-USE`/an existing mailbox of that name would already be
    /// missing. There's no reliable way to infer a provider-specific
    /// hierarchy (e.g. Gmail's `[Gmail]/Trash`) from IMAP alone for an
    /// account this code path has, by construction, never seen a mailbox of
    /// this role from.
    ///
    /// `nil` for any role this type doesn't self-heal (`.inbox`/`.sent`/
    /// everything else) — see `resolveOrCreate`'s doc comment for why only
    /// Trash/Junk/Archive/Drafts do.
    static func mailboxNameToCreate(for role: MailboxRoleRecord) -> String? {
        switch role {
        case .trash: "Trash"
        case .junk: "Junk"
        case .archive: "Archive"
        case .drafts: "Drafts"
        default: nil
        }
    }

    /// Resolves this account's mailbox for `role`, self-healing by
    /// `CREATE`-ing one named `mailboxNameToCreate(for: role)` when none is
    /// known yet (`docs/roadmap.md`: "Trash メールボックスが存在しないサーバ
    /// での Trash 自動作成", and D8's identical requirement for Junk). Only
    /// meaningful for `role`s `mailboxNameToCreate(for:)` returns a name
    /// for — Trash/Junk/Archive/Drafts. **`.inbox`/`.sent` deliberately
    /// never reach the `CREATE` attempt**: every IMAP account has an INBOX
    /// by construction, and this app's own initial sync always discovers
    /// and upserts both before any op could possibly need to resolve one
    /// (`OpQueueProcessor.apply`'s `.unarchive`/`.send` cases treat a `nil`
    /// INBOX/Sent lookup as "first sync hasn't completed yet", not
    /// "self-heal it") — passing `.inbox`/`.sent` here just returns
    /// whatever `mailbox(role:accountId:database:)` alone would have, since
    /// `mailboxNameToCreate(for:)` is `nil` for them.
    ///
    /// Returns `nil` when there's still no usable mailbox for `role` after
    /// a self-heal attempt (the `CREATE` itself failed — permission denied,
    /// a naming conflict, offline, ...) — callers treat this exactly like
    /// "no mailbox of this role known", their existing `mailboxNotFound`
    /// retry path unchanged. An account whose server already advertises a
    /// mailbox of this role never reaches the `CREATE` attempt at all (the
    /// `mailbox(role:accountId:database:)` lookup above already found it).
    static func resolveOrCreate(
        role: MailboxRoleRecord,
        accountId: String,
        session: any IMAPSessionProtocol,
        database: AppDatabase
    ) async throws -> MailboxRecord? {
        if let existing = try await mailbox(role: role, accountId: accountId, database: database) {
            return existing
        }
        guard let nameToCreate = mailboxNameToCreate(for: role) else { return nil }

        do {
            try await session.createMailbox(path: nameToCreate)
        } catch {
            return nil
        }

        // Re-list rather than assuming the just-created path/role: some
        // servers report a different `SPECIAL-USE` attribute or display
        // name for a freshly created mailbox than the literal string this
        // code asked to `CREATE`, and `MailboxInfo.role` (not the raw path)
        // is the source of truth `mailbox(role:accountId:database:)`'s
        // query above also relies on.
        let mailboxInfos = try await session.listMailboxes()
        guard let created = mailboxInfos.first(where: { info in
            info.role.rawValue == role.rawValue || info.path.caseInsensitiveCompare(nameToCreate) == .orderedSame
        }) else {
            return nil
        }

        return try await upsertCreatedMailbox(accountId: accountId, info: created, database: database)
    }

    /// Inserts (or, on a name collision with something already upserted by
    /// a concurrent sync pass, updates) the mailbox `resolveOrCreate`
    /// just created — the on-conflict column list mirrors `AccountSyncer
    /// .upsertMailboxes`'s (sync-state columns like `uidValidity` must
    /// survive if a race means a row already exists here), duplicated
    /// rather than shared since it's a two-line list and pulling in
    /// `AccountSyncer` for it isn't worth the coupling.
    private static func upsertCreatedMailbox(accountId: String, info: MailboxInfo, database: AppDatabase) async throws -> MailboxRecord {
        try await database.dbWriter.write { db in
            var record = MailboxRecord(
                accountId: accountId,
                path: info.path,
                displayPath: info.displayPath,
                delimiter: info.delimiter,
                role: MailboxRoleRecord(info.role),
                roleIsAuthoritative: info.roleIsAuthoritative,
                attributesRaw: info.attributes.rawValue
            )
            return try record.upsertAndFetch(db, onConflict: ["accountId", "path"]) { _ in
                [
                    Column("uidValidity").noOverwrite,
                    Column("uidNext").noOverwrite,
                    Column("highestModSeq").noOverwrite,
                    Column("messageCount").noOverwrite,
                    Column("lastSyncedAt").noOverwrite,
                ]
            }
        }
    }
}
