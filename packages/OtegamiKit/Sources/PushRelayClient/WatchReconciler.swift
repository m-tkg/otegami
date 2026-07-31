import Foundation
import OtegamiRelayAPI

/// Pure decision logic for `AppEnvironment.reconcilePushWatchesIfNeeded()`
/// (M9 follow-up: 実機バグ1「削除済みアカウントの watch がリレーに残り通知
/// が届き続ける」) — given what the relay says this device's watches are
/// (`GET /v1/watches`, ground truth) and what the app thinks locally (its
/// current `.password` accounts, and its own accountId→watchId map), works
/// out exactly what to reconcile. Kept side-effect-free and free of
/// `PushSettingsStore`/`PushRelayClient` themselves so it's trivially
/// unit-testable (`WatchReconcilerTests`) without touching Keychain,
/// `UserDefaults`, or the network — `AppEnvironment` is the one caller,
/// and does nothing more than execute whatever `Plan` this returns.
public enum WatchReconciler {
    /// What `AppEnvironment.reconcilePushWatchesIfNeeded()` should do,
    /// computed from a single snapshot of local + relay state. Every field
    /// defaults empty, so `Plan.isEmpty` (no drift — the common case once
    /// everything's settled) is exactly "every field is empty."
    public struct Plan: Equatable, Sendable {
        /// Relay watch ids to `DELETE` — either the watch belongs to an
        /// account this device no longer has locally (the actual M9 bug:
        /// the account was deleted, but the `DELETE` at delete-time either
        /// never ran or failed and was never retried), or it's a
        /// duplicate second watch for an account that already has one
        /// (shouldn't normally happen, but cheap to clean up here too if
        /// it ever does).
        public var watchIdsToDelete: [String]
        /// Local `.password` account ids with no live relay watch —
        /// `AppEnvironment.registerWatch` should be called for each (the
        /// initial `createWatch` failed, or the local map fell out of
        /// sync some other way).
        public var accountIdsToRegister: [String]
        /// Local accountId→watchId corrections: the relay already has a
        /// live watch for this account, but the local map either has no
        /// entry or points at a different (stale) watch id — just adopt
        /// the relay's id locally, no network call needed.
        public var watchIdsToAdoptLocally: [String: String]
        /// Local map entries to drop with no relay call at all — the
        /// account they reference doesn't exist locally anymore, so
        /// whatever watch id the map remembers for it is meaningless
        /// (the relay-side watch, if any, is already covered by
        /// `watchIdsToDelete`).
        public var accountIdsToForgetLocally: [String]

        public init(
            watchIdsToDelete: [String] = [],
            accountIdsToRegister: [String] = [],
            watchIdsToAdoptLocally: [String: String] = [:],
            accountIdsToForgetLocally: [String] = []
        ) {
            self.watchIdsToDelete = watchIdsToDelete
            self.accountIdsToRegister = accountIdsToRegister
            self.watchIdsToAdoptLocally = watchIdsToAdoptLocally
            self.accountIdsToForgetLocally = accountIdsToForgetLocally
        }

        public var isEmpty: Bool {
            watchIdsToDelete.isEmpty
                && accountIdsToRegister.isEmpty
                && watchIdsToAdoptLocally.isEmpty
                && accountIdsToForgetLocally.isEmpty
        }
    }

    /// - Parameters:
    ///   - localPasswordAccountIds: every `.password`-auth account this
    ///     device currently has locally (`.oauth2` accounts never get a
    ///     watch — M9's v1 scope — so they're irrelevant to this diff and
    ///     the caller shouldn't include them).
    ///   - localWatchMap: `PushSettingsStore.accountWatchMap` as-is
    ///     (accountId -> watchId), including any entries for accounts
    ///     that no longer exist locally.
    ///   - serverWatches: `PushRelayClient.listWatches`'s result — this
    ///     device's watches, per the relay.
    public static func plan(
        localPasswordAccountIds: Set<String>,
        localWatchMap: [String: String],
        serverWatches: [WatchSummary]
    ) -> Plan {
        var watchIdsToDelete: [String] = []
        var liveWatchIdByAccountId: [String: String] = [:]

        for watch in serverWatches {
            guard localPasswordAccountIds.contains(watch.accountId) else {
                // The account this watch was created for doesn't exist
                // locally anymore — the actual bug this reconciler fixes.
                watchIdsToDelete.append(watch.watchId)
                continue
            }
            if liveWatchIdByAccountId[watch.accountId] != nil {
                // A second watch for an account that already has one —
                // keep whichever was seen first (closest to `serverWatches`'
                // own ordering, oldest-first per `RelayStore
                // .listWatchSummaries`), delete the rest.
                watchIdsToDelete.append(watch.watchId)
            } else {
                liveWatchIdByAccountId[watch.accountId] = watch.watchId
            }
        }

        let accountIdsToRegister = localPasswordAccountIds
            .subtracting(liveWatchIdByAccountId.keys)
            .sorted()

        var watchIdsToAdoptLocally: [String: String] = [:]
        for (accountId, watchId) in liveWatchIdByAccountId where localWatchMap[accountId] != watchId {
            watchIdsToAdoptLocally[accountId] = watchId
        }

        let accountIdsToForgetLocally = localWatchMap.keys
            .filter { !localPasswordAccountIds.contains($0) }
            .sorted()

        return Plan(
            watchIdsToDelete: watchIdsToDelete,
            accountIdsToRegister: accountIdsToRegister,
            watchIdsToAdoptLocally: watchIdsToAdoptLocally,
            accountIdsToForgetLocally: accountIdsToForgetLocally
        )
    }

