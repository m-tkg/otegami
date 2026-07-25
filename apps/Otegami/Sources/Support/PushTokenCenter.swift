#if os(iOS)
import UIKit
import UserNotifications
import PushRelayClient

/// Bridges `UIApplicationDelegate`'s callback-based APNs device-token
/// registration into a single `async throws` call
/// (`PushSettingsStore.enable(...)` awaits this) — `AppDelegate` below
/// forwards both the success and failure callbacks here.
///
/// M9 bug fix (see `docs/verify.md`'s "M9 追補" section and
/// `docs/qa-findings.md`): `requestToken()` used to call *only*
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
/// M9 constraint (plan/PENDING.md) still holds independently of the above:
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

/// Minimal `UIApplicationDelegate` — only exists to receive the two APNs
/// registration callbacks and forward them to `PushTokenCenter`. Wired via
/// `@UIApplicationDelegateAdaptor` in `OtegamiApp`.
final class AppDelegate: NSObject, UIApplicationDelegate {
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
