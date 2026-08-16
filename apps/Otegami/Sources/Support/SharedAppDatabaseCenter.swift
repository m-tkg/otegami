#if os(iOS)
import Foundation
import OtegamiStore

/// 実クラッシュ調査 (TestFlight v1.14.1, iPad, `0xDEAD10CC`) 「穴2」対策:
/// bridges `AppEnvironment`'s already-open shared `AppDatabase` handle (a
/// single `DatabasePool` onto the App Group container) to
/// `PushNotificationActionHandler`, which otherwise has no reachable path to
/// it — `AppDelegate` can't see `AppEnvironment` (a SwiftUI `App`'s
/// `@State`, see `PushNotificationActionHandler`'s own doc comment on the
/// same constraint).
///
/// Before this existed, `PushNotificationActionHandler.handle(...)` always
/// called `AppDatabase.makeShared(...)` itself, opening a **second**
/// `DatabasePool` onto the exact same shared file whenever a notification
/// action arrived while this app process was already alive (foregrounded,
/// or mid-background-execution from an earlier launch) with its own
/// `AppEnvironment.database` already open — paying a fresh migration scan
/// plus `busyMode = .timeout(5.0)` lock contention against its own first
/// connection (`AppDatabase.makeConfiguration
/// (observesSuspensionNotifications:)`'s doc comment) for no reason, right
/// in the narrow execution window this whole crash fix is trying to
/// protect. This type lets `PushNotificationActionHandler` reuse the
/// existing handle when one is available, and fall back to opening its own
/// exactly as before when the notification action is itself what cold-
/// launches this process (no `AppEnvironment` constructed yet at all).
///
/// Mirrors `PushDatabaseChangeObserver`'s `weak var environment` /
/// `configure(environment:)` two-phase wiring (see that type's doc comment
/// for the identical reasoning) rather than making `AppEnvironment` itself
/// a singleton — `AppEnvironment` stays a plain SwiftUI `@State` value with
/// a single owner (`OtegamiApp`), matching every test/preview call site
/// that constructs its own throwaway instance.
@MainActor
final class SharedAppDatabaseCenter {
    static let shared = SharedAppDatabaseCenter()

    private weak var environment: AppEnvironment?

    private init() {}

    func configure(environment: AppEnvironment) {
        self.environment = environment
    }

    /// `nil` until `AppEnvironment.init()` has run and wired this instance
    /// (`configure(environment:)`, one of the last steps of `init()`) —
    /// exactly the "no `AppEnvironment` yet" case `PushNotificationActionHandler
    /// .handle(...)` falls back to opening its own `AppDatabase` for.
    var database: AppDatabase? { environment?.database }
}
#endif
