#if os(iOS)
import UIKit
import UserNotifications
import OtegamiRelayAPI
import PushRelayClient
import SyncEngine

/// Bridges `UIApplicationDelegate`'s callback-based APNs device-token
/// registration into a single `async throws` call
/// (`PushSettingsStore.enable(...)` awaits this) — `AppDelegate` below
/// forwards both the success and failure callbacks here.
///
/// M9 bug fix (see `docs/verify.md`'s "M9 追補" section):
/// `requestToken()` used to call *only*
/// `UIApplication.registerForRemoteNotifications()`, which registers for
/// APNs device tokens but does **not** request the user-visible
/// notification permission (`UNUserNotificationCenter`'s
/// alert/badge/sound authorization is a separate, iOS-10-vintage API).
/// That meant the app never actually had permission to *display* a
/// notification even after a real device token was obtained and a push
/// was delivered — a production bug, not just a simulator limitation.
/// `requestToken()` now resolves notification authorization first (via
/// `NotificationPermissionResolver`, `PushRelayClient` module — unit
/// tested there as `NotificationPermissionResolverTests` since this actor
/// itself has no unit-test target) and throws
/// `PushTokenError.notificationPermissionDenied` before ever touching
/// `registerForRemoteNotifications()` if that's declined.
///
/// M9 constraint still holds independently of the above:
/// the iOS **simulator** never actually receives a device token —
/// `UIApplication.registerForRemoteNotifications()` on a simulator either
/// never calls back at all or (depending on OS version) calls the failure
/// delegate method, *even when notification authorization itself was
/// granted*. `requestToken()` doesn't try to special-case this; it simply
/// surfaces whatever the OS reports (usually a failure delegate call or a
/// timeout), and `PushNotificationSettingsView` is the layer that turns
/// "no token" into a "この環境では有効化できません（実機が必要です）"
/// message rather than a crash — see that view's doc comment.
actor PushTokenCenter {
    static let shared = PushTokenCenter()

    enum PushTokenError: Error {
        case registrationFailed(String)
        case timedOut
        /// The user declined (or had previously declined) the
        /// `UNUserNotificationCenter` alert/badge/sound authorization
        /// prompt. Distinct from `.registrationFailed`, which is an APNs
        /// device-token registration failure — this happens *before* that
        /// step is even attempted.
        case notificationPermissionDenied
    }

    private var pendingContinuation: CheckedContinuation<String, Error>?

    private init() {}

    /// Resolves notification authorization (prompting the user only if
    /// undetermined — see `NotificationPermissionResolver`'s doc comment
    /// for the authorized/denied/notDetermined handling), then calls
    /// `UIApplication.registerForRemoteNotifications()` and awaits the
    /// delegate callback, with a generous timeout (real devices respond in
    /// well under a second when notifications are already authorized; the
    /// simulator either never responds or fails fast, so this mostly
    /// exists to avoid hanging forever there).
    func requestToken(timeoutSeconds: UInt64 = 10) async throws -> String {
        let outcome = await NotificationPermissionResolver.resolve(using: UNUserNotificationCenter.current())
        guard outcome == .granted else {
            throw PushTokenError.notificationPermissionDenied
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.setContinuation(continuation) }
                    Task { @MainActor in
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw PushTokenError.timedOut
            }
            guard let result = try await group.next() else { throw PushTokenError.timedOut }
            group.cancelAll()
            return result
        }
    }

    private func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
        pendingContinuation = continuation
    }

    /// Called by `AppDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    func didRegister(tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        pendingContinuation?.resume(returning: token)
        pendingContinuation = nil
    }

    /// Called by `AppDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    func didFail(error: any Error) {
        pendingContinuation?.resume(throwing: PushTokenError.registrationFailed("\(error)"))
        pendingContinuation = nil
    }
}