    /// Task #174 (実機バグ2: 再登録後もリレー側に古い watch が孤児として
    /// 残る): which relay watchIds `AppEnvironment.reregisterWatch(for:)`
    /// should `DELETE` before creating a fresh watch for `accountId`.
    ///
    /// Prefers `serverWatches` (`GET /v1/watches`, ground truth) filtered
    /// down to this account — this is what actually catches the orphan:
    /// the local `accountWatchMap` only ever remembers the *last*
    /// watchId a successful `createWatch` call persisted, so any earlier
    /// watch for the same account that a previous register/reregister
    /// attempt created but never got around to deleting (crash, kill,
    /// `try?`-swallowed delete failure) is invisible to a local-map-only
    /// lookup, even though the relay still has it. `localWatchId` is
    /// unioned in too so a transient/failed `GET /v1/watches` (the caller
    /// passes `nil` on any failure, matching this whole file's
    /// best-effort posture) still deletes at least the one watch the app
    /// itself remembers — no worse than the pre-#174 behavior.
    public static func watchIdsToDelete(
        forReregisteringAccountId accountId: String,
        serverWatches: [WatchSummary],
        localWatchId: String?
    ) -> Set<String> {
        var watchIds = Set(serverWatches.filter { $0.accountId == accountId }.map(\.watchId))
        if let localWatchId {
            watchIds.insert(localWatchId)
        }
        return watchIds
    }

    /// Task #174: every relay watchId `AppEnvironment
    /// .disablePushNotifications()` should `DELETE` — "disable" is meant
    /// to fully undo this device's relay footprint, so it should reach
    /// every watch the relay has for this device, not just the ones the
    /// local `accountWatchMap` happens to still remember. `serverWatches`
    /// (`GET /v1/watches`) is already device-scoped server-side
    /// (`WatchRoutes` resolves the owning deviceId from the
    /// `deviceSecret` used to authenticate the call), so every id it
    /// returns is safe to delete unconditionally. `localWatchMap`'s
    /// values are unioned in for the same "the relay list call itself
    /// might have failed" reason as `watchIdsToDelete
    /// (forReregisteringAccountId:...)` above.
    public static func watchIdsToDeleteForDisable(
        serverWatches: [WatchSummary],
        localWatchMap: [String: String]
    ) -> Set<String> {
        var watchIds = Set(serverWatches.map(\.watchId))
        watchIds.formUnion(localWatchMap.values)
        return watchIds
    }

    /// Task #210 (実機バグ3: Task #208 のリレー・スキーマ入れ替えで全 watch
    /// が破棄された後、通知が最大24時間止まったまま): whether
    /// `AppEnvironment.reconcilePushWatchesIfNeeded()` should attempt a
    /// `GET /v1/watches` call right now.
    ///
    /// Deliberately has **no parameter for how recently the last
    /// *successful* reconcile pass ran** — that was exactly Task #208's
    /// bug. The old `watchReconcileInterval` (~once/day) gated the fetch
    /// itself on staleness alone, so a relay that lost every watch (a
    /// server-side schema migration, not any client-visible event) stayed
    /// unrepaired until the throttle happened to expire, up to 24h later.
    /// There is no way to know locally whether the relay still agrees with
    /// this device without asking it — `AppEnvironment`'s local
    /// `accountWatchMap` cache is exactly the kind of state a server-side
    /// wipe leaves stale-but-populated (see `docs/architecture.md`'s Task
    /// #210 note for why a local-only "is my map empty?" heuristic would
    /// have missed this specific incident), so gating the fetch on
    /// anything other than "did the last attempt just fail" reintroduces
    /// the same class of bug.
    ///
    /// `GET /v1/watches` itself is treated as cheap enough to run on every
    /// foreground unconditionally (same cadence as `syncAllAccountsOnce()`,
    /// which does far more per foreground) — `WatchReconciler.plan` is a
    /// pure, in-memory diff, so the only real cost is the one network round
    /// trip, and an empty resulting `Plan` (the common, healthy case) costs
    /// nothing further.
    ///
    /// What *does* still need throttling is retrying a fetch that just
    /// failed: a relay that's unreachable right now (down, network error,
    /// ...) shouldn't get hit again on every single foreground while the
    /// user keeps unlocking/reopening the app during the outage — that's
    /// what `lastFailureDate`/`failureBackoffInterval` are for. Each
    /// failed attempt should re-record `lastFailureDate` as "now" (see
    /// `AppEnvironment.reconcilePushWatchesIfNeeded()`), so consecutive
    /// failures keep pushing the next retry back rather than retrying every
    /// foreground for the whole duration of an outage.
    public static func shouldAttemptReconcile(
        now: Date,
        lastFailureDate: Date?,
        failureBackoffInterval: TimeInterval
    ) -> Bool {
        guard let lastFailureDate else { return true }
        return now.timeIntervalSince(lastFailureDate) >= failureBackoffInterval
    }
}
