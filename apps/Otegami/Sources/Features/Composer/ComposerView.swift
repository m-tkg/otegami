import SwiftUI
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

/// Compose/reply UI (M5, plan: "作成・返信"). iOS presents this as a sheet;
/// macOS opens it in its own window (`WindowGroup(id: "composer")` in
/// `OtegamiApp`) — both share this same view, driven by the same
/// `ComposerLaunchPayload`.
///
/// To/Cc are plain comma-separated text fields (plan: "トークン化はlater") —
/// `parseAddresses(_:)` below turns `"Name <addr>, addr2"` back into
/// `[EmailAddress]` at send time; reply prefill goes the other direction via
/// `EmailAddress.description`.
struct ComposerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let payload: ComposerLaunchPayload

    @State private var selectedAccountId: String?
    @State private var toText = ""
    @State private var ccText = ""
    @State private var subject = ""
    @State private var bodyText = ""

    // Resolved once, from the original message, when `payload.kind` is
    // `.reply` — carried straight into the enqueued `OutboxMessageRecord`
    // at send time without re-deriving them.
    @State private var inReplyToMessageId: String?
    @State private var references: [String] = []

    @State private var isSending = false
    @State private var isLoadingReplyContext = false
    @State private var errorMessage: String?

    // MARK: - Draft saving (M10)

    /// Captured at the end of `prepare()` (after any reply-quote/draft
    /// prefill has already run) — comparing the live fields against this
    /// baseline is what decides whether closing the Composer should offer
    /// "save as draft" at all. Without a baseline, opening a reply (whose
    /// body starts pre-filled with quoted text) and immediately cancelling
    /// without typing anything would look identical to "user wrote a
    /// reply and then changed their mind", prompting a save-or-discard
    /// dialog for a message with genuinely nothing new in it.
    @State private var initialSnapshot: ComposerSnapshot?
    @State private var showingCloseConfirmation = false
    #if os(macOS)
    // Set right before this Composer's confirmation dialog closes the
    // window itself (`closeWindowAfterConfirmation()`) — lets
    // `handleWindowShouldClose()` tell "the user just confirmed save/
    // discard, let this one specific close through" apart from "the
    // titlebar button was clicked fresh, still need to ask." See
    // `WindowCloseInterceptor`'s doc comment for why this needs an
    // `NSWindowDelegate` hook at all.
    @State private var allowNextWindowClose = false
    #endif

    private struct ComposerSnapshot: Equatable {
        var to: String
        var cc: String
        var subject: String
        var body: String
    }

    private var currentSnapshot: ComposerSnapshot {
        ComposerSnapshot(to: toText, cc: ccText, subject: subject, body: bodyText)
    }

    /// Whether closing now would silently lose something the user typed.
    /// `false` until `prepare()` finishes (`initialSnapshot == nil` — no
    /// baseline yet means nothing to compare against, so cancelling during
    /// that brief window just closes immediately rather than blocking on a
    /// dialog for a Composer that isn't even done loading).
    private var hasUnsavedChanges: Bool {
        guard let initialSnapshot else { return false }
        return currentSnapshot != initialSnapshot
    }

    // M8: attachments picked but not yet sent — held as plain `Data` in
    // memory (not yet copied anywhere on disk) until `send()`, which is
    // where they're staged into Application Support/Outbox (plan: "送信前に
    // ... へコピーして安定パス化"). Fine for the small attachments this app's
    // own test fixtures and everyday mail-client use exercise; a much
    // larger file would be a reason to stream straight to a temp file at
    // pick time instead, but that's not a case M8 needs to solve.
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var isImportingFile = false
    #if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("差出人") {
                    Picker("From", selection: $selectedAccountId) {
                        ForEach(environment.accounts) { account in
                            Text("\(account.displayName) <\(account.email)>")
                                .tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("composer.fromPicker")
                }

                Section("宛先") {
                    TextField("To (カンマ区切り)", text: $toText)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("composer.to")
                    TextField("Cc (カンマ区切り)", text: $ccText)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("composer.cc")
                }

                Section("件名") {
                    TextField("件名", text: $subject)
                        .accessibilityIdentifier("composer.subject")
                }

                Section("本文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 240)
                        .accessibilityIdentifier("composer.body")
                }

                Section("添付ファイル") {
                    ForEach(pendingAttachments) { attachment in
                        HStack {
                            Image(systemName: "paperclip")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("composer.attachment.\(attachment.id)")
                    }
                    .onDelete { offsets in
                        pendingAttachments.remove(atOffsets: offsets)
                    }

                    Button {
                        isImportingFile = true
                    } label: {
                        Label("ファイルを追加", systemImage: "paperclip")
                    }
                    .accessibilityIdentifier("composer.addFileButton")

                    #if os(iOS)
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("写真を追加", systemImage: "photo")
                    }
                    .accessibilityIdentifier("composer.addPhotoButton")
                    #endif
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("composer.errorMessage")
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { handleCloseRequested() }
                        .accessibilityIdentifier("composer.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("送信")
                        }
                    }
                    .accessibilityIdentifier("composer.sendButton")
                    .disabled(isSending || isLoadingReplyContext || !isFormValid)
                }
            }
        }
        .accessibilityIdentifier("composer.sheet")
        // M10: block the iOS sheet's swipe-down dismissal whenever there's
        // something unsaved — the toolbar "キャンセル" button (routed through
        // `handleCloseRequested()`) becomes the one path that can actually
        // close the Composer in that state, so the save-or-discard prompt
        // below can never be bypassed by a gesture. A no-op on macOS (this
        // Composer is its own `WindowGroup` there, not a sheet) — macOS's
        // equivalent bypass (the titlebar close button) is handled by
        // `WindowCloseInterceptor` below instead.
        .interactiveDismissDisabled(hasUnsavedChanges)
        #if os(macOS)
        // Routes the native titlebar close button through the same
        // save-or-discard confirmation as the toolbar "キャンセル" button —
        // see `WindowCloseInterceptor`'s doc comment.
        .background(WindowCloseInterceptor(shouldClose: handleWindowShouldClose))
        #endif
        .confirmationDialog(
            "このメッセージを保存しますか？",
            isPresented: $showingCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("下書きとして保存") {
                Task {
                    await saveDraft()
                    closeAfterConfirmation()
                }
            }
            .accessibilityIdentifier("composer.saveDraftButton")
            Button("保存せずに破棄", role: .destructive) { closeAfterConfirmation() }
                .accessibilityIdentifier("composer.discardButton")
            Button("キャンセル", role: .cancel) {}
                .accessibilityIdentifier("composer.keepEditingButton")
        }
        .task { await prepare() }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { addAttachment(fromSecurityScopedURL: url) }
            case .failure:
                break // User cancelled, or the picker itself failed — nothing to attach either way.
            }
        }
        #if os(iOS)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await addAttachment(fromPhotoPickerItem: newItem)
                selectedPhotoItem = nil
            }
        }
        #endif
    }

    private var navigationTitle: String {
        switch payload.kind {
        case .new: "新規作成"
        case .reply(_, let replyAll): replyAll ? "全員に返信" : "返信"
        case .draft: "下書き"
        }
    }

    private var isFormValid: Bool {
        selectedAccountId != nil && !toText.trimmingCharacters(in: .whitespaces).isEmpty && !subject.isEmpty
    }

    // MARK: - Setup

    private func prepare() async {
        if selectedAccountId == nil {
            selectedAccountId = environment.accounts.first?.id
        }
        attachUITestFixtureIfRequested()
        switch payload.kind {
        case .new:
            break
        case .reply(let originalMessageId, let replyAll):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await prefillReply(toOriginalMessageId: originalMessageId, replyAll: replyAll)
        case .draft(let draftId):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await loadDraft(draftId: draftId)
        }
        // Baseline for `hasUnsavedChanges` — captured last, after whatever
        // prefill above (reply quoting, or a resumed draft's saved text)
        // has already landed in the `@State` fields. See its doc comment.
        initialSnapshot = currentSnapshot
    }

    /// Resuming a saved draft (M10): loads its fields, then deletes the row
    /// immediately — `ComposerLaunchPayload.Kind.draft`'s doc comment
    /// explains why ("load transfers ownership" avoids needing
    /// update-vs-insert branching in `saveDraft()`). Best-effort: if the
    /// row is already gone (e.g. deleted from `DraftsView` in another
    /// window right as this one opened), the Composer just opens blank
    /// rather than erroring.
    private func loadDraft(draftId: Int64) async {
        let draft: DraftMessageRecord? = try? await environment.database.dbWriter.write { db in
            guard let draft = try DraftMessageRecord.fetchOne(db, key: draftId) else { return nil }
            try draft.delete(db)
            return draft
        }
        guard let draft else { return }
        selectedAccountId = draft.accountId
        toText = draft.toAddresses.map(\.description).joined(separator: ", ")
        ccText = draft.ccAddresses.map(\.description).joined(separator: ", ")
        subject = draft.subject
        bodyText = draft.plainTextBody
        inReplyToMessageId = draft.inReplyToMessageId
        references = draft.references
    }

    // MARK: - Closing (M10: save-as-draft / discard)

    private func handleCloseRequested() {
        guard hasUnsavedChanges else {
            dismiss()
            return
        }
        showingCloseConfirmation = true
    }

    #if os(macOS)
    /// `WindowCloseInterceptor`'s `NSWindowDelegate` callback — invoked
    /// synchronously whenever the user clicks the titlebar's red close
    /// button (or otherwise asks AppKit to close this window), *before*
    /// the window actually closes. Returning `false` blocks the close and
    /// (as a side effect) opens the same confirmation dialog the toolbar
    /// "キャンセル" button uses; returning `true` lets it through.
    private func handleWindowShouldClose() -> Bool {
        guard hasUnsavedChanges else { return true }
        if allowNextWindowClose {
            allowNextWindowClose = false
            return true
        }
        showingCloseConfirmation = true
        return false
    }
    #endif

    /// Both confirmation-dialog actions that actually close the Composer
    /// (save-then-close, discard-then-close) call this instead of
    /// `dismiss()` directly. On iOS it's just `dismiss()`. On macOS,
    /// `dismiss()` closes this scene's `NSWindow`, which re-invokes
    /// `handleWindowShouldClose()` via the same delegate hook that opened
    /// this dialog in the first place — without the one-shot
    /// `allowNextWindowClose` flag set first, that second call would see
    /// `hasUnsavedChanges` still `true` and re-block the close, reopening
    /// the dialog in a loop instead of ever actually closing.
    private func closeAfterConfirmation() {
        #if os(macOS)
        allowNextWindowClose = true
        #endif
        dismiss()
    }

    /// Persists the current fields as a new `DraftMessageRecord` row.
    /// Attachments are intentionally dropped — see `DraftMessageRecord`'s
    /// doc comment ("シンプル優先"): staging them to disk the way `send()`
    /// does would be straightforward, but restoring them into a resumed
    /// Composer's `pendingAttachments` (currently in-memory `Data`, not a
    /// stable on-disk reference the way `outboxAttachment` rows are) would
    /// mean re-reading arbitrarily large files back into memory just to
    /// populate a draft the user might not even resume — a real feature,
    /// left for a future milestone rather than half-implemented here.
    private func saveDraft() async {
        guard let accountId = selectedAccountId else { return }
        let toAddresses = Self.parseAddresses(toText)
        let ccAddresses = Self.parseAddresses(ccText)
        // Nothing at all to save (a blank "新規作成" opened and immediately
        // cancelled without `hasUnsavedChanges` ever going true reaches
        // `dismiss()` directly in `handleCloseRequested()`, so this handles
        // the rarer case of unsaved *whitespace-only* edits) — skip writing
        // an empty row.
        guard !toAddresses.isEmpty || !ccAddresses.isEmpty || !subject.isEmpty || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        do {
            try await environment.database.dbWriter.write { db in
                var draft = DraftMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    subject: subject,
                    plainTextBody: bodyText,
                    inReplyToMessageId: inReplyToMessageId,
                    references: references
                )
                try draft.insert(db)
            }
        } catch {
            // Best-effort, matching every other Composer persistence path
            // in this file (`send()`'s doc comment) — a failure here means
            // the draft is simply lost, same as tapping "破棄" would have.
        }
    }

    // MARK: - Attachments (M8)

    /// Reads `url`'s bytes immediately (inside the picker's security-scoped
    /// access window — the URL `fileImporter` hands back isn't guaranteed
    /// readable once that window closes) rather than holding onto the URL
    /// itself for later.
    private func addAttachment(fromSecurityScopedURL url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let filename = url.lastPathComponent
        pendingAttachments.append(PendingAttachment(filename: filename, mimeType: Self.mimeType(forFilename: filename), data: data))
    }

    #if os(iOS)
    private func addAttachment(fromPhotoPickerItem item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // `PhotosPickerItem` doesn't reliably expose an original filename
        // (it's a photo library asset, not a file), so a generated one is
        // used — `.jpg` since `matching: .images` plus `loadTransferable
        // (type: Data.self)` is what `PhotosUI` documents as producing a
        // JPEG-transcoded representation for photo assets in the common
        // case.
        let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
        pendingAttachments.append(PendingAttachment(filename: filename, mimeType: "image/jpeg", data: data))
    }
    #endif

    private static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// XCUITest cannot reliably drive the system file-picker/PhotosPicker
    /// UI (it lives outside this app's own accessibility tree) — plan:
    /// "XCUITest でのファイル選択が困難なら、UITest 用 launch argument でテストファイルを
    /// 直接添付する内部フックを用意し、その旨 docs に記録". When the
    /// `OTEGAMI_UITEST_ATTACH_FIXTURE` launch environment variable is set
    /// to `"1"` (`OtegamiM8ComposeAttachmentUITests` — see `docs/verify.md`'s
    /// M8 section), a small fixed fixture is attached automatically as soon
    /// as the Composer appears, bypassing the picker entirely. The fixture
    /// is embedded in-process (not read from a host-written file path) so
    /// this hook has no dependency on whatever filesystem visibility the
    /// simulator's app-process sandbox happens to allow across processes —
    /// only a boolean flag crosses the process boundary, via
    /// `XCUIApplication.launchEnvironment` (well-supported, unlike
    /// `Foundation.Process`; see `verify.md`'s M3 note on what does and
    /// doesn't work from an XCUITest target). Unset in every normal
    /// launch, so this is a no-op outside of that one verification flow.
    private func attachUITestFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["OTEGAMI_UITEST_ATTACH_FIXTURE"] == "1" else { return }
        let content = Data("otegami M8 UITest attachment fixture\n".utf8)
        pendingAttachments.append(PendingAttachment(filename: "m8-uitest-attachment.txt", mimeType: "text/plain", data: content))
    }

    private func prefillReply(toOriginalMessageId originalMessageId: Int64, replyAll: Bool) async {
        struct ReplyContext {
            var message: MessageRecord
            var accountId: String
            var referenceValues: [String]
            var bodyRecord: MessageBodyRecord?
        }

        let context: ReplyContext? = try? await environment.database.dbWriter.read { db -> ReplyContext? in
            guard let message = try MessageRecord.fetchOne(db, key: originalMessageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { return nil }
            let referenceValues = try MessageReferenceRecord
                .filter(Column("messageId") == originalMessageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: originalMessageId)
            return ReplyContext(message: message, accountId: mailbox.accountId, referenceValues: referenceValues, bodyRecord: bodyRecord)
        }
        guard let context else { return }

        selectedAccountId = context.accountId
        subject = "Re: " + SubjectNormalizer.normalize(context.message.subject ?? "")
        inReplyToMessageId = context.message.messageId

        var chain = context.referenceValues
        if let ownMessageId = context.message.messageId, chain.last != ownMessageId {
            chain.append(ownMessageId)
        }
        references = chain

        let ownAddress = environment.accounts.first { $0.id == context.accountId }?.email.lowercased()
        if replyAll {
            var to = context.message.fromAddresses
            to.append(contentsOf: context.message.toAddresses.filter { $0.address.lowercased() != ownAddress })
            toText = to.map(\.description).joined(separator: ", ")
            ccText = context.message.ccAddresses
                .filter { $0.address.lowercased() != ownAddress }
                .map(\.description)
                .joined(separator: ", ")
        } else {
            toText = context.message.fromAddresses.map(\.description).joined(separator: ", ")
        }

        bodyText = "\n\n" + quotedBody(from: context.bodyRecord)
    }

    /// Plain-text quoting (plan: "本文に`> `引用"). Falls back to
    /// `HTMLTextExtractor` for an HTML-only original body — the same
    /// dependency-free extractor `SyncEngine.BodyFetcher` already uses for
    /// its own plain-text derivation, so a reply never needs a WKWebView
    /// just to quote text.
    private func quotedBody(from bodyRecord: MessageBodyRecord?) -> String {
        let source: String
        if let plainText = bodyRecord?.plainText, !plainText.isEmpty {
            source = plainText
        } else if let html = bodyRecord?.html, !html.isEmpty {
            source = HTMLTextExtractor.plainText(fromHTML: html)
        } else {
            return ""
        }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    // MARK: - Send

    private func send() async {
        guard let accountId = selectedAccountId,
              let account = environment.accounts.first(where: { $0.id == accountId })
        else { return }

        let toAddresses = Self.parseAddresses(toText)
        guard !toAddresses.isEmpty else {
            errorMessage = "宛先を入力してください。"
            return
        }
        let ccAddresses = Self.parseAddresses(ccText)

        isSending = true
        defer { isSending = false }

        do {
            // M8: stage each pending attachment's bytes onto disk *before*
            // the DB transaction below — `OutboxAttachmentRecord.localPath`
            // is `NOT NULL` (unlike the received-side `attachment.localPath`,
            // which starts `nil`), so a row for it should never exist
            // without a file already backing it. A staging failure here
            // (out of disk space, ...) surfaces as this whole send failing
            // up front, rather than an inconsistent partially-attached
            // outbox row.
            let stagedAttachments = try Self.stageAttachments(pendingAttachments)

            try await environment.database.dbWriter.write { db in
                var outbox = OutboxMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    subject: subject,
                    plainTextBody: bodyText,
                    inReplyToMessageId: inReplyToMessageId,
                    references: references
                )
                try outbox.insert(db)
                guard let outboxId = outbox.id else { return }
                for staged in stagedAttachments {
                    var attachmentRecord = OutboxAttachmentRecord(
                        outboxMessageId: outboxId, filename: staged.filename,
                        mimeType: staged.mimeType, localPath: staged.url.path, size: staged.size
                    )
                    try attachmentRecord.insert(db)
                }
                try OpQueue.enqueueSend(accountId: accountId, outboxMessageId: outboxId, db: db)
            }
            dismiss()

            // Best-effort immediate replay, same pattern as
            // MessageView.markAsReadIfNeeded/MessageListView's swipe
            // actions — harmless if offline, the op just waits for the
            // next successful connection.
            if let auth = try? await environment.auth(for: account) {
                Task { _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth) }
            }
        } catch {
            errorMessage = "送信の準備に失敗しました: \(error)"
        }
    }

    /// Parses a comma-separated address list, accepting either a bare
    /// address (`"a@example.com"`) or a `"Name <a@example.com>"` form —
    /// matches what `EmailAddress.description` (used to prefill a reply's
    /// To/Cc fields) produces, so round-tripping through this field doesn't
    /// lose the display name.
    static func parseAddresses(_ text: String) -> [EmailAddress] {
        text.split(separator: ",").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
                let name = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespaces)
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { return nil }
                return EmailAddress(name: name.isEmpty ? nil : name, address: address)
            }
            return EmailAddress(address: trimmed)
        }
    }

    /// Copies each pending attachment's in-memory bytes to
    /// `<Application Support>/otegami/Outbox/<UUID>/<filename>` — one
    /// fresh, randomly-named directory per attachment (rather than nesting
    /// under the not-yet-known `outboxMessageId`, since these files are
    /// written *before* that row's `db.write` transaction even starts;
    /// `OutboxAttachmentRecord.localPath` is what associates the file back
    /// to its outbox message afterward, not its position in this
    /// directory tree). Mirrors `AttachmentFetcher.storageURL`'s "everything
    /// under one `otegami/` folder in Application Support" convention on
    /// the received side.
    private static func stageAttachments(_ pending: [PendingAttachment]) throws -> [StagedAttachment] {
        guard !pending.isEmpty else { return [] }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let outboxRoot = base.appendingPathComponent("otegami/Outbox", isDirectory: true)

        return try pending.map { attachment in
            let directory = outboxRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(attachment.filename)
            try attachment.data.write(to: url, options: .atomic)
            return StagedAttachment(filename: attachment.filename, mimeType: attachment.mimeType, url: url, size: attachment.data.count)
        }
    }

    private struct StagedAttachment {
        var filename: String
        var mimeType: String
        var url: URL
        var size: Int
    }
}

