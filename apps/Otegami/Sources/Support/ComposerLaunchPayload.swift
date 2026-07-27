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
        /// `translateToEnglish`: design-phase-3's 1i "英語で返信を下書き" button
        /// (`MessageView`) sets this `true` instead of routing through the
        /// ordinary "返信" — `ComposerView.prepare()` reads it once to
        /// pre-enable the same "英語に翻訳して送る" toggle its own 1k bottom
        /// toolbar exposes (see that view's doc comment), so the two entry
        /// points share one underlying mechanism rather than duplicating
        /// translate-on-send logic. `false` for every other call site
        /// (plain "返信"/"全員に返信", ⌘R, ...).
        case reply(originalMessageId: Int64, replyAll: Bool, translateToEnglish: Bool)
        /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」—
        /// `ComposerView.prepare()` prefixes the subject with `Fwd: `,
        /// quotes the original body (same `> ` quoting `.reply` uses), and
        /// carries the original's attachments over when they can be
        /// fetched (`ComposerView.prefillForward(originalMessageId:)`'s
        /// doc comment covers the attachment-carryover fallback).
        /// Deliberately does **not** set `inReplyToMessageId`/`references`
        /// — forwarding starts a fresh conversation rather than threading
        /// onto the original, unlike `.reply`.
        case forward(originalMessageId: Int64)
        /// M10: resume a saved `DraftMessageRecord`. `ComposerView.prepare()`
        /// loads the row's fields, then deletes it immediately (see
        /// `ComposerView`'s doc comment on why "load transfers ownership" —
        /// a fresh "下書きとして保存" while editing writes a new row rather
        /// than needing update-vs-insert branching).
        case draft(draftId: Int64)
        /// Drafts IMAP sync: resume a server-origin draft — a `message` row
        /// living in a `MailboxRoleRecord.drafts` mailbox that no local
        /// `draftMessage` row has claimed yet (`DraftQuery.UnifiedRow
        /// .server`). Unlike `.draft`, `ComposerView.prepare()` does
        /// **not** delete or otherwise consume anything on load — see
        /// `DraftMessageRecord`'s doc comment for why closing/discarding a
        /// freshly-opened server draft without saving must be a true no-op.
        case serverDraft(messageId: Int64)
        /// C7 送信キャンセル: reopens the Composer with exactly the fields a
        /// just-cancelled pending send had, restored from
        /// `PendingSendDraftSnapshot` — the local outbox row/opQueue op the
        /// send had already durably written were deleted by
        /// `PendingSendCoordinator.cancelPendingSend()` before this payload
        /// is presented, so (unlike `.draft`/`.serverDraft`) there's no
        /// database row left to load from; every field the Composer needs
        /// travels in the payload itself.
        case cancelledSend(PendingSendDraftSnapshot)
        /// Task #48 (デフォルトメールアプリ対応): the OS handed this app a
        /// `mailto:` URL (`OtegamiApp`'s `.onOpenURL`, `MailtoURLParser`
        /// (`OtegamiCore`) already decoded it into plain strings). Its own
        /// case rather than reusing `.new` with optional prefill fields —
        /// every other `Kind` case already prefers "a dedicated case with
        /// exactly the fields that trigger matter" over one catch-all case
        /// with a pile of optionals, and a mailto open is a genuinely
        /// distinct trigger (external app/OS, not a button inside this
        /// app).
        case mailto(MailtoComposePrefill)
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

    static func reply(originalMessageId: Int64, replyAll: Bool, translateToEnglish: Bool = false) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .reply(originalMessageId: originalMessageId, replyAll: replyAll, translateToEnglish: translateToEnglish))
    }

    static func forward(originalMessageId: Int64) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .forward(originalMessageId: originalMessageId))
    }

    static func draft(draftId: Int64) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .draft(draftId: draftId))
    }

    static func serverDraft(messageId: Int64) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .serverDraft(messageId: messageId))
    }

    static func cancelledSend(_ snapshot: PendingSendDraftSnapshot) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .cancelledSend(snapshot))
    }

    static func mailto(_ prefill: MailtoComposePrefill) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .mailto(prefill))
    }
}

/// Task #48: `ComposerView.prepare()`'s prefill for `.mailto` — plain
/// `String` address lists (not `[EmailAddress]`) since `ComposerView`'s
/// To/Cc/Bcc fields are themselves plain comma-separated text (this file's
/// own doc comment on `parseAddresses(_:)`); joining these with `", "`
/// lands directly in `toText`/`ccText`/`bccText` with no further
/// conversion needed.
struct MailtoComposePrefill: Codable, Hashable, Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
}

/// C7: everything `ComposerView` needs to restore a just-cancelled pending
/// send's fields — captured by `ComposerView.send()` right before staging
/// attachments/writing the durable outbox row, so cancelling never needs to
/// re-read anything off disk or out of GRDB (the outbox row is deleted by
/// the time this is presented — see `ComposerLaunchPayload.Kind
/// .cancelledSend`'s doc comment).
struct PendingSendDraftSnapshot: Codable, Hashable, Sendable {
    var accountId: String
    var toText: String
    var ccText: String
    /// Task #48: added alongside `ComposerView.bccText` — see that
    /// property's doc comment for why Bcc has full send-path support but
    /// (deliberately) no draft-save support.
    var bccText: String
    var subject: String
    var bodyText: String
    var inReplyToMessageId: String?
    var references: [String]
    var translateToEnglishBeforeSend: Bool
    var attachments: [PendingAttachment]
    var draftServerMailboxId: Int64?
    var draftServerUid: Int64?
    var draftServerUidValidity: Int64?
}
