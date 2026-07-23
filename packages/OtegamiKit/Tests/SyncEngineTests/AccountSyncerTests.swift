import Foundation
import GRDB
import Testing
import MailTransport
import OtegamiCore
import OtegamiStore
@testable import SyncEngine

@Suite("AccountSyncer initial sync")
struct AccountSyncerTests {
    private func makeAccount() -> AccountRecord {
        AccountRecord(
            displayName: "Test",
            email: "test1@otegami.test",
            authType: .password,
            imapHost: "localhost",
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: "test1@otegami.test"
        )
    }

    private func makeInbox(uid: UInt32, subject: String, references: [String] = []) -> FetchedEnvelope {
        FetchedEnvelope(
            uid: uid,
            messageId: "<seed-\(uid)@otegami.test>",
            inReplyTo: references.last,
            references: references,
            subject: subject,
            from: [EmailAddress(name: "Aiko", address: "aiko@otegami.test")],
            to: [EmailAddress(address: "test1@otegami.test")],
            cc: [],
            bcc: [],
            replyTo: [],
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            internalDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(uid)),
            flags: [],
            size: 512
        )
    }

    @Test("fetches envelopes into message/messageReference on initial sync")
    func fetchesEnvelopesIntoStore() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let envelopes = [
            makeInbox(uid: 1, subject: "ようこそ otegami へ"),
            makeInbox(uid: 2, subject: "明日の打ち合わせについて"),
            makeInbox(uid: 3, subject: "Re: 明日の打ち合わせについて", references: ["<seed-2@otegami.test>"]),
        ]
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": envelopes],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: 4, highestModSeq: 0, messageCount: 3),
            ]
        )

        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.mailboxesDiscovered == 1)
        #expect(progress.envelopesFetched == 3)

        let (mailboxes, messages) = try await database.dbWriter.read { db in
            (
                try MailboxRecord.filter(Column("accountId") == account.id).fetchAll(db),
                try MessageRecord.fetchAll(db)
            )
        }
        #expect(mailboxes.count == 1)
        #expect(mailboxes.first?.role == .inbox)
        #expect(mailboxes.first?.messageCount == 3)
        #expect(mailboxes.first?.uidNext == 4)
        #expect(mailboxes.first?.lastSyncedAt != nil)

        #expect(messages.count == 3)
        let subjects = Set(messages.compactMap(\.subject))
        #expect(subjects.contains("ようこそ otegami へ"))
        #expect(subjects.contains("Re: 明日の打ち合わせについて"))

        let reply = try #require(messages.first { $0.subject == "Re: 明日の打ち合わせについて" })
        let references = try await database.dbWriter.read { db in
            try MessageReferenceRecord.filter(Column("messageId") == reply.id).fetchAll(db)
        }
        #expect(references.map(\.referenceValue) == ["<seed-2@otegami.test>"])
    }

    @Test("resyncing the same mailbox is idempotent and picks up flag changes")
    func resyncIsIdempotent() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        var envelope = makeInbox(uid: 1, subject: "ようこそ otegami へ")
        let firstScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [envelope]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )

        let syncer1 = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: firstScript)
        }
        _ = try await syncer1.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        // Second sync: server now reports the message as \Seen.
        envelope.flags = .seen
        let secondScript = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": [envelope]],
            statusByPath: ["INBOX": MailboxStatus(uidValidity: 1, uidNext: 2, highestModSeq: 0, messageCount: 1)]
        )
        let syncer2 = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: secondScript)
        }
        _ = try await syncer2.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == 1)
        #expect(messages.first?.flags.contains(.seen) == true)

        let mailboxes = try await database.dbWriter.read { db in try MailboxRecord.fetchAll(db) }
        #expect(mailboxes.count == 1)
    }

    @Test("only fetches the most recent initialSyncWindow messages from a larger mailbox")
    func fetchesOnlyRecentWindow() async throws {
        let database = try AppDatabase.makeInMemory()
        let account = makeAccount()
        try await database.dbWriter.write { db in try account.insert(db) }

        let inbox = MailboxInfo(path: "INBOX", displayPath: "INBOX", role: .inbox, attributes: [])
        let totalMessages: UInt32 = 600
        let envelopes = (1...totalMessages).map { makeInbox(uid: $0, subject: "msg-\($0)") }
        let script = FakeIMAPSession.Script(
            mailboxes: [inbox],
            envelopesByPath: ["INBOX": envelopes],
            statusByPath: [
                "INBOX": MailboxStatus(uidValidity: 1, uidNext: totalMessages + 1, highestModSeq: 0, messageCount: Int(totalMessages)),
            ]
        )
        let syncer = AccountSyncer(account: account, database: database) { config in
            FakeIMAPSession(config: config, script: script)
        }

        let progress = try await syncer.performInitialSync(auth: .password(username: "test1@otegami.test", password: "test1234"))
        #expect(progress.envelopesFetched == Int(AccountSyncer.initialSyncWindow))

        let messages = try await database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.count == Int(AccountSyncer.initialSyncWindow))
        let uids = messages.map(\.uid).sorted()
        #expect(uids.first == Int64(totalMessages - AccountSyncer.initialSyncWindow + 1))
        #expect(uids.last == Int64(totalMessages))
    }

    @Test("initialSyncLowerBound math")
    func initialSyncLowerBoundMath() {
        // Fewer messages than the window: start from UID 1.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 10, window: 500) == 1)
        // Exactly the window: start from UID 1.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 501, window: 500) == 1)
        // More than the window: keep only the most recent `window`.
        #expect(AccountSyncer.initialSyncLowerBound(uidNext: 601, window: 500) == 101)
    }
}
