import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #156 (作成画面リッチテキスト化のHTML送信配線): covers the schema-level
/// piece of the follow-up `PENDING.md`'s Task #129 section described —
/// `OutboxMessageRecord.htmlBody` (v32 migration) round-trips through GRDB
/// like every other column, so `OpQueueProcessor`'s `.send` replay actually
/// sees the HTML a formatted `ComposerView.send()` wrote, not a value lost
/// somewhere between the insert and the later fetch.
@Suite("OutboxMessageRecord htmlBody round-trip")
struct OutboxMessageRecordTests {
    private func makeAccount(db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: "Test", email: "t@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@example.test"
        )
        try account.insert(db)
        return account
    }

    @Test("a row written with htmlBody set still has it after fetching back from the database")
    func htmlBodySurvivesInsertAndFetch() throws {
        let database = try AppDatabase.makeInMemory()
        let outboxId: Int64 = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@example.test")],
                subject: "書式付きテスト",
                plainTextBody: "formatted body",
                htmlBody: "<p><b>formatted</b> body</p>"
            )
            try outbox.insert(db)
            return try #require(outbox.id)
        }

        let fetched = try database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outboxId) }
        #expect(fetched?.htmlBody == "<p><b>formatted</b> body</p>")
        #expect(fetched?.plainTextBody == "formatted body")
    }

    @Test("a row written with no htmlBody (unformatted send) still fetches back with it nil, unchanged from before Task #156")
    func nilHTMLBodyStaysNil() throws {
        let database = try AppDatabase.makeInMemory()
        let outboxId: Int64 = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            var outbox = OutboxMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@example.test")],
                subject: "プレーンテスト",
                plainTextBody: "plain body"
            )
            try outbox.insert(db)
            return try #require(outbox.id)
        }

        let fetched = try database.dbWriter.read { db in try OutboxMessageRecord.fetchOne(db, key: outboxId) }
        #expect(fetched?.htmlBody == nil)
    }
}
