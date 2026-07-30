import Foundation

/// Reads `OTEGAMI_RELAY_REGISTRATION_SECRET` from `Info.plist` — itself
/// expanded at build time from the `OTEGAMI_RELAY_REGISTRATION_SECRET`
/// xcconfig build setting (`Config/Shared.xcconfig` defines it empty by
/// default; `Config/Local.xcconfig`, git-ignored, is where a self-hoster
/// sets their own — see `docs/relay-deployment.md`). Same mechanism as
/// `GoogleOAuthConfig`/`MicrosoftOAuthConfig`.
///
/// Task #171 originally had `PushNotificationSettingsView` ask *every*
/// user to type this in a `SecureField` before enabling push notifications
/// — a 2026-07-30 実機フィードバック correctly called this out as
/// un-mail-app-like ("アプリ側でシークレット登録とかなしで通知を受けたい。
/// なぜなら、通常のメールアプリはそんなことをしないから"): an ordinary
/// user of someone else's relay never needs to know this value exists, and
/// the person who *is* the relay's operator already has to edit
/// `Config/Local.xcconfig`/a CI secret to build a signed app at all, so
/// folding this one more relay-side value into that same build-time step
/// removes a user-facing setting instead of just hiding it behind another
/// screen.
enum RelayRegistrationSecretConfig {
    /// `nil` when unset/empty — the OSS-default state (no
    /// `Config/Local.xcconfig` override, or the relay this build talks to
    /// doesn't require `RELAY_DEVICE_REGISTRATION_SECRET` at all).
    /// `PushRelayClient.registerDevice`'s `registrationSecret: String? =
    /// nil` parameter already treats `nil` as "omit the `Authorization`
    /// header," so a build that never sets this is unaffected.
    static var value: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_RELAY_REGISTRATION_SECRET") as? String,
              !value.isEmpty,
              // Same xcodegen edge case `GoogleOAuthConfig.clientId` guards
              // against — a build system that skips Info.plist variable
              // substitution leaves the literal `$(...)` placeholder in
              // place, which must not be treated as a real secret.
              !value.hasPrefix("$(")
        else {
            return nil
        }
        return value
    }

    static var isConfigured: Bool { value != nil }
}
