import Foundation
import GRDB
import Testing
@testable import OtegamiStore

/// 実機報告「iCloud のメールをアーカイブしたのに受信箱に残る」の根本原因
/// (Archive/Trash/Junk が一度も差分同期を経ないまま放置されうる) への対応
/// として追加した `StaleNonInboxMailboxQuery` のテスト。
@Suite("StaleNonInboxMailboxQuery selects mailboxes overdue for reconciliation")
struct StaleNonInboxMailboxQueryTests {
    private func makeAccount(email: String, db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: email, email: email, authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: email
        )
        try account.insert(db)
        return account
    }

    @discardableResult
    private func makeMailbox(
        accountId: String,
        path: String,
        role: MailboxRoleRecord,
        lastSyncedAt: Date?,
        db: Database
    ) throws -> Int64 {
        var mailbox = MailboxRecord(
            accountId: accountId, path: path, displayPath: path, role: role,
            lastSyncedAt: lastSyncedAt
        )
        mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
        return try #require(mailbox.id)
    }

    @Test("一度も同期されていない Archive/Trash/Junk は対象になる")
    func neverSyncedMailboxesAreStale() throws {
        let database = try AppDatabase.makeInMemory()
        let paths = try database.dbWriter.write { db -> [String] in
            let account = try makeAccount(email: "a@otegami.test", db: db)
            try makeMailbox(accountId: account.id, path: "Archive", role: .archive, lastSyncedAt: nil, db: db)
            try makeMailbox(accountId: account.id, path: "Trash", role: .trash, lastSyncedAt: nil, db: db)
            return try StaleNonInboxMailboxQuery.stalePaths(accountId: account.id, db: db)
        }
        #expect(Set(paths) == ["Archive", "Trash"])
    }

    @Test("しきい値内に同期済みのメールボックスは対象外")
    func recentlySyncedMailboxesAreExcluded() throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let paths = try database.dbWriter.write { db -> [String] in
            let account = try makeAccount(email: "a@otegami.test", db: db)
            try makeMailbox(
                accountId: account.id, path: "Archive", role: .archive,
                lastSyncedAt: now.addingTimeInterval(-60 * 60), db: db
            )
            return try StaleNonInboxMailboxQuery.stalePaths(accountId: account.id, now: now, db: db)
        }
        #expect(paths.isEmpty)
    }

    @Test("しきい値を超えて未同期のメールボックスは対象になる")
    func longUnsyncedMailboxesAreStale() throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let paths = try database.dbWriter.write { db -> [String] in
            let account = try makeAccount(email: "a@otegami.test", db: db)
            try makeMailbox(
                accountId: account.id, path: "Archive", role: .archive,
                lastSyncedAt: now.addingTimeInterval(-25 * 60 * 60), db: db
            )
            return try StaleNonInboxMailboxQuery.stalePaths(accountId: account.id, now: now, db: db)
        }
        #expect(paths == ["Archive"])
    }

    @Test("INBOX/Sent/Drafts など対象ロール外は含まれない")
    func nonTargetRolesAreExcluded() throws {
        let database = try AppDatabase.makeInMemory()
        let paths = try database.dbWriter.write { db -> [String] in
            let account = try makeAccount(email: "a@otegami.test", db: db)
            try makeMailbox(accountId: account.id, path: "INBOX", role: .inbox, lastSyncedAt: nil, db: db)
            try makeMailbox(accountId: account.id, path: "Sent", role: .sent, lastSyncedAt: nil, db: db)
            try makeMailbox(accountId: account.id, path: "Drafts", role: .drafts, lastSyncedAt: nil, db: db)
            return try StaleNonInboxMailboxQuery.stalePaths(accountId: account.id, db: db)
        }
        #expect(paths.isEmpty)
    }

    @Test("他アカウントのメールボックスは含まれない")
    func otherAccountsMailboxesAreExcluded() throws {
        let database = try AppDatabase.makeInMemory()
        let paths = try database.dbWriter.write { db -> [String] in
            let accountA = try makeAccount(email: "a@otegami.test", db: db)
            let accountB = try makeAccount(email: "b@otegami.test", db: db)
            try makeMailbox(accountId: accountA.id, path: "Archive", role: .archive, lastSyncedAt: nil, db: db)
            try makeMailbox(accountId: accountB.id, path: "Archive", role: .archive, lastSyncedAt: nil, db: db)
            return try StaleNonInboxMailboxQuery.stalePaths(accountId: accountA.id, db: db)
        }
        #expect(paths == ["Archive"])
    }
}
