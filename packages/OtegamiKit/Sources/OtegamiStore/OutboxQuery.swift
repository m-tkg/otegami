import Foundation
import GRDB

/// Query helpers for `OutboxMessageRecord` (M5): what `SidebarView`'s
/// "送信待ち" row observes.
public enum OutboxQuery {
    public static func request(accountIds: [String]) -> QueryInterfaceRequest<OutboxMessageRecord> {
        OutboxMessageRecord
            .filter(accountIds.contains(Column("accountId")))
            .order(Column("createdAt"))
    }

    public static func observation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[OutboxMessageRecord]>> {
        ValueObservation.tracking { db in try request(accountIds: accountIds).fetchAll(db) }
    }

    /// One `outboxMessage` row paired with the retry state of the `.send`
    /// `opQueue` row that's supposed to actually deliver it — `OutboxView`'s
    /// "送信失敗" detection needs this pairing since `outboxMessage` alone
    /// can't distinguish "still waiting its turn/backoff window" from
    /// "its op gave up retrying" or "its op is simply gone" (an orphaned
    /// row: e.g. a `.send` op discarded independently while somehow leaving
    /// this row behind, or — defensively — any future code path that
    /// deletes the op without also deleting the row). `opId == nil` covers
    /// both "never had a matching op in this fetch" cases; callers can't
    /// tell those two apart and don't need to, since either way there is no
    /// `opQueue` row left for `OpQueueProcessor.replay` to ever pick up.
    public struct Item: Sendable, Equatable, Identifiable {
        public var message: OutboxMessageRecord
        public var opId: Int64?
        public var attempts: Int
        public var lastError: String?
        public var nextRetryAt: Date?

        public var id: Int64 { message.id ?? 0 }

        public init(
            message: OutboxMessageRecord,
            opId: Int64? = nil,
            attempts: Int = 0,
            lastError: String? = nil,
            nextRetryAt: Date? = nil
        ) {
            self.message = message
            self.opId = opId
            self.attempts = attempts
            self.lastError = lastError
            self.nextRetryAt = nextRetryAt
        }

        /// True when there's no realistic path left for this row to be
        /// retried automatically by `OpQueueProcessor.replay`: either its
        /// `.send` op has hit `maxAttempts` (`OpQueueProcessor.maxAttempts`
        /// — passed in rather than hardcoded here, the same layering
        /// `OpQueueQuery`'s doc comment explains: `OtegamiStore` must not
        /// depend on `SyncEngine`), or it's an orphan with no `.send` op at
        /// all (this type's own doc comment).
        public func isFailed(maxAttempts: Int) -> Bool {
            opId == nil || attempts >= maxAttempts
        }
    }

    /// The one field this query needs out of `SyncEngine.SendOpPayload`'s
    /// JSON, duplicated rather than imported for the same reason
    /// `Item.isFailed(maxAttempts:)` takes its threshold as a parameter:
    /// `OtegamiStore` must not depend on `SyncEngine` (dependency direction
    /// is `SyncEngine → OtegamiStore → OtegamiCore`, never the reverse).
    private struct SendOpPayloadShape: Decodable {
        var outboxMessageId: Int64
    }

    /// Builds `[Item]` by fetching every outbox row plus every `.send`
    /// `opQueue` row for these accounts, then pairing them client-side by
    /// decoding each op's payload — the same "small enough to just decode
    /// and linearly match" approach `PendingSendCoordinator
    /// .deleteOutboxMessage`/`FailedOperationsView.discard` already use for
    /// this same payload. `"send"` mirrors `SyncEngine.OpQueueKind.send
    /// .rawValue` (a plain `String` enum, so its raw value is literally
    /// `"send"`) — see `SendOpPayloadShape`'s doc comment for why this
    /// can't reference that enum directly.
    public static func itemsRequest(accountIds: [String], db: Database) throws -> [Item] {
        let messages = try request(accountIds: accountIds).fetchAll(db)
        guard !messages.isEmpty else { return [] }

        let sendOps = try OpQueueRecord
            .filter(accountIds.contains(Column("accountId")))
            .filter(Column("kind") == "send")
            .fetchAll(db)

        var opByOutboxId: [Int64: OpQueueRecord] = [:]
        for op in sendOps {
            guard let payload = try? JSONDecoder().decode(SendOpPayloadShape.self, from: op.payload) else { continue }
            opByOutboxId[payload.outboxMessageId] = op
        }

        return messages.map { message in
            guard let messageId = message.id, let op = opByOutboxId[messageId] else {
                return Item(message: message)
            }
            return Item(message: message, opId: op.id, attempts: op.attempts, lastError: op.lastError, nextRetryAt: op.nextRetryAt)
        }
    }

    /// Tracks both `outboxMessage` and `opQueue` — `ValueObservation
    /// .tracking` automatically follows every table its closure actually
    /// reads, so `itemsRequest(accountIds:db:)` reading both tables is
    /// enough; nothing further needs to opt in the second table explicitly.
    public static func itemsObservation(accountIds: [String]) -> ValueObservation<ValueReducers.Fetch<[Item]>> {
        ValueObservation.tracking { db in try itemsRequest(accountIds: accountIds, db: db) }
    }
}
