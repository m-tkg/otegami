import Foundation

/// What to open `ComposerView` with: a brand-new message, or a reply to an
/// existing one (plan: "ツールバー「作成」ボタン" for new, per-message "返信"/
/// "全員に返信" for reply). `Codable`/`Hashable` so macOS can pass it as a
/// `WindowGroup(for:)` value (each compose action opens its own window);
/// `Identifiable` (a fresh `UUID` per construction) so iOS can drive it as a
/// `.sheet(item:)` — a second "作成" tap while one composer sheet is already
/// up should present a distinct one, not be coalesced by SwiftUI's identity
/// diffing into reusing the dismissed one's state.
struct ComposerLaunchPayload: Identifiable, Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case new
        case reply(originalMessageId: Int64, replyAll: Bool)
        /// M10: resume a saved `DraftMessageRecord`. `ComposerView.prepare()`
        /// loads the row's fields, then deletes it immediately (see
        /// `ComposerView`'s doc comment on why "load transfers ownership" —
        /// a fresh "下書きとして保存" while editing writes a new row rather
        /// than needing update-vs-insert branching).
        case draft(draftId: Int64)
    }

    var id = UUID()
    var kind: Kind

    // A computed property, not `static let` — a `static let` only ever runs
    // its initializer once and caches the result, so every `.new` reference
    // would share one fixed `id` for the process's entire lifetime. That's
    // fine for `Identifiable`'s sake on iOS (`.sheet(item:)` tears the whole
    // `ComposerView` down on dismiss regardless of `id`), but on macOS,
    // `WindowGroup(for:)` keys a window's identity/state off this value's
    // `Hashable` conformance (which includes `id`) — repeated ⌘N/「作成」
    // presses would all resolve to the *same* identity, and a fresh
    // `openWindow(id: "composer", value: .new)` call could resurrect a
    // previous (already-closed) composer session's stale `@State` (typed
    // text, `initialSnapshot`) instead of starting blank. Confirmed via
    // macOS QA sweep: open a new composer, type a recipient, discard it,
    // then ⌘N again — the "fresh" composer's To field carried over the
    // discarded one's text. A computed property gives every call site a
    // distinct `id`, so each new-message request is genuinely its own
    // identity.
    static var new: ComposerLaunchPayload { ComposerLaunchPayload(kind: .new) }

    static func reply(originalMessageId: Int64, replyAll: Bool) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .reply(originalMessageId: originalMessageId, replyAll: replyAll))
    }

    static func draft(draftId: Int64) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .draft(draftId: draftId))
    }
}