/// `UIApplicationDelegate` — receives the two APNs registration callbacks
/// and forwards them to `PushTokenCenter`, and (as a
/// `UNUserNotificationCenterDelegate`) handles push notification action
/// buttons ("既読にする"/"アーカイブ" — see `PushNotificationActionCategory`).
/// Wired via `@UIApplicationDelegateAdaptor` in `OtegamiApp`.
///
/// `@MainActor`: both `UIApplicationDelegate`'s and (implicitly, via
/// `NSObjectProtocol`) `UNUserNotificationCenterDelegate`'s requirements are
/// expected to run on the main thread, and every method here except
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)` is inferred
/// main-actor-isolated as a result. That one method is carved out as
/// `nonisolated` instead (see its own doc comment) — its SDK-declared
/// protocol requirement is itself `nonisolated`, and a main-actor-isolated
/// override can't satisfy a `nonisolated` requirement under Swift 6 strict
/// concurrency.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushNotificationActionCategory.registerPushNotificationCategories()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushTokenCenter.shared.didRegister(tokenData: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Task { await PushTokenCenter.shared.didFail(error: error) }
    }

    /// Handles a tap on one of `PushNotificationActionCategory`'s action
    /// buttons (`MARK_READ`/`ARCHIVE`), or a tap on the notification body
    /// itself (`UNNotificationDefaultActionIdentifier`) — that default tap
    /// hands the payload's `accountId`/`uidNext` straight to
    /// `PushNotificationOpenCoordinator` so `MailScreenView` can navigate
    /// to `PushNotificationOpenView` (a loading screen) the moment the app
    /// finishes launching/foregrounding; resolving the target message (and
    /// the INBOX-only priority sync a not-yet-synced message needs — see
    /// `AppEnvironment.resolvePushNotificationOpenTarget`) happens inside
    /// that view, with visible progress and a retry path, instead of here.
    /// The dismiss identifier (`UNNotificationDismissActionIdentifier`,
    /// swiping it away) falls through to the `nil` case in `action(for:)` —
    /// same as an unparseable payload — and just calls
    /// `completionHandler()` immediately.
    ///
    /// v1.3.8 production crash (`UIApplication
    /// ._updateStateRestorationArchiveForBackgroundEvent:...` asserting
    /// inside `_performBlockAfterCATransactionCommitSynchronizes:`, observed
    /// on a `Foreground`-role process): the default-tap branch used to await
    /// target resolution — by then already doing an IMAP round trip for
    /// the priority sync — before calling `completionHandler()`. A default
    /// tap simultaneously foregrounds the app (the whole point of tapping a
    /// notification body) *and* is, from `UNUserNotificationCenter`'s
    /// perspective, still an in-flight background notification-handling
    /// call until `completionHandler()` fires. Holding that background call
    /// open for a multi-second IMAP connect while the app was already
    /// foregrounding raced UIKit's own foreground/background state-restoration
    /// bookkeeping and tripped an internal assertion. Since then the whole
    /// resolution moved into `PushNotificationOpenView` (so a slow/failed
    /// sync shows a loading/retry screen instead of silently opening
    /// nothing), leaving this branch with nothing async at all: call
    /// `completionHandler()` immediately and post the pending request. The
    /// action-button branch below (`MARK_READ`/`ARCHIVE`) keeps awaiting
    /// its work before calling back — those never foreground the app, so
    /// there's no such race, and `PushNotificationActionHandler
    /// .handle(...)`'s local DB write + best-effort IMAP replay still needs
    /// the OS's background execution window to actually finish before the
    /// process risks being suspended.
    ///
    /// `nonisolated`: this protocol requirement is itself `nonisolated` in
    /// the SDK overlay — an `@MainActor`-isolated override can't satisfy a
    /// `nonisolated` requirement (Swift 6 strict concurrency), and nothing
    /// in this body needs main-actor isolation anyway (it only reads the
    /// immutable `response`/`completionHandler` parameters and calls other
    /// `nonisolated`/free-standing async work).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let payload = Self.parsePayload(response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // See this method's doc comment (v1.3.8 crash) for why this
            // branch calls back immediately and does nothing async —
            // target resolution lives in `PushNotificationOpenView` now.
            completionHandler()
            Task { @MainActor in
                PushNotificationOpenCoordinator.shared.setPendingRequest(accountId: payload.accountId, uidNext: payload.uidNext)
            }
            return
        }

        // `completionHandler`'s type (`() -> Void`, not `@Sendable`) can't
        // prove Sendable-safe capture into `Task {}`'s closure under strict
        // concurrency — `NonSendableCompletionHandlerBox` (below) is the
        // standard `@unchecked Sendable` wrapper for exactly this shape: a
        // plain callback that the OS itself only ever calls once,
        // synchronously, from whatever thread this delegate method already
        // ran on, so there is no real data race here to catch.
        let boxedCompletionHandler = NonSendableCompletionHandlerBox(completionHandler)

        guard let action = Self.action(for: response.actionIdentifier) else {
            completionHandler()
            return
        }
        Task {
            await PushNotificationActionHandler.handle(action: action, accountId: payload.accountId, uidNext: payload.uidNext)
            boxedCompletionHandler.value()
        }
    }

    /// Maps `UNNotificationResponse.actionIdentifier` to the
    /// `SyncEngine.PushNotificationAction` it requests — `nil` for anything
    /// that isn't one of `PushNotificationActionCategory`'s two action
    /// buttons. A plain `static func` (rather than inlined in the delegate
    /// method above) so a unit test can exercise this branching without
    /// constructing a real `UNNotificationResponse`. `nonisolated`: a pure
    /// function touching no main-actor state, and unit tests calling it
    /// directly have no reason to hop to the main actor first.
    nonisolated static func action(for actionIdentifier: String) -> PushNotificationAction? {
        switch actionIdentifier {
        case PushNotificationActionCategory.markReadActionIdentifier:
            .markRead
        case PushNotificationActionCategory.archiveActionIdentifier:
            .archive
        default:
            nil
        }
    }

    /// Byte-for-byte the same logic as `NotificationService.parsePayload(_:)`
    /// (`apps/Otegami/NotificationService/NotificationService.swift`) —
    /// duplicated rather than shared, since an app extension's source files
    /// aren't importable from the app target (that file's own doc comment on
    /// its `private` → `internal` relaxation makes the same point).
    /// `nonisolated` for the same reason as `action(for:)` above.
    nonisolated static func parsePayload(_ userInfo: [AnyHashable: Any]) -> PushNotificationPayload? {
        guard let accountId = userInfo["accountId"] as? String,
              let uidNext = userInfo["uidNext"] as? Int
        else { return nil }
        return PushNotificationPayload(accountId: accountId, uidNext: uidNext)
    }
}