/// One file the user has picked in this Composer session but not yet sent
/// — see `ComposerView.pendingAttachments`'s doc comment for why this
/// holds raw `Data` rather than a URL.
private struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

private extension View {
    @ViewBuilder
    func textFieldAutocapitalizationNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Reaches AppKit's `NSWindowDelegate.windowShouldClose(_:)` — the only way
/// to intercept the titlebar's native close button — from pure SwiftUI.
/// `WindowGroup`/`Settings` scenes don't expose a delegate hook directly,
/// so this is the standard workaround: a zero-size `NSViewRepresentable`
/// that, once AppKit has actually placed it into a window's view hierarchy,
/// swaps in a delegate that forwards the one question this Composer cares
/// about (`shouldClose`) back into SwiftUI state. Fixes the gap noted in
/// `docs/roadmap.md`'s "既知の制約" list: closing the Composer via the
/// titlebar red button used to bypass the save-draft/discard confirmation
/// entirely, silently losing unsaved text — only the toolbar "キャンセル"
/// button (and, on iOS, the sheet's own swipe-to-dismiss block) went
/// through `handleCloseRequested()`/`hasUnsavedChanges`.
private struct WindowCloseInterceptor: NSViewRepresentable {
    /// Forwarded to `Coordinator.shouldClose` on every `updateNSView` call
    /// (cheap — a closure property assignment) so it always reflects the
    /// current SwiftUI-side handler, even though the delegate itself is
    /// only ever assigned once per window (see `updateNSView`).
    var shouldClose: () -> Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        // `nsView.window` is `nil` until AppKit actually places this view
        // into a window's hierarchy; `updateNSView` re-runs on every
        // SwiftUI body re-evaluation, so the first call after the window
        // exists is what wires this up. Guarding on `!==` avoids fighting
        // any other code that might reassign the delegate later, and
        // avoids redundantly reassigning it on every re-render once set.
        guard let window = nsView.window, window.delegate !== context.coordinator else { return }
        window.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose()
        }
    }
}
#endif
