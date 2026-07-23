import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("ThreadAssigner")
struct ThreadAssignerTests {
    private func makeDatabaseWithInbox() throws -> (database: AppDatabase, accountId: String, mailboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        let mailboxId = try database.dbWriter.write { db -> Int64 in
            try account.insert(db)
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try mailbox.insert(db)
            return mailbox.id!
        }
        return (database, account.id, mailboxId)
    }

    @discardableResult
    private func insertMessage(
        mailboxId: Int64,
        uid: Int64,
        messageId: String?,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String,
        from: [EmailAddress],
        to: [EmailAddress],
        date: Date,
        seen: Bool = false,
        db: Database
    ) throws -> Int64 {
        var message = MessageRecord(
            mailboxId: mailboxId,
            uid: uid,
            messageId: messageId,
            inReplyTo: inReplyTo,
            subject: subject,
            normalizedSubject: SubjectNormalizer.normalize(subject),
            fromAddresses: from,
            toAddresses: to,
            date: date,
            internalDate: date,
            flagsRaw: seen ? MessageFlags.seen.rawValue : 0
        )
        try message.insert(db)
        let messageRowId = message.id!
        for (index, reference) in references.enumerated() {
            var ref = MessageReferenceRecord(messageId: messageRowId, referenceValue: reference, position: index)
            try ref.insert(db)
        }
        return messageRowId
    }

    // MARK: References-based threading

    @Test("a References chain of three messages ends up in one thread")
    func referencesChainFormsOneThread() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let test1 = EmailAddress(address: "test1@otegami.test")
        let test2 = EmailAddress(address: "test2@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try database.dbWriter.write { db in
            let m1 = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<seed-9@otegami.test>",
                subject: "来週のランチ", from: [test2], to: [test1], date: base, db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m1, accountId: accountId, db: db)

