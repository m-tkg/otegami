import Foundation

/// C7 「メール内リンクを開くブラウザ」— iOS only in practice: `SFSafariViewController`
/// (the "in-app browser" option) is an iOS/iPadOS-only API, so this setting
/// has nothing to toggle on macOS. `AccountsListContent` only shows the
/// picker `#if os(iOS)`; `HTMLMessageView`'s link handler on macOS always
/// opens the system default browser (`NSWorkspace.shared.open(_:)`)
/// regardless of this key's value — the same "macOS has no equivalent, so
/// it isn't offered there" pattern `SwipeActionSettingsStore` already
/// established for a different iOS-only affordance.
///
/// Default **in-app browser**: mail links are usually a quick "let me
/// check this" detour, not the start of real browsing — staying inside
/// the app (no context switch, a natural "Done" button back to the
/// message) fits that better than backgrounding otegami into Safari for
/// every tapped link. The setting exists precisely for anyone who'd
/// rather always land in their full browser (extensions, saved
/// passwords, reading list, ...) instead.
enum LinkBrowserSettingsStore {
    static let openInAppBrowserKey = "links.openInAppBrowser"
    static let defaultOpenInAppBrowser = true
}
