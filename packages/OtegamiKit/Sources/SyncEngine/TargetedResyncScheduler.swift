import Foundation

/// Task #152 (実機報告「フラグ/アーカイブ操作後、他の受信箱一覧への反映が
/// 遅い」): the pure debounce/coalesce *policy* behind `SyncCoordinator`'s
/// post-`opQueue`-replay targeted resync — decides only *when* a resync
/// should fire for an account and *which destination* mailboxes it should cover, given
/// a stream of `request(accountId:mailboxIds:now:)` calls. Deliberately
/// knows nothing about `AccountRecord`/`MailAuth`/actual IMAP sync —
/// `SyncCoordinator` supplies its own wall clock (`Date()`) and pairs each
/// request with the account/auth needed to actually perform the resync once
/// it comes due. Kept as a plain, synchronous, `Sendable` value type (no
/// `Task.sleep`, no actor) specifically so `TargetedResyncSchedulerTests`
/// can drive it with synthetic timestamps instead of waiting through real
/// multi-second debounce windows.
///
/// Behavior, mirroring the task's "連続操作向けに 2-3 秒デバウンス + 同一
/// mailbox の合流" requirement:
/// - **Debounce**: each `request` for an account *resets* that account's
///   fire time to `now + debounceInterval` — a burst of consecutive swipes
///   on the same account (flag → archive → flag another thread, all within
///   the window) keeps pushing the resync out until the burst quiets down,
///   producing exactly one resync per burst rather than one per operation.
/// - **Coalesce**: each `request`'s `mailboxIds` are *unioned* into
///   whatever's still pending for that account, so a burst touching
///   different destinations (e.g. archiving into Archive, then restoring a
///   different thread into INBOX) resyncs every destination in one pass,
///   not just the most recent one. Optimistic source mailboxes never reach
///   this scheduler; see `OpQueueProcessor.ReplayResult`.
/// - Per-account independence: one account's pending request/fire time
///   never affects another's — matches every other per-account loop in this
///   codebase (`SyncCoordinator.lastPostSyncPrefetchDateByAccount`,
///   `AccountSyncer.mailboxNetworkFailureStreaks`, ...).
public struct TargetedResyncScheduler: Sendable {
    /// One account's still-pending (not yet fired) targeted resync request.
    struct Pending: Sendable, Equatable {
        var mailboxIds: Set<Int64>
        var fireAt: Date
    }

    /// 2-3 second debounce per the task's own spec — 2.5s splits the
    /// difference: long enough that a rapid multi-swipe burst still
    /// coalesces into one resync, short enough that a single isolated
    /// action still reflects "速く" (the whole point of this task) rather
    /// than sitting for several seconds first.
    public static let defaultDebounceInterval: TimeInterval = 2.5

    public let debounceInterval: TimeInterval

    private var pendingByAccount: [String: Pending] = [:]

    public init(debounceInterval: TimeInterval = TargetedResyncScheduler.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    /// Records a targeted-resync request for `accountId`/`mailboxIds` as of
    /// `now`. A no-op if `mailboxIds` is empty (nothing to resync). Merges
    /// into and resets any still-pending request for the same account — see
    /// this type's doc comment for the debounce/coalesce rationale.
    public mutating func request(accountId: String, mailboxIds: Set<Int64>, now: Date) {
        guard !mailboxIds.isEmpty else { return }
        var pending = pendingByAccount[accountId] ?? Pending(mailboxIds: [], fireAt: now)
        pending.mailboxIds.formUnion(mailboxIds)
        pending.fireAt = now.addingTimeInterval(debounceInterval)
        pendingByAccount[accountId] = pending
    }

    /// Pops and returns every account whose debounce window has elapsed as
    /// of `now` (`fireAt <= now`), removing them from the pending set —
    /// idempotent to call again immediately after with the same `now` (an
    /// account just popped won't be returned twice). Order is unspecified
    /// (dictionary iteration) — callers processing multiple due accounts in
    /// one pass shouldn't rely on a particular order between them.
    public mutating func due(now: Date) -> [(accountId: String, mailboxIds: Set<Int64>)] {
        let dueAccountIds = pendingByAccount.filter { $0.value.fireAt <= now }.map(\.key)
        var result: [(accountId: String, mailboxIds: Set<Int64>)] = []
        result.reserveCapacity(dueAccountIds.count)
        for accountId in dueAccountIds {
            if let pending = pendingByAccount.removeValue(forKey: accountId) {
                result.append((accountId, pending.mailboxIds))
            }
        }
        return result
    }

    /// The earliest `fireAt` among every still-pending account, or `nil` if
    /// nothing is pending — how long a real timer loop (`SyncCoordinator
    /// .runTargetedResyncLoop`) should sleep before calling `due(now:)`
    /// again.
    public var nextFireAt: Date? {
        pendingByAccount.values.map(\.fireAt).min()
    }

    /// Whether `accountId` currently has a pending (not yet fired) request
    /// — test/diagnostic convenience.
    public func isPending(accountId: String) -> Bool {
        pendingByAccount[accountId] != nil
    }
}
