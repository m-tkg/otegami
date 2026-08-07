import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// `MailboxQuery.roleScopedMailboxPaths` is the sync-side mirror of the scope
/// `ThreadQuery.unifiedInboxRequest` defines for a `.unifiedRole` view. The
/// two used to disagree on Gmail: the display query mapped `.archive` to All
/// Mail via `MailboxRoleRecord.gmailArchiveQueryRole`, the sync side matched
/// `role` literally and so found nothing, and its caller fell back to syncing
/// every mailbox on the account. These tests pin the mapping on the side that
/// `make test` can check.
@Suite("MailboxQuery.roleScopedMailboxPaths")
struct RoleScopedMailboxPathsTests {
    private func makeDatabase(kind: AccountKind) throws -> (database: AppDatabase, accountId: String) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "t@otegami.test", authType: .password, kind: kind,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@otegami.test"
        )
        try database.dbWriter.write { db in try account.insert(db) }
        return (database, account.id)
    }

    private func insertMailbox(
        accountId: String, path: String, role: MailboxRoleRecord, isHidden: Bool = false,
        database: AppDatabase
    ) throws {
        try database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: accountId, path: path, displayPath: path, role: role)
            mailbox.isHidden = isHidden
            try mailbox.insert(db)
        }
    }

    private func paths(
        accountId: String, kind: AccountKind, role: MailboxRoleRecord, database: AppDatabase
    ) throws -> Set<String> {
        try database.dbWriter.read { db in
            try MailboxQuery.roleScopedMailboxPaths(accountId: accountId, accountKind: kind, role: role, db: db)
        }
    }

    @Test("a Gmail account's .archive scope maps to All Mail, matching the display query")
    func gmailArchiveMapsToAllMail() throws {
        let (database, accountId) = try makeDatabase(kind: .gmail)
        try insertMailbox(accountId: accountId, path: "INBOX", role: .inbox, database: database)
        try insertMailbox(accountId: accountId, path: "[Gmail]/All Mail", role: .all, database: database)

        #expect(try paths(accountId: accountId, kind: .gmail, role: .archive, database: database) == ["[Gmail]/All Mail"])
    }

    @Test("every other role is unmapped on Gmail too")
    func gmailNonArchiveRolesAreUnmapped() throws {
        let (database, accountId) = try makeDatabase(kind: .gmail)
        try insertMailbox(accountId: accountId, path: "INBOX", role: .inbox, database: database)
        try insertMailbox(accountId: accountId, path: "[Gmail]/All Mail", role: .all, database: database)
        try insertMailbox(accountId: accountId, path: "[Gmail]/Sent Mail", role: .sent, database: database)

        #expect(try paths(accountId: accountId, kind: .gmail, role: .inbox, database: database) == ["INBOX"])
        #expect(try paths(accountId: accountId, kind: .gmail, role: .sent, database: database) == ["[Gmail]/Sent Mail"])
    }

    @Test("a non-Gmail account's .archive scope is its Archive-role mailbox, unmapped")
    func nonGmailArchiveIsUnmapped() throws {
        let (database, accountId) = try makeDatabase(kind: .generic)
        try insertMailbox(accountId: accountId, path: "INBOX", role: .inbox, database: database)
        try insertMailbox(accountId: accountId, path: "Archive", role: .archive, database: database)

        #expect(try paths(accountId: accountId, kind: .generic, role: .archive, database: database) == ["Archive"])
    }

    @Test("a non-Gmail account's .all scope is every non-hidden mailbox (Task #141 parity)")
    func nonGmailAllMatchesEveryMailbox() throws {
        let (database, accountId) = try makeDatabase(kind: .generic)
        try insertMailbox(accountId: accountId, path: "INBOX", role: .inbox, database: database)
        try insertMailbox(accountId: accountId, path: "Archive", role: .archive, database: database)
        try insertMailbox(accountId: accountId, path: "Projects", role: .none, database: database)

        #expect(
            try paths(accountId: accountId, kind: .generic, role: .all, database: database)
                == ["INBOX", "Archive", "Projects"]
        )
    }

    @Test("hidden mailboxes are excluded, matching the display query's isHidden = 0 condition")
    func hiddenMailboxesAreExcluded() throws {
        let (database, accountId) = try makeDatabase(kind: .gmail)
        try insertMailbox(accountId: accountId, path: "[Gmail]/All Mail", role: .all, isHidden: true, database: database)

        #expect(try paths(accountId: accountId, kind: .gmail, role: .archive, database: database).isEmpty)
    }

    @Test("an account with no matching mailbox returns an empty set — the caller's own fallback signal")
    func noMatchReturnsEmpty() throws {
        let (database, accountId) = try makeDatabase(kind: .generic)
        try insertMailbox(accountId: accountId, path: "INBOX", role: .inbox, database: database)

        #expect(try paths(accountId: accountId, kind: .generic, role: .archive, database: database).isEmpty)
    }

    @Test("another account's mailboxes never leak in")
    func otherAccountsAreExcluded() throws {
        let (database, accountId) = try makeDatabase(kind: .gmail)
        let other = AccountRecord(
            displayName: "Other", email: "o@otegami.test", authType: .oauth2, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "o@otegami.test"
        )
        try database.dbWriter.write { db in try other.insert(db) }
        try insertMailbox(accountId: accountId, path: "[Gmail]/All Mail", role: .all, database: database)
        try insertMailbox(accountId: other.id, path: "[Gmail]/All Mail", role: .all, database: database)

        let result = try database.dbWriter.read { db in
            try MailboxQuery.roleScopedMailboxPaths(
                accountId: accountId, accountKind: .gmail, role: .archive, db: db
            )
        }
        #expect(result == ["[Gmail]/All Mail"])
    }
}
