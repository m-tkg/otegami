import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Task「送信失敗メールの再送・削除」: covers `OutboxQuery.itemsRequest`'s
/// pairing of each `outboxMessage` row with its `.send` opQueue row's retry
/// state — `OutboxView`'s "送信失敗" detection depends on this pairing being
/// correct for all three shapes an outbox row can be in (still retryable,
/// retries exhausted, orphaned with no op at all).
@Suite("OutboxQuery.itemsRequest pairs outbox rows with their .send op state")
struct OutboxQueryTests {
    private func makeAccount(db: Database) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: "Test", email: "t@example.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "t@example.test"
        )
        try account.insert(db)
        return account
    }

    private func makeOutbox(accountId: String, db: Database) throws -> Int64 {
        var outbox = OutboxMessageRecord(
            accountId: accountId,
            toAddresses: [EmailAddress(address: "recipient@example.test")],
            subject: "テスト送信",
            plainTextBody: "body"
        )
        try outbox.insert(db)
        return try #require(outbox.id)
    }

    /// Mirrors the JSON shape of `SyncEngine.SendOpPayload` — this package
    /// can't import `SyncEngine` (dependency direction is `SyncEngine →
    /// OtegamiStore`, never the reverse), so the payload is hand-encoded
    /// here the same way `OutboxQuery.itemsRequest`'s own
    /// `SendOpPayloadShape` decodes it.
    private struct SendPayload: Encodable {
        var outboxMessageId: Int64
    }

    private func makeSendOp(accountId: String, outboxMessageId: Int64, attempts: Int, lastError: String?, db: Database) throws {
        var op = OpQueueRecord(
            accountId: accountId,
            kind: "send",
            payload: try JSONEncoder().encode(SendPayload(outboxMessageId: outboxMessageId)),
            attempts: attempts,
            lastError: lastError
        )
        try op.insert(db)
    }

    @Test("a row still under maxAttempts pairs with its op and isFailed is false")
    func stillRetryingPairsCorrectly() throws {
        let database = try AppDatabase.makeInMemory()
        let items: [OutboxQuery.Item] = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            try makeSendOp(accountId: account.id, outboxMessageId: outboxId, attempts: 2, lastError: "network error", db: db)
            return try OutboxQuery.itemsRequest(accountIds: [account.id], db: db)
        }

        let item = try #require(items.first)
        #expect(item.opId != nil)
        #expect(item.attempts == 2)
        #expect(item.lastError == "network error")
        #expect(item.isFailed(maxAttempts: 5) == false)
    }

    @Test("a row whose op has hit maxAttempts is reported as failed")
    func exhaustedAttemptsIsFailed() throws {
        let database = try AppDatabase.makeInMemory()
        let items: [OutboxQuery.Item] = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            try makeSendOp(accountId: account.id, outboxMessageId: outboxId, attempts: 5, lastError: "SMTP auth failed", db: db)
            return try OutboxQuery.itemsRequest(accountIds: [account.id], db: db)
        }

        let item = try #require(items.first)
        #expect(item.opId != nil)
        #expect(item.attempts == 5)
        #expect(item.isFailed(maxAttempts: 5) == true)
    }

    @Test("an orphaned outbox row with no matching .send op has opId nil and is reported as failed")
    func orphanedRowIsFailed() throws {
        let database = try AppDatabase.makeInMemory()
        let items: [OutboxQuery.Item] = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            _ = try makeOutbox(accountId: account.id, db: db)
            // Deliberately no matching `.send` op inserted.
            return try OutboxQuery.itemsRequest(accountIds: [account.id], db: db)
        }

        let item = try #require(items.first)
        #expect(item.opId == nil)
        #expect(item.attempts == 0)
        #expect(item.isFailed(maxAttempts: 5) == true)
    }

    @Test("a .send op belonging to a different outboxMessageId doesn't get mismatched to this row")
    func doesNotMismatchUnrelatedOp() throws {
        let database = try AppDatabase.makeInMemory()
        let items: [OutboxQuery.Item] = try database.dbWriter.write { db in
            let account = try makeAccount(db: db)
            let outboxId = try makeOutbox(accountId: account.id, db: db)
            // A `.send` op referencing some other, non-existent outboxMessageId.
            try makeSendOp(accountId: account.id, outboxMessageId: outboxId + 999, attempts: 1, lastError: nil, db: db)
            return try OutboxQuery.itemsRequest(accountIds: [account.id], db: db)
        }

        let item = try #require(items.first)
        #expect(item.opId == nil)
        #expect(item.isFailed(maxAttempts: 5) == true)
    }
}
