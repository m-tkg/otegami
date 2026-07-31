import Foundation

/// Reads `OTEGAMI_PUSH_RELAY_URL` from `Info.plist` — itself expanded at
/// build time from the `OTEGAMI_PUSH_RELAY_URL` xcconfig build setting
/// (`Config/Shared.xcconfig` defines it empty by default;
/// `Config/Local.xcconfig`, git-ignored, is where a self-hoster sets their
/// own — see `docs/relay-deployment.md`). Same mechanism as
/// `RelayRegistrationSecretConfig`/`GoogleOAuthConfig`/`MicrosoftOAuthConfig`.
///
/// Task #173 follow-up (実機フィードバック 2026-07-30: 「リレー URL は今の
/// 固定 URL という話をしたよ」): `RelayRegistrationSecretConfig` moved the
/// registration secret to a build-time value but left the relay URL itself
/// as a `PushNotificationSettingsView` text field — half-finished, since an
/// ordinary mail app user shouldn't need to know a "relay URL" is a thing
/// either. This value now follows the same build-time path, so
/// `PushNotificationSettingsView` has nothing left to type at all: just the
/// ON/OFF toggle (Task #212 — a plain button pair before that) plus
/// (Task #173) the per-account watch status list.
enum RelayURLConfig {
    /// `nil` when unset/empty — the OSS-default state (no
    /// `Config/Local.xcconfig` override). `PushNotificationSettingsView`
    /// disables its enable toggle and explains why when this is `nil`, the
    /// same way `GoogleOAuthConfig.isConfigured == false` disables the
    /// Gmail add-account button.
    static var value: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_PUSH_RELAY_URL") as? String,
              !raw.isEmpty,
              // Same xcodegen edge case `GoogleOAuthConfig.clientId` guards
              // against — a build system that skips Info.plist variable
              // substitution leaves the literal `$(...)` placeholder in
              // place, which must not be treated as a real URL.
              !raw.hasPrefix("$(")
        else {
            return nil
        }
        // `AppEnvironment.validatedRelayURL(_:)` is the single source of
        // truth for "is this a URL we'll actually talk to" (https://
        // required; http://localhost / http://127.0.0.1 exempted for
        // local dev) — reused here rather than duplicated, so a
        // misconfigured Local.xcconfig (e.g. the `//`-is-a-comment
        // xcconfig pitfall this build setting's own doc comment in
        // Config/Shared.xcconfig warns about, truncating the value to
        // `https:`) fails the same validation an end user's typed-in URL
        // used to fail, instead of silently reaching `PushRelayClient`
        // with a broken value.
        return AppEnvironment.validatedRelayURL(raw)
    }

    static var isConfigured: Bool { value != nil }
}
