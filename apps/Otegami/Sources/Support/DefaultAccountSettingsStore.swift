import Foundation

/// G「デフォルトのアカウント」: which account `ComposerView.prepare()` preselects
/// for a brand-new message (`ComposerLaunchPayload.Kind.new` only — a
/// reply/forward/draft always preselects whatever account the original
/// message/draft belongs to, never this setting). Raw `AccountRecord.id`
/// string, empty when unset (`@AppStorage` has no ergonomic `String?`
/// storage — same "plain `UserDefaults` key, empty string means unset"
/// pattern `LinkBrowserSettingsStore`/`SwipeActionSettingsStore` already use
/// elsewhere in this directory).
///
/// **Not validated against the current account list here** — an account can
/// be deleted after being picked as default, or synced away on another
/// device. `ComposerView.prepare()` falls back to `environment.accounts
/// .first?.id` whenever the stored id doesn't match any current account,
/// so a stale value never blocks composing, it just silently reverts to the
/// pre-existing "first account" behavior until the user picks a new default
/// (or a matching account reappears).
enum DefaultAccountSettingsStore {
    static let defaultAccountIdKey = "account.defaultAccountId"
}
