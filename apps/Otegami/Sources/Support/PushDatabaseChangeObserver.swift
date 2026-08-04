import Foundation
import PushRelayClient

#if os(iOS)
import CoreFoundation
#endif

/// プッシュ通知起点バックグラウンド受信 Phase 1 (アプリ側反映): observes
/// `DatabaseChangeDarwinNotification.name` — the Darwin notification
/// `NotificationService` posts right after it durably writes a newly-synced
/// message into the shared App Group database
/// (`SyncEngine.PushTriggeredInboxSync.run`'s doc comment) — and calls back
/// into `AppEnvironment` so its live `ValueObservation`s (mailbox/thread
/// lists, unread counts, ...) notice the change while this app is in the
/// foreground.
///
/// Mirrors `PendingSendCoordinator`/`GmailAccessTokenBridge`'s two-phase
/// `weak var environment` / `configure(environment:)` wiring (see either
/// type's own doc comment for the identical reasoning): `AppEnvironment`
/// holds one as a default-initialized stored property (so it already
/// exists, with no `environment` yet, before `init()`'s body runs), then
/// wires — and, on iOS, starts observing — it as one of the last steps of
/// `init()`, once `self` is safe to hand out.
///
/// **iOS-only observing**: macOS has no App Group/shared database for
/// another process to change out from under this one in the first place
/// (`OtegamiAppGroup.identifier`'s doc comment — no `NotificationService`
/// Extension there either), so `startObserving()`/the Darwin
/// `CFNotificationCenterAddObserver`/`RemoveObserver` calls are `#if
/// os(iOS)`-gated; on macOS this type exists (for `AppEnvironment`'s own
/// simplicity, same "inert on macOS" shape as `DatabaseSuspensionTracker`)
/// but never actually registers anything.
///
/// `@MainActor` (not an `actor`) specifically so `configure(environment:)`
/// can be called synchronously from `AppEnvironment.init()` itself, the
/// same constraint `GmailAccessTokenBridge.configure(environment:)` is
/// under. `@unchecked Sendable`: every stored property is only ever read/
/// written while isolated to the main actor (`configure(environment:)`) or
/// captured as a plain, already-`Sendable` value into the `@convention(c)`
/// callback below — the compiler can't verify that automatically for a
/// plain (non-`actor`) class, but the isolation itself makes it safe,
/// matching this codebase's other `@unchecked Sendable` main-actor-isolated
/// types (e.g. `GmailAccessTokenBridge`'s own doc comment).
@MainActor
final class PushDatabaseChangeObserver: @unchecked Sendable {
    private weak var environment: AppEnvironment?

    func configure(environment: AppEnvironment) {
        self.environment = environment
        #if os(iOS)
        startObserving()
        #endif
    }

    #if os(iOS)
    private func startObserving() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                // `@convention(c)` — no captures allowed, so `observer`
                // (the exact same `Unmanaged.passUnretained(self)` pointer
                // registered above) is how this reaches back into the
                // instance that registered it. `takeUnretainedValue()`
                // (not `takeRetainedValue()`): this callback doesn't own a
                // reference, it's just borrowing the one `startObserving()`
                // already holds via `self` — `removeObserver` in `deinit`
                // is what actually unregisters this pointer before the
                // instance goes away.
                guard let observer else { return }
                Unmanaged<PushDatabaseChangeObserver>.fromOpaque(observer).takeUnretainedValue().handleDatabaseChanged()
            },
            DatabaseChangeDarwinNotification.name as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// `nonisolated`: called directly from the `@convention(c)` callback
    /// above, a synchronous, non-actor-isolated context — a plain
    /// `@MainActor`-isolated method couldn't be called from there without
    /// an `await` this call site can't provide. Darwin notifications can
    /// also arrive off the main thread regardless, so this hops onto the
    /// main actor itself (where `environment`/its `database` are isolated)
    /// before doing anything, rather than assuming it's already there.
    /// Best-effort (`try?` inside `AppEnvironment
    /// .notifyDatabaseChangesFromPush()`): a write that races a currently-
    /// suspended shared database (this app itself just backgrounded) simply
    /// does nothing, the same way every other suspended-database write in
    /// this codebase does — the next foreground return's own
    /// `notifyDatabaseChangesFromPush()` call (`OtegamiApp
    /// .handleScenePhaseChange`'s `.active` case) covers the gap.
    nonisolated private func handleDatabaseChanged() {
        Task { @MainActor [weak self] in
            await self?.environment?.notifyDatabaseChangesFromPush()
        }
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(DatabaseChangeDarwinNotification.name as CFString),
            nil
        )
    }
    #endif
}
