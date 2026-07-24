#if os(iOS)
import UIKit

/// Bridges `UIApplicationDelegate`'s callback-based APNs device-token
/// registration into a single `async throws` call
/// (`PushSettingsStore.enable(...)` awaits this) — `AppDelegate` below
/// forwards both the success and failure callbacks here.
///
/// M9 constraint (plan/PENDING.md): the iOS **simulator** never actually
/// receives a device token — `UIApplication.registerForRemoteNotifications()`
/// on a simulator either never calls back at all or (depending on OS
/// version) calls the failure delegate method. `requestToken()` doesn't try
/// to special-case this; it simply surfaces whatever the OS reports
/// (usually `.notificationsNotAllowed`-shaped failures or a timeout), and
/// `PushNotificationSettingsView` is the layer that turns "no token" into
/// a "この環境では有効化できません（実機が必要です）" message rather than a
/// crash — see that view's doc comment.
actor PushTokenCenter {
    static let shared = PushTokenCenter()

    enum PushTokenError: Error {
        case registrationFailed(String)
        case timedOut
    }

    private var pendingContinuation: CheckedContinuation<String, Error>?

    private init() {}

    /// Calls `UIApplication.registerForRemoteNotifications()` and awaits
    /// the delegate callback, with a generous timeout (real devices
    /// respond in well under a second when notifications are already
    /// authorized; the simulator either never responds or fails fast, so
    /// this mostly exists to avoid hanging forever there).
    func requestToken(timeoutSeconds: UInt64 = 10) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
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
#endif
