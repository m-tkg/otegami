import OtegamiRelayAPI

/// Abstraction over "deliver this payload to this device via APNs" — kept
/// as a protocol (plan/M9 constraint: no real `.p8` key is available yet,
/// see `PENDING.md`) so `WatcherPool` and its tests never depend on
/// `APNsSender` specifically. Three implementations:
///
/// - `APNsSender`: real token-based (.p8/JWT) HTTP/2 delivery. Untestable
///   here (no key), but self-contained and exercised by its own
///   JWT/payload-construction unit tests.
/// - `ConsolePushSender`: logs what *would* have been sent — the default
///   when `APNS_*` env vars aren't configured (docker-compose fallback).
/// - `FakePushSender` (test target only): records calls for
///   `WatcherPoolTests` to assert against.
protocol PushSending: Sendable {
    /// Sends `payload` to `deviceToken`. Implementations should not throw
    /// for ordinary APNs-reported delivery failures (e.g. an expired
    /// token) — `WatcherPool` isn't in a position to usefully react to
    /// send failures beyond logging them, so implementations log instead
    /// and only throw for programmer-error-shaped conditions (bad
    /// configuration).
    func send(deviceToken: String, environment: RegisterDeviceRequest.Environment, payload: PushNotificationPayload) async throws
}