            let m2 = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<seed-10@otegami.test>",
                inReplyTo: "<seed-9@otegami.test>", references: ["<seed-9@otegami.test>"],
                subject: "Re: 来週のランチ", from: [test1], to: [test2], date: base.addingTimeInterval(3600), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m2, accountId: accountId, db: db)

            let m3 = try insertMessage(
                mailboxId: mailboxId, uid: 3, messageId: "<seed-11@otegami.test>",
                inReplyTo: "<seed-10@otegami.test>",
                references: ["<seed-9@otegami.test>", "<seed-10@otegami.test>"],
                subject: "Re: 来週のランチ", from: [test2], to: [test1], date: base.addingTimeInterval(7200), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m3, accountId: accountId, db: db)
        }

        let (threads, messages) = try database.dbWriter.read { db in
            (try ThreadRecord.fetchAll(db), try MessageRecord.fetchAll(db))
        }
        #expect(threads.count == 1)
        let thread = threads[0]
        #expect(thread.messageCount == 3)
        #expect(thread.unreadCount == 3)
        #expect(messages.allSatisfy { $0.threadId == thread.id })
        #expect(thread.lastMessageDate == base.addingTimeInterval(7200))
    }

    @Test("a References break (missing In-Reply-To/References) starts a separate thread")
    func referencesBreakStartsNewThread() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let aiko = EmailAddress(address: "aiko@otegami.test")
        let test1 = EmailAddress(address: "test1@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try database.dbWriter.write { db in
            let m1 = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<a@x>",
                subject: "件名A", from: [aiko], to: [test1], date: base, db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m1, accountId: accountId, db: db)

            // A totally unrelated message: different subject, no
            // references, far outside any fallback window.
            let m2 = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<b@x>",
                subject: "件名B", from: [aiko], to: [test1], date: base.addingTimeInterval(30 * 24 * 3600), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m2, accountId: accountId, db: db)
        }

        let threads = try database.dbWriter.read { db in try ThreadRecord.fetchAll(db) }
        #expect(threads.count == 2)
        #expect(threads.allSatisfy { $0.messageCount == 1 })
    }

    // MARK: Subject fallback (no References header at all)

    @Test("subject fallback joins a same-subject reply with no References/In-Reply-To, including a Japanese Re: prefix")
    func subjectFallbackJoinsWithoutReferences() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let aiko = EmailAddress(address: "aiko@otegami.test")
        let test1 = EmailAddress(address: "test1@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try database.dbWriter.write { db in
            let m1 = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<orig@x>",
                subject: "来月の懇親会について", from: [aiko], to: [test1], date: base, db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m1, accountId: accountId, db: db)

            // No In-Reply-To/References at all — some clients (or a broken
            // mail flow) drop them, but the normalized subject still
            // matches and the participants overlap within the window.
            let m2 = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<reply@x>",
                subject: "Ｒｅ：来月の懇親会について", from: [test1], to: [aiko], date: base.addingTimeInterval(3600), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m2, accountId: accountId, db: db)
        }

        let threads = try database.dbWriter.read { db in try ThreadRecord.fetchAll(db) }
        #expect(threads.count == 1)
        #expect(threads[0].messageCount == 2)
    }

    // MARK: Thread merge

    @Test("a message referencing two previously-separate threads merges them into one, keeping the larger's id")
    func bridgingMessageMergesThreads() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let test1 = EmailAddress(address: "test1@otegami.test")
        let aiko = EmailAddress(address: "aiko@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let (largeThreadId, smallThreadId) = try database.dbWriter.write { db -> (Int64, Int64) in
            // Thread A: two messages, ends up larger.
            let a1 = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<a1@x>",
                subject: "件名A", from: [aiko], to: [test1], date: base, db: db
            )
            let threadA = try ThreadAssigner.assignThread(messageId: a1, accountId: accountId, db: db)!
            let a2 = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<a2@x>", inReplyTo: "<a1@x>", references: ["<a1@x>"],
                subject: "Re: 件名A", from: [test1], to: [aiko], date: base.addingTimeInterval(60), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: a2, accountId: accountId, db: db)

            // Thread B: one message, ends up smaller.
            let b1 = try insertMessage(
                mailboxId: mailboxId, uid: 3, messageId: "<b1@x>",
                subject: "件名B", from: [aiko], to: [test1], date: base.addingTimeInterval(120), db: db
            )
            let threadB = try ThreadAssigner.assignThread(messageId: b1, accountId: accountId, db: db)!

            return (threadA, threadB)
        }
        #expect(largeThreadId != smallThreadId)

        // A forward/bridge message referencing both prior threads' messages.
        try database.dbWriter.write { db in
            let bridge = try insertMessage(
                mailboxId: mailboxId, uid: 4, messageId: "<bridge@x>",
                references: ["<a2@x>", "<b1@x>"],
                subject: "Fwd: 件名A", from: [test1], to: [aiko], date: base.addingTimeInterval(180), db: db
            )
            let result = try ThreadAssigner.assignThread(messageId: bridge, accountId: accountId, db: db)
            #expect(result == largeThreadId)
        }

        let (threads, messages) = try database.dbWriter.read { db in
            (try ThreadRecord.fetchAll(db), try MessageRecord.fetchAll(db))
        }
        #expect(threads.count == 1)
        #expect(threads[0].id == largeThreadId)
        #expect(threads[0].messageCount == 4)
        #expect(messages.allSatisfy { $0.threadId == largeThreadId })

        // The smaller thread's row was deleted (merged away), not just
        // orphaned.
        let survivingIds = Set(threads.compactMap(\.id))
        #expect(!survivingIds.contains(smallThreadId))
    }

    // MARK: unreadCount integrity through flag changes and deletion

    @Test("recomputeAggregates reflects a flag change and a deletion, deleting an emptied thread")
    func aggregatesTrackFlagChangesAndDeletion() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let test1 = EmailAddress(address: "test1@otegami.test")
        let aiko = EmailAddress(address: "aiko@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let (threadId, m1, m2) = try database.dbWriter.write { db -> (Int64, Int64, Int64) in
            let m1 = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<a@x>",
                subject: "s", from: [aiko], to: [test1], date: base, db: db
            )
            let threadId = try ThreadAssigner.assignThread(messageId: m1, accountId: accountId, db: db)!
            let m2 = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<b@x>", inReplyTo: "<a@x>", references: ["<a@x>"],
                subject: "Re: s", from: [test1], to: [aiko], date: base.addingTimeInterval(60), db: db
            )
            _ = try ThreadAssigner.assignThread(messageId: m2, accountId: accountId, db: db)
            return (threadId, m1, m2)
        }

        var thread = try #require(try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) })
        #expect(thread.messageCount == 2)
        #expect(thread.unreadCount == 2)

        // Mark one message read, as MessageView's markAsReadIfNeeded does.
        try database.dbWriter.write { db in
            var message = try MessageRecord.fetchOne(db, key: m1)!
            message.flags.insert(.seen)
            try message.update(db)
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        thread = try #require(try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) })
        #expect(thread.unreadCount == 1)

        // Delete the remaining unread message too.
        try database.dbWriter.write { db in
            try MessageRecord.deleteOne(db, key: m2)
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        thread = try #require(try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) })
        #expect(thread.messageCount == 1)
        #expect(thread.unreadCount == 0)

        // Delete the last message: the thread row itself should be gone.
        try database.dbWriter.write { db in
            try MessageRecord.deleteOne(db, key: m1)
            try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
        }
        let survivor = try database.dbWriter.read { db in try ThreadRecord.fetchOne(db, key: threadId) }
        #expect(survivor == nil)
    }

    // MARK: assignAllUnthreaded (bulk backfill)

    @Test("assignAllUnthreaded threads a batch of pre-existing (threadId == nil) messages in one pass")
    func bulkBackfillThreadsExistingMessages() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let test1 = EmailAddress(address: "test1@otegami.test")
        let test2 = EmailAddress(address: "test2@otegami.test")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Simulate legacy (pre-M4) rows: inserted directly, no
        // assignThread call, as if migrated in with threadId still nil.
        try database.dbWriter.write { db in
            _ = try insertMessage(
                mailboxId: mailboxId, uid: 1, messageId: "<x1@x>",
                subject: "旧データの件名", from: [test2], to: [test1], date: base, db: db
            )
            _ = try insertMessage(
                mailboxId: mailboxId, uid: 2, messageId: "<x2@x>", inReplyTo: "<x1@x>", references: ["<x1@x>"],
                subject: "Re: 旧データの件名", from: [test1], to: [test2], date: base.addingTimeInterval(60), db: db
            )
            _ = try insertMessage(
                mailboxId: mailboxId, uid: 3, messageId: "<y1@x>",
                subject: "別件", from: [test2], to: [test1], date: base.addingTimeInterval(120), db: db
            )
        }

        let beforeCount = try database.dbWriter.read { db in try ThreadRecord.fetchCount(db) }
        #expect(beforeCount == 0)

        try database.dbWriter.write { db in
            try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db)
        }

        let (threads, messages) = try database.dbWriter.read { db in
            (try ThreadRecord.fetchAll(db), try MessageRecord.fetchAll(db))
        }
        #expect(threads.count == 2)
        #expect(messages.allSatisfy { $0.threadId != nil })
        let counts = Set(threads.map(\.messageCount)).sorted()
        #expect(counts == [1, 2])
    }
}