/// A completion-handler-shaped closure (`() -> Void`, not `@Sendable`) can't
/// be proven safe to capture into a `Task {}` closure under Swift 6 strict
/// concurrency's region isolation — this box exists solely to let
/// `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
/// carry `completionHandler` across that boundary. `@unchecked Sendable` is
/// justified the same way it is for every other framework completion
/// handler wrapped this way in this codebase: the OS calls it exactly once,
/// synchronously, and this type never touches `value` from more than one
/// place at a time.
private struct NonSendableCompletionHandlerBox: @unchecked Sendable {
    let value: () -> Void

    init(_ value: @escaping () -> Void) {
        self.value = value
    }
}

/// The real-world implementation of `NotificationPermissionChecking`
/// (`PushRelayClient` module) — the options passed to
/// `requestAuthorization(options:)` are fixed here (`[.alert, .badge,
/// .sound]`, the standard set for a mail app's new-message notifications;
/// no `.provisional`/`.criticalAlert`, which aren't appropriate for this
/// use case).
extension UNUserNotificationCenter: NotificationPermissionChecking {
    public func currentAuthorizationStatus() async -> NotificationAuthorizationStatus {
        switch await notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            .authorized
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await requestAuthorization(options: [.alert, .badge, .sound])
    }
}
#endif
