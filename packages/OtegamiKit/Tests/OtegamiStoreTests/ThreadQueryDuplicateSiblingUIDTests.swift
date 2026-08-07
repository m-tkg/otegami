import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// `ThreadQuery.duplicateSiblingUIDs(ofUIDs:in:siblingMailboxId:db:)` —
/// 実機報告 (2026-08-07)「メールの unpin が反映されない」の2度目の修正で
/// 追加した、同期ガード (`SyncEngine.PendingOpTargets`) が兄弟行まで
/// 守るための UID 解決。
///
/// この判定は `deduplicate(_:db:)` の `identityKey` を **SQL へ写した**
/// もので、型では守れない。特に `gmailMessageId` の有無で同一性キーが
/// 変わる非対称 (`gmail:` 優先なので、片方だけ Gmail ID を持つ行同士は
/// 重複ではない) を取り違えると、無関係な行までガードしてサーバー状態が
/// 永久に入らなくなる — そこを個別に固定する。
@Suite("ThreadQuery.duplicateSiblingUIDs")
struct ThreadQueryDuplicateSiblingUIDTests {
    private struct Fixture {
        var accountId: String
        var inboxId: Int64
        var allMailId: Int64
    }

    private func makeFixture(db: Database) throws -> Fixture {
        let account = AccountRecord(
            displayName: "Gmail", email: "sib@otegami.test", authType: .password, kind: .gmail,
            imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, imapUsername: "sib@otegami.test"
        )
        try account.insert(db)
        var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox, uidValidity: 1)
        try inbox.insert(db)
        var allMail = MailboxRecord(accountId: account.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all, uidValidity: 1)
        try allMail.insert(db)
        return Fixture(accountId: account.id, inboxId: try #require(inbox.id), allMailId: try #require(allMail.id))
    }

    private func makeThread(accountId: String, subject: String, db: Database) throws -> Int64 {
        var thread = ThreadRecord(accountId: accountId, normalizedSubject: subject)
        try thread.insert(db)
        return try #require(thread.id)
    }

    @discardableResult
    private func insertMessage(
        mailboxId: Int64,
        uid: Int64,
        threadId: Int64?,
        messageId: String?,
        gmailMessageId: Int64?,
        db: Database
    ) throws -> Int64 {
        var message = MessageRecord(
            mailboxId: mailboxId, uid: uid,
            messageId: messageId,
            subject: "件名", normalizedSubject: "件名",
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            gmailMessageId: gmailMessageId,
            threadId: threadId
        )
        try message.insert(db)
        return try #require(message.id)
    }

    @Test("gmailMessageId が一致する行を兄弟として返す")
    func matchesByGmailMessageId() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "重複", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings == [20])
    }

    @Test("逆方向 (All Mail → INBOX) も同じように引ける")
    func matchesInBothDirections() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "重複", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [20], in: fixture.allMailId, siblingMailboxId: fixture.inboxId, db: db
            )
        }
        #expect(siblings == [10])
    }

    /// `identityKey` は `gmailMessageId` を優先するので、片方だけ Gmail ID
    /// を持つ行同士は**キーが違う** = 重複ではない。SQL 側でこの非対称を
    /// 取り違えると、無関係な行をガードしてしまう。
    @Test("片方だけ gmailMessageId を持つ行は兄弟にしない")
    func gmailIdAsymmetryIsRespected() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "非対称", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            // 同じ Message-ID だが Gmail ID を持たない → `identityKey` は
            // `msgid:` になり、`gmail:4242` とは一致しない。
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: nil, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }

    @Test("どちらも gmailMessageId を持たないなら Message-ID で一致させる")
    func matchesByMessageIdWhenNeitherHasGmailId() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "msgid", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: nil, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: nil, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings == [20])
    }

    @Test("識別子がどちらも無い行は何とも重複扱いしない")
    func rowsWithoutAnyIdentityAreNeverSiblings() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "無識別", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: nil, gmailMessageId: nil, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadId, messageId: nil, gmailMessageId: nil, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }

    /// `duplicateSiblings(of:db:)` と同じ判断 — RFC 822 `Message-ID` は
    /// 転送等で別スレッドの行と一致しうるので、スレッドを跨いでは畳まない。
    @Test("同じ Message-ID でも別スレッドなら兄弟にしない")
    func doesNotCrossThreads() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadA = try makeThread(accountId: fixture.accountId, subject: "A", db: db)
            let threadB = try makeThread(accountId: fixture.accountId, subject: "B", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadA, messageId: "<a@otegami.test>", gmailMessageId: nil, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: threadB, messageId: "<a@otegami.test>", gmailMessageId: nil, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }

    @Test("スレッド未割り当ての行は対象外")
    func unthreadedRowsAreIgnored() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: nil, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            try insertMessage(mailboxId: fixture.allMailId, uid: 20, threadId: nil, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }

    @Test("複数 UID をまとめて解決できる")
    func resolvesMultipleUIDsAtOnce() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            for (index, gmailId) in [4242, 4343].enumerated() {
                let threadId = try makeThread(accountId: fixture.accountId, subject: "重複\(index)", db: db)
                try insertMessage(mailboxId: fixture.inboxId, uid: Int64(10 + index), threadId: threadId, messageId: "<\(index)@otegami.test>", gmailMessageId: Int64(gmailId), db: db)
                try insertMessage(mailboxId: fixture.allMailId, uid: Int64(20 + index), threadId: threadId, messageId: "<\(index)@otegami.test>", gmailMessageId: Int64(gmailId), db: db)
            }
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10, 11], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings == [20, 21])
    }

    @Test("同じメールボックスを指定したら空 (自分自身は兄弟ではない)")
    func sameMailboxYieldsNothing() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            let threadId = try makeThread(accountId: fixture.accountId, subject: "重複", db: db)
            try insertMessage(mailboxId: fixture.inboxId, uid: 10, threadId: threadId, messageId: "<a@otegami.test>", gmailMessageId: 4242, db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [10], in: fixture.inboxId, siblingMailboxId: fixture.inboxId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }

    @Test("UID 指定が空なら空")
    func emptyInputYieldsEmpty() throws {
        let database = try AppDatabase.makeInMemory()
        let siblings = try database.dbWriter.write { db -> Set<Int64> in
            let fixture = try makeFixture(db: db)
            return try ThreadQuery.duplicateSiblingUIDs(
                ofUIDs: [], in: fixture.inboxId, siblingMailboxId: fixture.allMailId, db: db
            )
        }
        #expect(siblings.isEmpty)
    }
}
