import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task #161 (#129/#156のフォローアップ「下書きのhtmlBody未対応」を
/// 解消): `DraftMessageRecord.htmlBody` (v33 migration) round-trips through
/// GRDB like every other column — same shape as
/// `OutboxMessageRecordTests.swift`'s identical coverage for
/// `OutboxMessageRecord.htmlBody` (v32).
@Suite("DraftMessageRecord htmlBody round-trip")
struct DraftMessageRecordTests {
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
        let draftId: Int64 = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            var draft = DraftMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@example.test")],
                subject: "書式付き下書き",
                plainTextBody: "formatted draft",
                htmlBody: "<p><b>formatted</b> draft</p>"
            )
            try draft.insert(db)
            return try #require(draft.id)
        }

        let fetched = try database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draftId) }
        #expect(fetched?.htmlBody == "<p><b>formatted</b> draft</p>")
        #expect(fetched?.plainTextBody == "formatted draft")
    }

    @Test("a row written with no htmlBody (pre-Task #161 draft) still fetches back with it nil")
    func nilHTMLBodyStaysNil() throws {
        let database = try AppDatabase.makeInMemory()
        let draftId: Int64 = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            var draft = DraftMessageRecord(
                accountId: account.id,
                toAddresses: [EmailAddress(address: "recipient@example.test")],
                subject: "プレーン下書き",
                plainTextBody: "plain draft"
            )
            try draft.insert(db)
            return try #require(draft.id)
        }

        let fetched = try database.dbWriter.read { db in try DraftMessageRecord.fetchOne(db, key: draftId) }
        #expect(fetched?.htmlBody == nil)
    }
}
