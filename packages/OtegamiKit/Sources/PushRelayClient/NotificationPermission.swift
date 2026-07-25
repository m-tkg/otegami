import Foundation

/// The three states `UNAuthorizationStatus` practically boils down to from
/// `PushTokenCenter`'s perspective — the real enum has five cases
/// (`.notDetermined`/`.denied`/`.authorized`/`.provisional`/`.ephemeral`);
/// `.provisional` and `.ephemeral` both already let remote-notification
/// registration proceed without any further prompting, so they fold into
/// `.authorized` here.
public enum NotificationAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// What `PushTokenCenter.requestToken()` should do next, after resolving
/// the current (or just-requested) authorization state.
public enum NotificationPermissionOutcome: Sendable, Equatable {
    /// Proceed to `UIApplication.registerForRemoteNotifications()`.
    case granted
    /// Stop — the caller should surface
    /// `AppEnvironment.PushError.notificationPermissionDenied` rather than
    /// attempting device-token registration (which would just silently
    /// never call back once notifications are denied).
    case denied
}

/// Abstraction over `UNUserNotificationCenter` narrow enough to unit-test
/// `NotificationPermissionResolver` without linking `UserNotifications`
/// into this package's test target — mirrors the two calls
/// `PushTokenCenter` actually needs
/// (`notificationSettings().authorizationStatus` and
/// `requestAuthorization(options:)`). The app target's `PushTokenCenter.swift`
/// conforms `UNUserNotificationCenter` to this protocol via a small
/// extension (options are fixed there: `[.alert, .badge, .sound]`).
public protocol NotificationPermissionChecking: Sendable {
    func currentAuthorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
}

/// The permission decision `PushTokenCenter.requestToken()` applies
/// *before* ever calling `registerForRemoteNotifications()` (M9 bug fix —
/// previously the app never called `UNUserNotificationCenter
/// .requestAuthorization` at all, so push notifications silently never
/// displayed even once APNs delivered them; see `docs/verify.md`'s "M9
/// 追補" section and `docs/qa-findings.md`):
///
/// - `.authorized` (already granted — e.g. re-enabling push after an
///   earlier session, or notifications were authorized some other way):
///   proceed immediately, no prompt.
/// - `.denied` (user said no previously): stop *without* calling
///   `requestAuthorization` again — iOS never re-prompts once denied, so
///   calling it would just silently return `false`; querying status first
///   lets the caller short-circuit straight to "point the user at
///   Settings" without even needing that round trip.
/// - `.notDetermined`: the only state where a system prompt is actually
///   shown; the eventual user choice decides the outcome. A thrown error
///   from `requestAuthorization()` (some OS versions can throw rather than
///   return `false` for certain denial paths) is folded into `.denied` too
///   — the caller only needs the binary "may proceed" / "stop" signal.
///
/// Extracted here — rather than left inline in the `#if os(iOS)`-gated
/// `PushTokenCenter` actor, which has no unit-test target of its own (see
/// `NotificationEnrichment`'s doc comment for the same reasoning applied to
/// the notification title/body rewrite) — purely so it's exercisable by
/// `swift test` (`NotificationPermissionResolverTests`).
public enum NotificationPermissionResolver {
    public static func resolve(using checker: some NotificationPermissionChecking) async -> NotificationPermissionOutcome {
        switch await checker.currentAuthorizationStatus() {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            let granted = (try? await checker.requestAuthorization()) ?? false
            return granted ? .granted : .denied
        }
    }
}
