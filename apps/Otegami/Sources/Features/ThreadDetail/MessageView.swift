import Foundation
import SwiftUI
import QuickLook
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import GRDB
import OtegamiTranslation
import TranslationEngine

/// Single-message reading view (M2's "ThreadDetail"; real multi-message
/// thread collapsing lands in M4). Shows the header, then the body: if
/// `message.bodyState` is already `.fetched`, reads straight from
/// `messageBody` (works offline); otherwise fetches it over IMAP via
/// `SyncCoordinator.fetchBody`, showing a spinner meanwhile.
///
/// Takes `messageId` rather than an already-loaded `MessageRecord`: the id
/// is what `MessageListView`'s `List(selection:)` binding (and `RootView`'s
/// "last opened message" restoration) naturally deal in, and re-reading
/// the row here means this view always reflects the current database state
/// (e.g. a flag change from another source) rather than a snapshot passed
/// in at selection time.
struct MessageView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Which account to authenticate against for a lazy body fetch —
    /// derived from `message.mailboxId` for everything else (M4: a message
    /// embedded in `ThreadDetailView` doesn't necessarily belong to
    /// whichever mailbox the sidebar has selected, e.g. the unified inbox
    /// or a thread that spans mailboxes), so this is the one piece of
    /// context a caller must still supply.
    let accountId: String
    let messageId: Int64
    /// M5/design-phase-3: invoked with `(messageId, replyAll,
    /// translateToEnglish)` when the reply/reply-all/"英語で返信を下書き"
    /// buttons at the bottom of this message are tapped. Presentation
    /// itself (sheet on iOS, a separate window on macOS) is `RootView`'s
    /// job — see `SidebarView.onCompose`'s doc comment for the same
    /// pattern. `translateToEnglish` is always `false` for 返信/全員に返信;
    /// see `ComposerLaunchPayload.Kind.reply`'s doc comment for what it
    /// does downstream.
    var onReply: (Int64, Bool, Bool) -> Void = { _, _, _ in }

    /// B5 — see `ListDisplaySettingsStore.showAvatarInDetailKey`'s doc
    /// comment on why this is read directly via `@AppStorage`.
    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatarInDetail = ListDisplaySettingsStore.defaultShowAvatarInDetail

    // MARK: - HTML/text display (A9)

    /// A9-2 「常にテキストで表示」 — see `HTMLDisplaySettingsStore`'s doc comment.
    /// This is only the *default*; `manualPreferPlainText` (below) lets a
    /// single open message override it in either direction via the toggle
    /// button next to `HTMLBadge`.
    @AppStorage(HTMLDisplaySettingsStore.alwaysShowPlainTextKey) private var alwaysShowPlainText = HTMLDisplaySettingsStore.defaultAlwaysShowPlainText
    /// `nil` until the toggle button (`toggleHTMLTextButton`) is tapped for
    /// *this* message — reset in `load()` so switching to a different
    /// message never carries a previous message's manual choice forward.
    @State private var manualPreferPlainText: Bool?

    @State private var message: MessageRecord?
    @State private var bodyRecord: MessageBodyRecord?
    /// M8: the mailbox path `message` lives in — resolved once during
    /// `load()` (same `MailboxRecord` lookup `fetchBodyOverNetwork` already
    /// does for the body itself) and kept around so the attachment section
    /// and `HTMLMessageView`'s cid image resolver don't each need to
    /// re-derive it.
    @State private var mailboxPath: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var attachments: [AttachmentRecord] = []
    /// M8: which attachment (by id) is currently being downloaded on-demand
    /// — drives that row's spinner. A `Set` rather than a single optional
    /// id since a user could plausibly tap two attachment rows in quick
    /// succession.
    @State private var fetchingAttachmentIds: Set<Int64> = []
    @State private var attachmentErrorMessage: String?
    /// M8: the attachment currently shown in the `.quickLookPreview` sheet
    /// — `nil` means no preview is presented.
    @State private var previewURL: URL?

    // MARK: - Translation (design-phase-3, 1i)

    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) private var autoTranslateEnglish = true
    @State private var translationState: MessageTranslationState = .none
    /// The bar's 訳文/原文 segment — `false` (訳文) is the handoff's
    /// explicit default ("既定は訳文").
    @State private var translationShowOriginal = false
    /// `TranslatedBodyView.originalOverrides` — per-paragraph long-press
    /// state, reset alongside everything else in `load()`.
    @State private var translationParagraphOverrides: Set<Int> = []
    @State private var translateTask: Task<Void, Never>?

    /// Only a message `SyncEngine.BodyFetcher` tagged English gets a bar at
    /// all (plan: "英文メールのみ翻訳バーを出す") — `nil`/any other BCP-47 code
    /// (including "ja", or a message whose body hasn't been fetched/
    /// detected yet) shows nothing rather than an always-disabled bar for
    /// every message.
    private var isEnglishMessage: Bool {
        message?.detectedLanguage == "en"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                header(for: message)
                    .padding()
                // 1i: "件名 → 送信者行 → 翻訳バー → 本文" — right after the
                // header (subject/from/to/date), before attachments/body.
                if isEnglishMessage {
                    TranslationBar(
                        state: translationState,
                        showOriginal: $translationShowOriginal,
                        isAvailable: environment.isTranslationAvailable,
                        onTranslate: { requestTranslation(message: message) }
                    )
                }
                if !attachments.isEmpty {
                    attachmentSection
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                Divider()
            }
            // HTML bodies scroll internally (inside `HTMLMessageView`'s own
            // `WKWebView`) and need the remaining space handed to them
            // directly; plain-text bodies get their own `ScrollView` below
            // instead of wrapping the header in one too, so a long HTML
            // message never ends up nested inside two independent
            // scrollers.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let message {
                Divider()
                replyBar(for: message)
                    .padding()
            }
        }
        .accessibilityIdentifier("messageDetail.scrollView")
        .navigationTitle(displaySubject)
        .task(id: messageId) { await load() }
        // M8: QuickLook, shared across platforms via SwiftUI's own
        // modifier rather than a `QLPreviewController`/`QLPreviewPanel`
        // wrapper per platform — see `openAttachment(_:)`'s doc comment.
        .quickLookPreview($previewURL)
    }

    private var displaySubject: String {
        message?.subject?.isEmpty == false ? message!.subject! : "(件名なし)"
    }

    private func header(for message: MessageRecord) -> some View {
        HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
            // B5 「本文にも送信者アイコンを出せるように」— see
            // `ListDisplaySettingsStore.showAvatarInDetailKey`'s doc comment.
            if showAvatarInDetail {
                SenderAvatar(
                    displayName: message.fromAddresses.first?.name,
                    address: message.fromAddresses.first?.address ?? "",
                    accountId: accountId,
                    diameter: 36
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: OtegamiSpacing.xs) {
                    Text(displaySubject)
                        .font(.title2)
                        .bold()
                        .accessibilityIdentifier("messageDetail.subject")
                    // A9-1: a subdued flag that this message *is* HTML —
                    // independent of `isShowingHTML` below (still shown even
                    // while the toggle has switched this message to its
                    // text rendering).
                    if isHTMLMessage {
                        HTMLBadge()
                    }
                }
                Text(addressListText(message.fromAddresses, prefix: "From"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("messageDetail.from")
                if !message.toAddresses.isEmpty {
                    Text(addressListText(message.toAddresses, prefix: "To"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("messageDetail.to")
                }
                Text(message.date ?? message.internalDate, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("messageDetail.date")
                // A9-2: only offered for messages that actually have an
                // HTML body to switch away from/back to — see
                // `isShowingHTML`'s doc comment for what toggling flips.
                if isHTMLMessage {
                    Button(isShowingHTML ? "テキストで表示" : "HTMLで表示") {
                        manualPreferPlainText = isShowingHTML
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .tint(OtegamiColor.accent)
                    .accessibilityIdentifier("messageDetail.toggleHTMLTextButton")
                }
            }
        }
    }

    /// A9-1/A9-4: whether `bodyRecord` has an HTML part with genuinely
    /// visible content — the badge and the HTML/text toggle button both
    /// gate on this, regardless of which rendering is currently chosen.
    ///
    /// Not just "is `html` a non-empty string": a message with no real body
    /// at all (`18-empty-body.eml`'s fixture, confirmed by an actual
    /// simulator run) still comes back from MailCore2's `htmlBodyRendering()`
    /// as a non-empty (but tag-only, no visible text or media) HTML
    /// document — treating that as "an HTML message" would show the "HTML"
    /// badge and a genuinely blank `WKWebView` instead of A9-4's "本文なし"
    /// placeholder. `HTMLTextExtractor` finding no text is *not* enough on
    /// its own to call the HTML empty, though — an image-only HTML message
    /// (no text, but a real `<img>` to show) is legitimate HTML content, so
    /// this only treats HTML as empty when it has neither extractable text
    /// nor any `<img` tag.
    private var isHTMLMessage: Bool {
        guard let html = bodyRecord?.html, !html.isEmpty else { return false }
        if HTMLTextExtractor.plainText(fromHTML: html).isEmpty, !html.localizedCaseInsensitiveContains("<img") {
            return false
        }
        return true
    }

    /// A9-2: the effective choice between the HTML (`WKWebView`) and
    /// text rendering for *this* message right now — `manualPreferPlainText`
    /// (set by the toggle button) wins when present, otherwise falls back to
    /// the "常にテキストで表示" setting's default. Always `true` (irrelevant)
    /// for a non-HTML message; callers only consult this after already
    /// checking `isHTMLMessage`/`bodyRecord.html`.
    private var isShowingHTML: Bool {
        !(manualPreferPlainText ?? alwaysShowPlainText)
    }

    /// A9-2: the text rendering an HTML message falls back to when
    /// `isShowingHTML` is `false` — the message's own `text/plain` part if
    /// it has one (a real author-provided plain-text alternative), otherwise
    /// `HTMLTextExtractor`'s output from the HTML (same extractor
    /// `ComposerView`'s reply-quoting and the translation source already
    /// use, so this doesn't introduce a second HTML-to-text implementation).
    private func plainTextFallback(for bodyRecord: MessageBodyRecord) -> String? {
        if let plainText = bodyRecord.plainText, !plainText.isEmpty { return plainText }
        if let html = bodyRecord.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }

    /// 1i: "下部: 「返信」と「英語で返信を下書き」を対で置く（翻訳を読み専用機能にしない）"
    /// — moved out of the header (M2–design-phase-2 had 返信/全員に返信 there)
    /// to the bottom, below the body, with 返信 and 英語で返信を下書き placed
    /// directly adjacent per that instruction; 全員に返信 stays reachable but
    /// visually separated (`Spacer()`) rather than a three-way tie, since
    /// the handoff only calls out the first pair explicitly.
    /// "英語で返信を下書き" only appears when translation is actually usable on
    /// this device (`AppEnvironment.isTranslationAvailable`) — there's no
    /// point offering an entry point that can only fail once tapped.
    private func replyBar(for message: MessageRecord) -> some View {
        HStack {
            Button {
                onReply(messageId, false, false)
            } label: {
                Label("返信", systemImage: "arrowshape.turn.up.left")
            }
            .accessibilityIdentifier("messageDetail.replyButton")

            if environment.isTranslationAvailable {
                Button {
                    onReply(messageId, false, true)
                } label: {
                    Label("英語で返信を下書き", systemImage: "globe")
                }
                .accessibilityIdentifier("messageDetail.draftEnglishReplyButton")
            }

            Spacer(minLength: OtegamiSpacing.sm)

            Button {
                onReply(messageId, true, false)
            } label: {
                Label("全員に返信", systemImage: "arrowshape.turn.up.left.2")
            }
            .accessibilityIdentifier("messageDetail.replyAllButton")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(OtegamiColor.accent)
    }

    // MARK: - Attachments (M8)

    /// Inline (`cid:`-referenced) parts are excluded — those render inside
    /// `HTMLMessageView`'s body itself (via the `otegami-cid://` scheme
    /// handler), so listing them again here as a separate downloadable row
    /// would be confusing/redundant. Only genuine "here's a file" parts
    /// show up in this list.
    private var listableAttachments: [AttachmentRecord] {
        attachments.filter { !$0.isInline }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(listableAttachments) { attachment in
                attachmentRow(attachment)
            }
            if let attachmentErrorMessage {
                Text(attachmentErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("messageDetail.attachmentError")
            }
        }
        .accessibilityIdentifier("messageDetail.attachments")
    }

    private func attachmentRow(_ attachment: AttachmentRecord) -> some View {
        let attachmentId = attachment.id ?? 0
        return Button {
            Task { await openAttachment(attachment) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.iconName(for: attachment))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename?.isEmpty == false ? attachment.filename! : "添付ファイル")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(Self.formattedSize(attachment.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if fetchingAttachmentIds.contains(attachmentId) {
                    ProgressView()
                        .accessibilityIdentifier("messageDetail.attachment.\(attachmentId).loading")
                } else if let localPath = attachment.localPath {
                    // 保存 (plan: "iOS: ShareLink / fileExporter、macOS: 保存
                    // パネル") — `ShareLink` works on both platforms (a
                    // share sheet on iOS, `NSSharingServicePicker` — which
                    // includes "Save to Downloads"/"Save As…" style services
                    // — on macOS), so one cross-platform control covers
                    // both rather than diverging per platform here.
                    ShareLink(item: URL(fileURLWithPath: localPath)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("messageDetail.attachment.\(attachmentId).shareButton")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityIdentifier("messageDetail.attachment.\(attachmentId)")
    }

    private static func iconName(for attachment: AttachmentRecord) -> String {
        switch attachment.mimeType.lowercased() {
        case "image": "photo"
        case "video": "film"
        case "audio": "waveform"
        case "application" where attachment.mimeSubtype.lowercased() == "pdf": "doc.richtext"
        default: "doc"
        }
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Tapping an attachment row: already-downloaded (`localPath` points at
    /// a file that still exists) opens QuickLook immediately; otherwise
    /// fetches it first (with `fetchingAttachmentIds` driving that row's
    /// spinner — plan: "タップ → 未取得ならスピナー付き取得 → QuickLook プレビュー"),
    /// then opens it. `.quickLookPreview($previewURL)` (SwiftUI's own
    /// modifier, available on both iOS and macOS since it was introduced)
    /// is used over a hand-rolled `QLPreviewController`/`QLPreviewPanel`
    /// wrapper per platform — simpler, and it's exactly the single-URL case
    /// this view needs (one attachment previewed at a time, no "next/
    /// previous" browsing across the whole attachment list).
    private func openAttachment(_ attachment: AttachmentRecord) async {
        guard let attachmentId = attachment.id else { return }
        attachmentErrorMessage = nil

        if let localPath = attachment.localPath, FileManager.default.fileExists(atPath: localPath) {
            previewURL = URL(fileURLWithPath: localPath)
            return
        }
        guard !fetchingAttachmentIds.contains(attachmentId) else { return }

        fetchingAttachmentIds.insert(attachmentId)
        defer { fetchingAttachmentIds.remove(attachmentId) }

        do {
            let updated = try await fetchAttachmentOverNetwork(attachment)
            if let index = attachments.firstIndex(where: { $0.id == attachmentId }) {
                attachments[index] = updated
            }
            if let localPath = updated.localPath {
                previewURL = URL(fileURLWithPath: localPath)
            } else {
                attachmentErrorMessage = "添付ファイルの取得に失敗しました。"
            }
        } catch {
            attachmentErrorMessage = "添付ファイルの取得に失敗しました: \(error)"
        }
    }

    private func fetchAttachmentOverNetwork(_ attachment: AttachmentRecord) async throws -> AttachmentRecord {
        guard let message, let mailboxPath else { throw MailTransportError.notConnected }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            throw MailTransportError.authenticationFailed(underlyingDescription: "資格情報が見つかりません")
        }
        return try await environment.syncCoordinator.fetchAttachment(
            attachment, messageUID: message.uid, mailboxPath: mailboxPath, account: account, auth: auth
        )
    }

    private func addressListText(_ addresses: [EmailAddress], prefix: String) -> String {
        let formatted = addresses.map { $0.name?.isEmpty == false ? "\($0.name!) <\($0.address)>" : $0.address }
        return "\(prefix): \(formatted.joined(separator: ", "))"
    }

    @ViewBuilder
    private var content: some View {
        // 1i: "訳文" showing and a translation actually cached — render the
        // per-paragraph translated view instead of the normal HTML/plain-
        // text body. Every other state (still translating, failed, "原文"
        // selected, or not an English message at all) falls through to the
        // original rendering untouched below — the translation feature
        // never changes what a non-English or not-yet-translated message
        // looks like.
        if isEnglishMessage, !translationShowOriginal, case .translated(let record) = translationState {
            TranslatedBodyView(paragraphs: record.paragraphs, originalOverrides: $translationParagraphOverrides)
        } else if isLoading {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("本文を取得しています…")
                        .accessibilityIdentifier("messageDetail.loadingIndicator")
                    Spacer()
                }
                Spacer()
            }
        } else if let bodyRecord {
            // A9-2: an HTML message only actually renders `HTMLMessageView`
            // when `isShowingHTML` — the "常にテキストで表示" setting or this
            // message's own toggle button can route it through the plain-
            // text branch below instead, using `plainTextFallback(for:)`
            // (the message's real `text/plain` part if it has one, else
            // `HTMLTextExtractor`'s output) exactly the way a message with
            // no HTML part at all already does.
            if isHTMLMessage, isShowingHTML, let html = bodyRecord.html {
                HTMLMessageView(html: html, accountId: accountId, messageId: messageId, mailboxPath: mailboxPath)
                    .accessibilityIdentifier("messageDetail.htmlBody")
            } else if let plainText = plainTextFallback(for: bodyRecord) {
                ScrollView {
                    linkifiedText(plainText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("messageDetail.plainTextBody")
                }
            } else {
                // A9-4: shown whenever there is genuinely no body content at
                // all (no HTML, no `text/plain`, and — for an HTML message
                // switched to text — no extractable text either) — a light,
                // clearly-secondary label rather than leaving the space
                // blank, per the design system's `inkTertiary` token
                // ("薄いテキスト（無効/キャプション寄り）").
                Text("本文なし")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .padding()
                    .accessibilityIdentifier("messageDetail.emptyBody")
            }
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding()
                .accessibilityIdentifier("messageDetail.errorMessage")
        }
    }

    // MARK: - Loading

    private func load() async {
        errorMessage = nil
        bodyRecord = nil
        message = nil
        mailboxPath = nil
        attachments = []
        attachmentErrorMessage = nil
        previewURL = nil
        manualPreferPlainText = nil
        resetTranslationState()

        guard let loadedMessage = try? await environment.database.dbWriter.read({ db in
            try MessageRecord.fetchOne(db, key: messageId)
        }) else {
            errorMessage = "メッセージが見つかりません。"
            return
        }
        message = loadedMessage
        mailboxPath = try? await environment.database.dbWriter.read { db in
            try MailboxRecord.fetchOne(db, key: loadedMessage.mailboxId)?.path
        }
        attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []

        if loadedMessage.bodyState == .fetched, let existing = try? await fetchBodyRecord(messageId: messageId) {
            bodyRecord = existing
            markAsReadIfNeeded()
            kickoffTranslationIfNeeded(message: loadedMessage)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetchBodyOverNetwork(message: loadedMessage)
            bodyRecord = try await fetchBodyRecord(messageId: messageId)
            // M2's body fetch also replaces `attachment` rows for this
            // message (`BodyFetcher.fetchBody`) — re-read so a message
            // opened for the first time shows its attachment list too, not
            // just the (empty, pre-fetch) snapshot read above.
            attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []
            // design-phase-3: `SyncEngine.BodyFetcher` also sets
            // `detectedLanguage` as part of this same fetch — `loadedMessage`
            // predates it (read *before* the fetch even started), so the
            // translation bar's `isEnglishMessage` check needs the freshly
            // re-read row, not the stale one, or a message opened for the
            // first time (the common case: body not fetched yet) would
            // never show a translation bar on its first open. Caught by a
            // real XCUITest run, not by inspection — `docs/verify.md`'s
            // translation section.
            let refreshed = (try? await environment.database.dbWriter.read { db in
                try MessageRecord.fetchOne(db, key: messageId)
            }) ?? loadedMessage
            message = refreshed
            markAsReadIfNeeded()
            kickoffTranslationIfNeeded(message: refreshed)
        } catch {
            // Offline (or any other network failure): fall back to
            // whatever's already in the local database — a `.fetching`
            // message left mid-flight by a previous attempt can still have
            // no row yet, in which case there's genuinely nothing to show.
            if let existing = try? await fetchBodyRecord(messageId: messageId) {
                bodyRecord = existing
                markAsReadIfNeeded()
                kickoffTranslationIfNeeded(message: loadedMessage)
            } else {
                errorMessage = "本文の取得に失敗しました: \(error)"
            }
        }
    }

    private func fetchBodyRecord(messageId: Int64) async throws -> MessageBodyRecord? {
        try await environment.database.dbWriter.read { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
    }

    private func fetchAttachmentRecords(messageId: Int64) async throws -> [AttachmentRecord] {
        try await environment.database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
        }
    }

    private func fetchBodyOverNetwork(message: MessageRecord) async throws {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            throw MailTransportError.authenticationFailed(underlyingDescription: "資格情報が見つかりません")
        }
        guard let mailboxPath else {
            throw MailTransportError.mailboxNotFound(path: "")
        }
        try await environment.syncCoordinator.fetchBody(
            for: message,
            mailboxPath: mailboxPath,
            account: account,
            auth: auth
        )
    }

    /// Reflects `\Seen` in the local database immediately, then enqueues
    /// the absolute flag state for `OpQueueProcessor` to mirror to the
    /// server (M3) and makes a best-effort replay attempt right away —
    /// harmless if offline, the op just waits for the next successful
    /// connection (foreground IDLE reconnect, pull-to-refresh, ...).
    private func markAsReadIfNeeded() {
        guard let message, !message.flags.contains(.seen) else { return }
        let messageId = messageId
        let accountId = accountId
        let mailboxId = message.mailboxId
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return }
                    guard !record.flags.contains(.seen) else { return }
                    record.flags.insert(.seen)
                    record.updatedAt = Date()
                    try record.update(db)
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(record.uid)], flags: record.flags, db: db
                    )
                    if let threadId = record.threadId {
                        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                    }
                }
                guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort: the local flag update simply doesn't happen
                // if this fails.
            }
        }
    }

    // MARK: - Plain-text link detection

    /// Builds a `Text` with any `http(s)://` links in `text` rendered as
    /// tappable links (plan: "SwiftUI Text（等幅でなく通常書体、リンク検出）").
    private func linkifiedText(_ text: String) -> Text {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Text(attributed)
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: attributed)
            else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].underlineStyle = .single
        }
        return Text(attributed)
    }

    // MARK: - Translation (design-phase-3, 1i)

    private func resetTranslationState() {
        translateTask?.cancel()
        translateTask = nil
        translationState = .none
        translationShowOriginal = false
        translationParagraphOverrides = []
    }

    /// Plain text handed to `MessageTranslator` regardless of body kind —
    /// the engine only ever translates plain strings (`docs/translation.md`),
    /// so an HTML body is flattened the same way `ComposerView`'s reply
    /// quoting already does (`HTMLTextExtractor`, no `WKWebView` needed just
    /// to extract text).
    private func sourceTextForTranslation() -> String? {
        guard let bodyRecord else { return nil }
        if let plainText = bodyRecord.plainText, !plainText.isEmpty { return plainText }
        if let html = bodyRecord.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }

    /// Called once per `load()`, after `bodyRecord` is populated (every
    /// exit path in `load()` calls this) — only actually starts a
    /// translation when every precondition holds: an English message, the
    /// device can translate at all, the "英文を自動で翻訳" setting is on
    /// (1l), and there's a non-empty cache-key-eligible `messageId`. Manual
    /// translation (the bar's "翻訳"/"再試行" button, when auto-translate is
    /// off or a previous attempt failed) goes through the same
    /// `requestTranslation(message:)` this calls into.
    private func kickoffTranslationIfNeeded(message: MessageRecord) {
        guard message.detectedLanguage == "en" else { return }
        guard environment.isTranslationAvailable else { return }
        guard autoTranslateEnglish else { return }
        requestTranslation(message: message)
    }

    /// Shared by the automatic kickoff above and the translation bar's
    /// manual "翻訳"/"再試行" button — `MessageTranslator.translate` already
    /// checks its own persisted cache first (`docs/translation.md`'s
    /// キャッシュ方針), so calling this again after a previous success (e.g.
    /// re-opening the same message) is cheap rather than re-running the
    /// on-device model.
    private func requestTranslation(message: MessageRecord) {
        guard translateTask == nil else { return }
        guard let sourceText = sourceTextForTranslation() else { return }
        translationState = .translating
        let messageId = messageId
        let translator = environment.messageTranslator
        translateTask = Task {
            let result = await translator.translate(
                messageId: messageId,
                sourceText: sourceText,
                sourceLanguage: .english,
                targetLanguage: .japanese
            )
            guard !Task.isCancelled else { return }
            translationState = result
            translateTask = nil
        }
    }
}
