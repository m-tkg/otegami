import Foundation
import OtegamiRelayAPI
import OtegamiStore

/// Task #173: per-account push-watch status for
/// `PushNotificationSettingsView`'s account list — the motivating 実機
/// report was a relay-side log line ("3 watches, 1 auth-failed") with no
/// way to tell *which* account from the app. Pure/side-effect-free (like
/// `WatchReconciler.plan`) so the row-building logic can be reasoned about
/// (and, if this app ever gains its own unit test target, tested) without
/// touching `AppEnvironment`/SwiftUI at all.
struct PushWatchDisplayRow: Identifiable, Equatable {
    enum Status: Equatable {
        /// The relay has a live, healthy watch for this account.
        case registered
        /// Push is enabled, this account is `.password`-auth, but the
        /// relay has no watch for it — the initial `createWatch` failed,
        /// or the local/relay state fell out of sync (`WatchReconciler`
        /// normally self-heals this within a day; this state is what a
        /// user would see in the gap before that runs, or if it also
        /// failed).
        case notRegistered
        /// The relay's `WatcherPool` gave up on this watch (currently:
        /// repeated IMAP login failures) — `reason` is whatever the relay
        /// classified it as, `nil` if an older relay reports `.stopped`
        /// without one (shouldn't happen post-Task #173, but decoded
        /// leniently either way per `WatchSummary`'s doc comment).
        case stopped(reason: WatchSummary.ErrorKind?)
        /// An account this build's relay integration has no way to watch
        /// at all — as of Task #175 this is only a `.oauth2` account of
        /// neither `.gmail` nor `.microsoft` `kind` (shouldn't occur in
        /// practice; every `.oauth2` account this app creates is one of
        /// those two). Before Task #175, every `.oauth2` account
        /// (including Gmail/Microsoft) was `.unsupported` — the relay only
        /// supported password auth in v1. Distinct from `.notRegistered`
        /// so the UI doesn't suggest a "re-register" action that could
        /// never work.
        case unsupported
        /// Push is enabled and this is a `.password` account, but the
        /// relay's current watch list couldn't be fetched at all (relay
        /// unreachable, network error, ...) — distinct from
        /// `.notRegistered` so the UI says "status unknown" rather than
        /// implying the watch definitely doesn't exist.
        case unavailable
    }

    var id: String { accountId }
    var accountId: String
    var displayName: String
    var status: Status
    var lastConnectedAt: Date?
    var lastErrorAt: Date?

    /// Builds one row per account, in `accounts`' own order (already the
    /// user's chosen display order — `AccountRecord.sortOrder` — since
    /// every caller passes `AppEnvironment.accounts` straight through).
    ///
    /// - Parameters:
    ///   - accounts: every locally configured account, `.password` and
    ///     `.oauth2` alike (this function does the filtering/branching via
    ///     `AppEnvironment.isPushWatchCandidate(_:)`).
    ///   - isPushEnabled: when `false`, every push-watch-eligible account is
    ///     `.notRegistered` outright — there's no relay call to even
    ///     attempt, so `serverWatches` is irrelevant.
    ///   - serverWatches: `AppEnvironment.fetchPushWatchSummaries()`'s
    ///     result — `nil` means the fetch itself failed (relay
    ///     unreachable), which is exactly what `.unavailable` communicates
    ///     for every push-watch-eligible account rather than defaulting to
    ///     `.notRegistered` (a false "you have no watch" reading).
    static func build(
        accounts: [AccountRecord],
        isPushEnabled: Bool,
        serverWatches: [WatchSummary]?
    ) -> [PushWatchDisplayRow] {
        var watchByAccountId: [String: WatchSummary] = [:]
        for watch in serverWatches ?? [] {
            // Mirrors `WatchReconciler.plan`'s "keep whichever was seen
            // first" tie-break for a duplicate watch on the same account —
            // shouldn't happen in steady state, but this is a display-only
            // reducer, not the source of truth, so it just picks one
            // deterministically rather than crashing/asserting.
            if watchByAccountId[watch.accountId] == nil {
                watchByAccountId[watch.accountId] = watch
            }
        }

        return accounts.map { account in
            guard AppEnvironment.isPushWatchCandidate(account) else {
                return PushWatchDisplayRow(accountId: account.id, displayName: account.displayName, status: .unsupported)
            }
            guard isPushEnabled else {
                return PushWatchDisplayRow(accountId: account.id, displayName: account.displayName, status: .notRegistered)
            }
            guard serverWatches != nil else {
                return PushWatchDisplayRow(accountId: account.id, displayName: account.displayName, status: .unavailable)
            }
            guard let watch = watchByAccountId[account.id] else {
                return PushWatchDisplayRow(accountId: account.id, displayName: account.displayName, status: .notRegistered)
            }
            switch watch.status {
            case .active:
                return PushWatchDisplayRow(
                    accountId: account.id,
                    displayName: account.displayName,
                    status: .registered,
                    lastConnectedAt: watch.lastConnectedAt,
                    lastErrorAt: watch.lastErrorAt
                )
            case .stopped:
                return PushWatchDisplayRow(
                    accountId: account.id,
                    displayName: account.displayName,
                    status: .stopped(reason: watch.lastErrorKind),
                    lastConnectedAt: watch.lastConnectedAt,
                    lastErrorAt: watch.lastErrorAt
                )
            }
        }
    }
}
