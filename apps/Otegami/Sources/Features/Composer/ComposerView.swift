import SwiftUI
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import OtegamiTranslation
import SyncEngine
import UniformTypeIdentifiers
import os
#if os(iOS)
import PhotosUI
import UIKit
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

    /// Task #124 — shared category with `PendingSendCoordinator`/
    /// `OpQueueProcessor` so one send's whole lifecycle reads as a single
    /// interleaved stream in Console.app.
    private static let pendingSendLogger = Logger(subsystem: "com.mtkg.otegami", category: "PendingSend")

    let payload: ComposerLaunchPayload

    /// G「デフォルトのアカウント」— see `DefaultAccountSettingsStore`'s doc
    /// comment. Only consulted by `prepare()` for `.new`; every other
    /// `payload.kind` overwrites `selectedAccountId` from the original
    /// message/draft's own account right after, same as before this
    /// setting existed.
    @AppStorage(DefaultAccountSettingsStore.defaultAccountIdKey) private var defaultAccountId = ""

    @State private var selectedAccountId: String?
    @State private var toText = ""
    @State private var ccText = ""
    /// Task #48 (デフォルトメールアプリ対応): added alongside the `mailto:`
    /// handler so a `bcc=` hfield has somewhere to land — `OutboxMessageRecord
    /// .bccAddresses`/`OpQueueProcessor`'s SMTP send already supported Bcc
    /// end to end (the recipient gets the message via `RCPT TO`, but never
    /// appears in any header — `OpQueueProcessor`'s `recipients =
    /// toAddresses + ccAddresses + bccAddresses` vs. the separate `bcc:`
    /// parameter it passes to the MIME builder), this field was simply the
    /// only missing piece of Composer UI.
    ///
    /// Known gap, not a bug: `DraftMessageRecord` (the "下書きとして保存"
    /// table) has no `bccAddresses` column, so saving a draft with Bcc
    /// filled in silently drops it — `saveDraft()` was never touched here.
    /// Adding draft-level Bcc persistence would need its own schema
    /// migration and is out of scope for what this field exists to unblock
    /// (mailto: prefill, immediate send). `PendingSendDraftSnapshot` (C7
    /// cancelled-send restore) *does* carry it, since that's in-memory only.
    @State private var bccText = ""
    /// 2026-07-29デザイン指示 (iOSフラットデザイン化): the iOS "宛先" row's
    /// "Cc: Bcc:" ピルボタンをタップした結果 — `true`になった後は元に戻らない
    /// (一度展開したCc/Bcc行を再び隠す操作はない、他のメールクライアントの
    /// 慣習どおり)。`isShowingCcBcc`はこれと「すでにCc/Bccに値が入っている」
    /// のORで決まるので、mailto:プリフィル/全員に返信/送信キャンセル復元で
    /// 最初からCc/Bccに値が入っているケースはピルをタップしなくても最初から
    /// 展開済みで見える — `OtegamiMailtoUITests`がタップなしで
    /// `composer.cc`/`composer.bcc`を直接読むのはこの前提に依存している。
    @State private var isCcBccExpandedByUser = false

    /// Task #161 (#129 第2段, 下部バーのSpark準拠再構成): whether
    /// `RichTextFormattingBar` is currently shown, iOS only — the bar no
    /// longer sits permanently above the body editor (`flatBodySection`
    /// used to place it there unconditionally); `flatBottomActionBar`'s "T"
    /// button toggles this instead, matching Spark's compose screen (書式
    /// バーはタップで開閉する引き出し、常時表示ではない). macOS's `bodySection`
    /// is untouched by this restructure (`bodySection`'s own doc comment).
    // `-uitestsShowFormattingBarDirectly` (verify-screen.sh's
    // `composer-richtext-open` scenario): pre-expands the bar so the
    // "open" screenshot doesn't depend on a "T" button tap — same
    // tap-free direct-nav convention as `MailScreenView.isFabExpanded`'s
    // `-uitestsExpandFabDirectly`.
    #if os(iOS)
    @State private var isFormattingBarVisible = ProcessInfo.processInfo.arguments.contains("-uitestsShowFormattingBarDirectly")
    #endif

    /// See `isCcBccExpandedByUser`'s doc comment.
    private var isShowingCcBcc: Bool {
        isCcBccExpandedByUser
            || !ccText.trimmingCharacters(in: .whitespaces).isEmpty
            || !bccText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    @State private var subject = ""
    /// Task #129 (作成画面リッチテキスト化): the body editor's real state —
    /// replaces the M1-era plain `bodyText: String` now that `bodySection`
    /// is a `RichTextEditor` (`UITextView`/`NSTextView` +
    /// `NSAttributedString`, not SwiftUI's `TextEditor`). `bodyText` below
    /// is kept as a computed plain-text projection so every read site from
    /// before #129 (persistence into `plainTextBody`, emptiness checks,
    /// `hasSuffix`) keeps working unchanged; every *write* site now goes
    /// through `setPlainBody(_:)`/`appendPlainBody(_:)` instead (plain text
    /// in, exactly like before — only newly-typed/selected text ever picks
    /// up formatting from the formatting bar).
    @State private var attributedBodyText = RichTextAttributedString.plainAttributedString("")
    /// Bound to `bodySection`'s `RichTextEditor` — reflects the live
    /// cursor/selection. Task #125's 「署名カーソル」placement logic that used
    /// to write here (right after a signature's text was appended to
    /// `attributedBodyText`) was retired by Task #162 — signatures no
    /// longer touch the body at all, so there's no post-insertion cursor to
    /// place; see "MARK: - F 署名"'s doc comment.
    @State private var bodySelectedRange = NSRange(location: 0, length: 0)
    /// Task #129: created once, handed to both `bodySection`'s
    /// `RichTextEditor` and its formatting bar — see
    /// `RichTextEditingController`'s doc comment.
    @StateObject private var richTextEditingController = RichTextEditingController()

    /// See `attributedBodyText`'s doc comment.
    private var bodyText: String { attributedBodyText.string }

    private func setPlainBody(_ text: String) {
        attributedBodyText = RichTextAttributedString.plainAttributedString(text)
    }

    private func appendPlainBody(_ text: String) {
        let mutable = NSMutableAttributedString(attributedString: attributedBodyText)
        mutable.append(RichTextAttributedString.plainAttributedString(text))
        attributedBodyText = mutable
    }

    // Resolved once, from the original message, when `payload.kind` is
    // `.reply` — carried straight into the enqueued `OutboxMessageRecord`
    // at send time without re-deriving them.
    @State private var inReplyToMessageId: String?
    @State private var references: [String] = []

    // MARK: - Drafts IMAP sync

    /// The server-side Drafts copy this Composer session is resuming from,
    /// if any — set by `loadDraft(draftId:)` (a local draft that itself
    /// already has a known server copy from a previous save) or
    /// `loadServerDraft(messageId:)` (a server-origin draft opened
    /// directly). `saveDraft()` carries these forward as "the old copy to
    /// replace" on the new `DraftMessageRecord` row it writes; `send()`
    /// carries them onto the new `OutboxMessageRecord` row so
    /// `OpQueueProcessor`'s `.send` replay can best-effort delete the
    /// now-redundant Drafts copy once the message is actually sent. All
    /// three stay `nil` for `.new`/`.reply` and for a local draft that was
    /// never uploaded.
    @State private var draftServerMailboxId: Int64?
    @State private var draftServerUid: Int64?
    @State private var draftServerUidValidity: Int64?

    @State private var isSending = false
    @State private var isLoadingReplyContext = false
    @State private var errorMessage: String?

    /// C7 「送信取り消し」猶予 — see `SendCancelSettingsStore`'s doc comment.
    @AppStorage(SendCancelSettingsStore.windowKey) private var sendCancelWindowRaw = SendCancelSettingsStore.defaultWindow.rawValue

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
        var bcc: String
        var subject: String
        var body: String
    }

    private var currentSnapshot: ComposerSnapshot {
        ComposerSnapshot(to: toText, cc: ccText, bcc: bccText, subject: subject, body: bodySnapshotString)
    }

    /// Task #129: an HTML rendering of `attributedBodyText`, originally
    /// added only as `ComposerSnapshot.body`'s value — comparing the
    /// plain-text projection alone (`bodyText`) would miss a purely-
    /// formatting edit (e.g. selecting existing text and making it bold,
    /// with not a single character added/removed), which should still
    /// count as "something to lose" for `hasUnsavedChanges`'s save-or-
    /// discard prompt.
    ///
    /// Task #156: `send()` reuses this exact same rendering for
    /// `PendingSendDraftSnapshot.htmlBody` (C7's cancelled-send restore) and
    /// `saveDraft()` for `DraftMessageRecord.htmlBody` — both want
    /// precisely "what the editable body looks like as HTML", the
    /// signature deliberately *not* included (Task #162: neither a
    /// cancelled-send restore nor a resumed draft should show the
    /// signature already baked into the body — see `bodyDocumentWithSignature`
    /// for the one place that combines them, and this file's "MARK: - F
    /// 署名" doc comment for the full picture).
    private var bodySnapshotString: String {
        RichTextHTMLCoder.encode(RichTextAttributedString.makeDocument(from: attributedBodyText))
    }

    /// Task #162: the editable body combined with the currently-selected
    /// signature (if any) as "本文 + 空行 + 署名" — `send()`'s sole caller,
    /// right before deriving `OutboxMessageRecord.plainTextBody`/`.htmlBody`
    /// from it. See `RichTextDocument.appendingSignature(_:)`'s doc comment
    /// for why this builds one combined document rather than string-
    /// splicing the plain and HTML forms independently.
    private var bodyDocumentWithSignature: RichTextDocument {
        RichTextAttributedString.makeDocument(from: attributedBodyText).appendingSignature(selectedSignature?.body)
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
    /// 表示・操作改善バッチ「添付ボタンの統合」— `.photosPicker(isPresented:)`'s
    /// flag (`attachmentsMenu`'s doc comment on why this isn't a
    /// `PhotosPicker` trigger view embedded directly in the `Menu`).
    @State private var isShowingPhotoPicker = false
    /// 表示・操作改善バッチ「添付ボタンの統合」— `CameraPicker`'s sheet flag.
    @State private var isShowingCamera = false
    #endif

    // MARK: - C8 テンプレート

    /// Templates visible from the currently-selected `From` account —
    /// `accountId == nil` (global) or `accountId == selectedAccountId`
    /// (scoped to this one). Reloaded whenever `selectedAccountId` changes
    /// (`.task(id: selectedAccountId)` below), not just once at `prepare()`
    /// time, so switching the `From` picker updates which templates are
    /// offered without needing to reopen the Composer.
    @State private var availableTemplates: [MailTemplateRecord] = []

    // MARK: - F 署名
    //
    // Task #162 (実機フィードバック「署名が本文に混ざって編集しづらい」):
    // signatures are no longer inserted into `attributedBodyText` at all —
    // `selectedSignatureId` only drives a read-only preview row
    // (`flatSignatureRow`/`signatureSection`) below the body editor.
    // Combining "本文 + 空行 + 署名" happens exactly once, transiently, at
    // `send()` (`RichTextDocument.appendingSignature(_:)`) — the editable
    // body the user actually types into, `DraftMessageRecord`'s persisted
    // columns, and C7's `PendingSendDraftSnapshot` all keep body and
    // signature choice entirely separate. This also retires Task #125's
    // 「署名カーソル」cursor-placement logic (`ComposerCursorPlacement`,
    // deleted) — that logic only ever existed to place the cursor relative
    // to signature text that lived *inside* the body; with nothing being
    // inserted there anymore, there's no cursor to place.

    /// Signatures scoped to the currently-selected `From` account — same
    /// "reloaded on `.task(id: selectedAccountId)`" shape as
    /// `availableTemplates` just above, but filtered client-side
    /// (`SignatureTemplateRecord.accountIds.contains(_:)`) rather than by a
    /// SQL predicate, since `accountIds` is a JSON-encoded BLOB column
    /// GRDB can't filter inside SQL — this list is never large enough
    /// (a handful of signatures at most) for that to matter.
    @State private var availableSignatures: [SignatureTemplateRecord] = []
    /// `nil` = "なし" (the picker's own first option). Auto-selected by
    /// `loadAvailableSignatures()` whenever this is still `nil` after a From
    /// account (re)load — priority "前回選択 (`LastSignatureSettingsStore`) >
    /// アカウント既定署名 (`AccountRecord.defaultSignatureId`) > なし". Restored
    /// verbatim (never re-derived) when resuming a saved draft
    /// (`DraftMessageRecord.signatureId`) or a cancelled send
    /// (`PendingSendDraftSnapshot.signatureId`).
    @State private var selectedSignatureId: Int64?

    var body: some View {
        NavigationStack {
            composerContent
                .navigationTitle(navigationTitle)
                .tint(OtegamiColor.accent)
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
        .task(id: selectedAccountId) { await loadAvailableTemplates() }
        .task(id: selectedAccountId) { await loadAvailableSignatures() }
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
        // バグ修正: `.sheet(isPresented: $isShowingCamera)` を最初
        // `attachmentsMenu`（`Form`/`Section`の奥深く、`Menu`本体）に直接付けて
        // いたところ、「添付」メニューをタップした瞬間 (`isShowingCamera`が
        // まだ`false`のまま、カメラを選ぶ前) にこの `ComposerView` 自身の
        // `.sheet` (`composer.sheet`) がまるごと閉じてしまう実機さながらの
        // シミュレータ挙動を UITest で確認した — `docs/design-system.md`の
        // 「シートからシートを開く」で既知の壊れ方そのもの (`Menu`のポップ
        // オーバー表示と、同じ view に付いた`.sheet`修飾子が競合したとみられる)。
        // `isImportingFile`の`.fileImporter`が既にそうしているのと同じく、
        // 深い子ビューではなくこの`body`トップレベルへ付け替えて解決した。
        .sheet(isPresented: $isShowingCamera) {
            CameraPicker(onCapture: handleCameraCapture)
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        #endif
    }

    // MARK: - Top-level content (platform split)
    //
    // 2026-07-29デザイン指示 (Spark ダークモード参考): iOS はカード/`Form`の
    // グループ化された見た目をやめ、背景に直接フィールドが並ぶミニマムな
    // フラットデザインへ — `flatContent`とその下の「MARK: - iOS flat layout」
    // 節がそれ。macOS は今回のスコープ外 (指示の「macOSは崩れない範囲で
    // 追随、優先はiOS」どおり、既存の`Form`ベースのレイアウトをそのまま
    // 維持) — `fromSection`以下、この下に続く「MARK: - Form sections
    // (macOS)」節がそれ。
    @ViewBuilder
    private var composerContent: some View {
        #if os(iOS)
        flatContent
        #else
        Form {
            fromSection
            addressSection
            subjectSection
            bodySection
            templateSection
            signatureSection
            // Task #125 「添付UIの位置」: 添付ボタン/添付済み一覧は本文＋
            // 署名の下 — 署名選択で本文末尾が変わっても、添付欄の位置が
            // それに引きずられて動かないようにする。
            attachmentsSection
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("composer.errorMessage")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        #endif
    }

    // MARK: - Form sections (macOS)
    //
    // `docs/ci.md`'s SwiftUI type-check-timeout pitfall, hit for real
    // building this: a `Form { Section { ForEach { multi-line HStack } } }`
    // all inline inside one `body` expression is exactly the "nested
    // container + multi-argument view content + several modifier chains"
    // shape that blew CI's type-checker budget (confirmed locally with
    // `OTHER_SWIFT_FLAGS="-Xfrontend -warn-long-expression-type-checking=300"`
    // — `body` itself was the flagged expression). Splitting each `Section`
    // out into its own `@ViewBuilder`/computed property (mirroring
    // `MessageListView`/`ThreadDetailView`'s row-splitting precedent) fixed
    // it; `attachmentsSection`'s `ForEach` row further needed its own
    // `AttachmentRow` type below, not just a smaller closure, since the row
    // itself still had a multi-line `HStack`/`VStack`/two-`Text` shape.

    // Task #164 (実機フィードバック「メール作成のUIがおかしい。ラベルが複数
    // あるとか」): macOS の `Form` は `Section("見出し")` の見出しテキストと、
    // 各コントロールの先頭引数 (`Picker`/`TextField` のタイトル、Form内では
    // 左ラベルとして描画される) の両方が同時に見えるため、`Section("差出人")`
    // + `Picker("From", ...)` のように見出しと行ラベルを両方付けると
    // 「差出人」「From: <picker>」の二重表示になる (実機フィードバック
    // スクリーンショットで確認)。以下の3セクションは見出しを外し、
    // 行ラベル1本 (macOS 標準 Mail.app の「宛先: / Cc: / 件名:」に合わせた
    // 日本語) に統一した。`Section`自体は見出しなしのままグルーピング目的で
    // 残している (`Form`の区切り線はそのまま活きる)。
    #if os(macOS)
    private var fromSection: some View {
        Section {
            Picker("差出人:", selection: $selectedAccountId) {
                ForEach(environment.accounts) { account in
                    Text("\(account.displayName) <\(account.email)>")
                        .tag(Optional(account.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("composer.fromPicker")
        }
    }

    private var addressSection: some View {
        Section {
            TextField("宛先:", text: $toText, prompt: Text("カンマ区切りで複数指定可"))
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("composer.to")
            TextField("Cc:", text: $ccText, prompt: Text("カンマ区切りで複数指定可"))
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("composer.cc")
            TextField("Bcc:", text: $bccText, prompt: Text("カンマ区切りで複数指定可"))
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("composer.bcc")
        }
    }

    private var subjectSection: some View {
        Section {
            TextField("件名:", text: $subject)
                .accessibilityIdentifier("composer.subject")
        }
    }

    private var bodySection: some View {
        Section("本文") {
            // Task #129 (作成画面リッチテキスト化): `RichTextEditor` (a real
            // `UITextView`/`NSTextView` bound to `NSAttributedString`) replaces
            // the M1-era SwiftUI `TextEditor` — see `attributedBodyText`'s doc
            // comment. `RichTextFormattingBar` sits directly above it on
            // macOS (unlike iOS's Task #161 toggle-controlled bottom bar —
            // this platform's scope wasn't touched by that restructure).
            RichTextFormattingBar(controller: richTextEditingController, hasSelection: bodySelectedRange.length > 0)
            RichTextEditor(
                attributedText: $attributedBodyText,
                selectedRange: $bodySelectedRange,
                controller: richTextEditingController,
                accessibilityIdentifier: "composer.body"
            )
            .frame(minHeight: 240)
        }
    }

    /// 表示・操作改善バッチ「添付ボタンの統合」: 従来はファイル/写真それぞれ独立
    /// したボタンだったものを、1つの「添付」ボタン + メニュー ("ファイルを選択" /
    /// "写真を選択" / "写真を撮る") にまとめた。「写真を撮る」は `CameraPicker`
    /// （`UIImagePickerController`ラッパー、実機のみ）を別シートで開く。iOS
    /// のみ (macOS にはカメラ/フォトピッカーの同等 API がない — 従来の
    /// 「ファイルを追加」的な `fileImporter` のみ)。
    private var attachmentsSection: some View {
        Section("添付ファイル") {
            ForEach(pendingAttachments) { attachment in
                AttachmentRow(attachment: attachment)
            }
            .onDelete { offsets in
                pendingAttachments.remove(atOffsets: offsets)
            }

            attachmentsMenu
        }
    }
    #endif

    @ViewBuilder
    private var attachmentsMenu: some View {
        #if os(iOS)
        Menu {
            Button {
                isImportingFile = true
            } label: {
                Label("ファイルを選択", systemImage: "doc")
            }
            .accessibilityIdentifier("composer.addFileButton")

            // `PhotosPicker`をトリガービューとしてメニュー項目に直接埋め込む
            // 代わりに、状態駆動の `.photosPicker(isPresented:selection:
            // matching:)` (`body` トップレベルに付与、`.sheet`/`.fileImporter`
            // と同じ置き場所) を使っている — こちらの方がこのアプリの他の
            // ピッカー系モディファイアの配置規約 (深い子ビューではなく`body`
            // 直下) に揃う。
            Button {
                isShowingPhotoPicker = true
            } label: {
                Label("写真を選択", systemImage: "photo")
            }
            .accessibilityIdentifier("composer.addPhotoButton")

            Button {
                isShowingCamera = true
            } label: {
                Label("写真を撮る", systemImage: "camera")
            }
            // カメラはシミュレータにハードウェアがなく常に利用不可 —
            // 「実機のみ動作、シミュレータではグレーアウト」の指示どおり、
            // 項目自体は残しつつ非活性にする（存在を隠さない）。
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            .accessibilityIdentifier("composer.addCameraButton")
        } label: {
            Label("添付", systemImage: "paperclip")
        }
        .accessibilityIdentifier("composer.attachMenu")
        // `.sheet(isPresented: $isShowingCamera)` はここではなく `body` の
        // トップレベルに付けている — 理由はそちら側のコメント参照。
        #else
        Button {
            isImportingFile = true
        } label: {
            Label("ファイルを追加", systemImage: "paperclip")
        }
        .accessibilityIdentifier("composer.addFileButton")
        #endif
    }

    #if os(iOS)
    private func handleCameraCapture(_ data: Data?) {
        isShowingCamera = false
        guard let data else { return }
        let filename = "camera-\(UUID().uuidString.prefix(8)).jpg"
        pendingAttachments.append(PendingAttachment(filename: filename, mimeType: "image/jpeg", data: data))
    }
    #endif

    /// C8: only shown when at least one template is available to the
    /// currently-selected `From` account (`availableTemplates`, kept in
    /// sync by `.task(id: selectedAccountId)` in `body`) — an empty `Menu`
    /// with nothing to pick would just be confusing. A `Menu` (not a
    /// `Picker`) since applying a template is an *action* (inserts text
    /// right away), not a persistent selection state.
    #if os(macOS)
    @ViewBuilder
    private var templateSection: some View {
        if !availableTemplates.isEmpty {
            Section {
                Menu {
                    ForEach(availableTemplates) { template in
                        Button(template.name) { applyTemplate(template) }
                    }
                } label: {
                    Label("テンプレートを挿入", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("composer.insertTemplateMenu")
            } header: {
                Text("テンプレート")
            }
        }
    }
    #endif

    /// C8: "署名的な使い方（本文の末尾に定型文）と、定型メール全体の両方に使える"
    /// — which of the two this does isn't a property of the template
    /// itself, just whether the Composer already has content: a
    /// completely blank new message (no subject, no body) gets the
    /// template's subject (if it has one) and body used wholesale, exactly
    /// like starting from a canned message; anything else (already typed
    /// a subject, already typed some body text, or a template with no
    /// subject of its own) appends the template's body to whatever's
    /// already there — the signature-style case.
    private func applyTemplate(_ template: MailTemplateRecord) {
        let isBlankComposition = subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlankComposition, let templateSubject = template.subject, !templateSubject.isEmpty {
            subject = templateSubject
            setPlainBody(template.body)
        } else if bodyText.isEmpty {
            setPlainBody(template.body)
        } else {
            appendPlainBody("\n\n" + template.body)
        }
    }

    private func loadAvailableTemplates() async {
        guard let selectedAccountId else {
            availableTemplates = []
            return
        }
        availableTemplates = (try? await environment.database.dbWriter.read { db in
            try MailTemplateRecord
                .filter(Column("accountId") == nil || Column("accountId") == selectedAccountId)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }) ?? []
    }

    /// F「作成画面に署名選択欄」— unlike `templateSection`'s `Menu` (an
    /// *action*), this is a `Picker` bound to persistent state
    /// (`selectedSignatureId`, via `selectedSignatureIdBinding` so a genuine
    /// user pick also records `LastSignatureSettingsStore`'s per-account
    /// memory). Task #162: 本文への挿入はもうしない — 署名の内容自体は
    /// `signatureBodyPreview`の読み取り専用プレビューで見せる。ラベルは常に
    /// 「署名: <名前>」/「署名: なし」形式 (実機フィードバック「いきなり『なし』
    /// だけだと分かりにくい」)。Only shown once at least one signature is
    /// scoped to the selected account — an empty picker with nothing but
    /// "なし" would be pointless chrome.
    #if os(macOS)
    @ViewBuilder
    private var signatureSection: some View {
        if !availableSignatures.isEmpty {
            Section {
                Picker("署名", selection: selectedSignatureIdBinding) {
                    Text("なし").tag(Int64?.none)
                    ForEach(availableSignatures) { signature in
                        Text(signature.name).tag(Optional(signature.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("composer.signaturePicker")
                signatureBodyPreview
            } header: {
                Text("署名")
            }
        }
    }
    #endif

    // MARK: - iOS flat layout
    //
    // 2026-07-29デザイン指示 (Spark ダークモード参考): `Form`/`Section`の
    // カード的なグループ化をやめ、背景に直接フィールドが並ぶミニマムな
    // フラットデザインへ。区切りは`.otegamiRowDivider()`（罫線1本）か余白の
    // みで、見出しラベルは基本置かない — 差出人/宛先/Cc/Bccだけは「ラベル:
    // フィールド」という最小限のインライン表記 (`ComposerFieldRow`) を使う。
    // 件名/本文はプレースホルダのみで、ラベル自体を出さない。
    //
    // このセクション全体を1つの`ScrollView`にまとめて`body`に直接書くと
    // （`Form`のときと同じ理由で）CI の型チェックタイムアウトを再発させる
    // 恐れがあるため、`flatContent`は各行を個別の computed property/型に
    // 割った上で並べるだけの薄いラッパーにしている。

    #if os(iOS)
    private var flatContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OtegamiSpacing.lg) {
                flatFromRow
                flatRecipientsSection
                flatSubjectRow
                flatBodySection
                flatSignatureRow
                // Task #125 「添付UIの位置」: 添付ボタン/添付済み一覧は本文＋
                // 署名の下 — 署名選択で本文末尾が変わっても、添付欄の位置が
                // それに引きずられて動かないようにする。Task #161: 添付を
                // "追加する"アクション自体 (`attachmentsMenu`) は下部バーに
                // 移した — ここに残るのは追加済みファイルの一覧のみ。
                flatAttachmentsSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("composer.errorMessage")
                }
            }
            .padding(.horizontal, OtegamiSpacing.lg)
            .padding(.vertical, OtegamiSpacing.md)
        }
        .background(OtegamiColor.background)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { flatBottomActionBar }
    }

    /// Task #161 (下部バーのSpark準拠再構成): pinned above the keyboard
    /// (`.safeAreaInset(edge: .bottom)` on `flatContent`'s `ScrollView`, not
    /// scrolling away with the rest of the form) — the formatting bar
    /// itself (only while `isFormattingBarVisible`) stacked directly above
    /// a persistent action row: 左に「T」(書式バーの開閉), その右にこれまで
    /// 本文の下に置いていた添付/テンプレートの各アクション。Spark の作成画面の
    /// 下部バー構成 (左にT、中央に添付/テンプレート群) に合わせた、既存の
    /// flat デザイン (da4d3a9/8f29a4b) と同じトーンの`surface`背景+罫線。
    ///
    /// A `VStack` of two already-small pieces (a conditional
    /// `RichTextFormattingBar` call, and a flat `HStack` of a handful of
    /// buttons) — kept this shallow deliberately, same
    /// type-check-timeout-avoidance reasoning as everywhere else in this
    /// file's "MARK: -" doc comments.
    private var flatBottomActionBar: some View {
        VStack(spacing: 0) {
            if isFormattingBarVisible {
                RichTextFormattingBar(controller: richTextEditingController, hasSelection: bodySelectedRange.length > 0)
                    .otegamiRowDivider()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: OtegamiSpacing.sm) {
                    FormatBarToggleButton(isActive: isFormattingBarVisible) {
                        isFormattingBarVisible.toggle()
                    }
                    Divider().frame(height: 20)
                    attachmentsMenu
                    flatTemplateSection
                }
                .padding(.horizontal, OtegamiSpacing.lg)
                .padding(.vertical, OtegamiSpacing.xs)
            }
        }
        .background(OtegamiColor.surface)
    }

    /// 「差出人 (From アカウント) 行は現行機能を維持しつつ同トーンの控えめな
    /// 行に」— `macOS`側の`fromSection`と同じ`Picker`/`selectedAccountId`
    /// バインディングをそのまま使い、ラベルだけ他の行 (宛先/Cc/Bcc) と揃えた
    /// 見た目にする。`.labelsHidden()`で`Picker`自身の既定ラベルを隠し、
    /// 手前の`Text("差出人:")`だけを見せているのは、他の行がすべて
    /// 「ラベル: 値」という共通の形なのに揃えるため。
    private var flatFromRow: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Text("差出人:")
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
            // 実機フィードバック (2026-07-29「アカウント選択が崩れてる」):
            // `.pickerStyle(.menu)`は選択中の行`Text`をそのままラベルに使う
            // ため、「表示名 <アドレス>」が長いと行内で3行に折り返れて崩れる。
            // `Menu`+`Picker`の入れ子 (選択チェックマークは`Picker`が維持) に
            // し、閉じた状態のラベルだけ1行・中間省略で描く。
            Menu {
                Picker("差出人", selection: $selectedAccountId) {
                    ForEach(environment.accounts) { account in
                        Text("\(account.displayName) <\(account.email)>")
                            .tag(Optional(account.id))
                    }
                }
            } label: {
                Text(verbatim: flatFromLabel)
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityIdentifier("composer.fromPicker")
            Spacer(minLength: 0)
        }
        // 実機フィードバック (2026-07-29「文字の一番下のラインが切れてる」):
        // `otegamiRowDivider()`は行コンテンツの下端に重ねる overlay で、
        // この行は`Menu`ラベルの`Text`高がコンテンツ高そのもの — 罫線が
        // ちょうど descender (g 等の下部) に被る。`TextField`の行 (宛先など)
        // は field 自身の内側余白で自然に逃げているので、この行だけ罫線の
        // 内側に最小トークン分の余白を足して揃える。
        .padding(.bottom, OtegamiSpacing.xs)
        .otegamiRowDivider()
        .padding(.bottom, OtegamiSpacing.sm)
    }

    /// `flatFromRow`の閉じた状態のラベル文字列。表示名とアドレスが同じ
    /// (表示名未設定でアドレスがそのまま入っている) アカウントでは
    /// 「a@example.com <a@example.com>」と冗長になるのでアドレス1本にする。
    private var flatFromLabel: String {
        guard let account = environment.accounts.first(where: { $0.id == selectedAccountId }) else {
            return "アカウントを選択"
        }
        if account.displayName.isEmpty || account.displayName == account.email {
            return account.email
        }
        return "\(account.displayName) <\(account.email)>"
    }

    /// 宛先行 (常に表示) + 「Cc: Bcc:」ピルボタン (`isShowingCcBcc`が`false`の
    /// 間だけ、宛先行の右端に表示) + Cc/Bcc行 (`isShowingCcBcc`が`true`に
    /// なったら表示、ピルは消える) — 詳細は`isCcBccExpandedByUser`/
    /// `isShowingCcBcc`の doc comment 参照。
    private var flatRecipientsSection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            HStack(spacing: OtegamiSpacing.sm) {
                Text("宛先:")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                TextField("", text: $toText)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("composer.to")
                if !isShowingCcBcc {
                    ComposerCcBccPillButton { isCcBccExpandedByUser = true }
                }
            }
            if isShowingCcBcc {
                ComposerFieldRow(label: "Cc:", text: $ccText, accessibilityIdentifier: "composer.cc")
                ComposerFieldRow(label: "Bcc:", text: $bccText, accessibilityIdentifier: "composer.bcc")
            }
        }
        .otegamiRowDivider()
        .padding(.bottom, OtegamiSpacing.sm)
    }

    /// 「プレースホルダのみのプレーン入力」— ラベルなし、`Form`の見出しも
    /// なし。件名の値そのものにはプレースホルダと違う色を使いたいわけでは
    /// ないので、`TextField`本体の既定のプレースホルダ描画に任せている。
    private var flatSubjectRow: some View {
        TextField("件名", text: $subject)
            .font(OtegamiFont.body())
            .accessibilityIdentifier("composer.subject")
            .otegamiRowDivider()
            .padding(.bottom, OtegamiSpacing.sm)
    }

    /// 本文: `RichTextEditor`自体はプレースホルダを知らない
    /// (`RichTextEditor`のdoc comment参照) ので、空のときだけ`ZStack`で
    /// プレースホルダの`Text`を重ねている — `UITextView`の既定の
    /// `textContainerInset`(top/bottom 8pt)/`lineFragmentPadding`(5pt)に
    /// おおよそ合わせた`padding`で、入力済みテキストの先頭とほぼ同じ位置に
    /// 見えるようにしている（厳密なピクセル一致は狙っていない — 1文字でも
    /// 入力されればプレースホルダ自体が消えるので実害は小さい）。
    private var flatBodySection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            ZStack(alignment: .topLeading) {
                if attributedBodyText.string.isEmpty {
                    Text("本文を入力してください")
                        .font(OtegamiFont.body())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                RichTextEditor(
                    attributedText: $attributedBodyText,
                    selectedRange: $bodySelectedRange,
                    controller: richTextEditingController,
                    accessibilityIdentifier: "composer.body"
                )
            }
            .frame(minHeight: 240)
        }
    }

    @ViewBuilder
    private var flatTemplateSection: some View {
        if !availableTemplates.isEmpty {
            Menu {
                ForEach(availableTemplates) { template in
                    Button(template.name) { applyTemplate(template) }
                }
            } label: {
                Label("テンプレートを挿入", systemImage: "doc.on.doc")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.accentText)
            }
            .accessibilityIdentifier("composer.insertTemplateMenu")
        }
    }

    /// 「署名: 本文下に「署名: なし」/「署名: <名前>」というグレーテキスト行 —
    /// タップで既存の署名選択。署名選択済みなら署名内容をその下にプレビュー
    /// 表示 (`signatureBodyPreview`)。」実機フィードバック「いきなり『なし』
    /// だけだと分かりにくい」を受けて、ラベルは常に「署名: 」を前置きする
    /// (`selectedSignatureLabel`)。
    ///
    /// 実機フィードバック続報 (2026-07-29「まだ『署名』という項目名がない」):
    /// 当初の `Picker(selection:label:)` + `.pickerStyle(.menu)` は、iOS では
    /// カスタムラベルを無視して**選択中の選択肢の`Text`(「なし」) をそのまま
    /// 表示する** — `flatFromRow`の差出人行が踏んだのと同じ落とし穴。同じ
    /// 修正 (`Menu`+`Picker`入れ子 — 選択チェックマークは内側の`Picker`が
    /// 維持し、閉じた状態の見た目は`Menu`の`label:`が完全に支配する) を
    /// 適用した。選択そのもの (`selectedSignatureId`、
    /// `selectedSignatureIdBinding`経由) はmacOS側の`signatureSection`と
    /// 完全に同じ状態を共有している。
    @ViewBuilder
    private var flatSignatureRow: some View {
        if !availableSignatures.isEmpty {
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Menu {
                    Picker(selection: selectedSignatureIdBinding) {
                        Text("なし").tag(Int64?.none)
                        ForEach(availableSignatures) { signature in
                            Text(signature.name).tag(Optional(signature.id))
                        }
                    } label: { EmptyView() }
                } label: {
                    Text(selectedSignatureLabel)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                }
                .accessibilityIdentifier("composer.signaturePicker")
                signatureBodyPreview
            }
        }
    }

    /// 添付済みファイル一覧: 装飾を他の行と同トーンに（`Section`の見出しなし）。
    /// macOS側の`attachmentsSection`が`List`の`.onDelete`（スワイプ削除）に
    /// 頼っているのに対し、`ScrollView`+`VStack`の中では`.onDelete`が機能
    /// しないため、各行に明示的な削除ボタン (`AttachmentRow(onRemove:)`) を
    /// 渡している。Task #161: 添付を追加するアクション自体
    /// (`attachmentsMenu`) は下部バー (`flatBottomActionBar`) に移した —
    /// ここは追加済みファイルが1件もなければ何も描画しない。
    @ViewBuilder
    private var flatAttachmentsSection: some View {
        if !pendingAttachments.isEmpty {
            VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentRow(attachment: attachment) {
                        pendingAttachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - F 署名 (プラットフォーム共通)

    private var selectedSignature: SignatureTemplateRecord? {
        guard let selectedSignatureId else { return nil }
        return availableSignatures.first(where: { $0.id == selectedSignatureId })
    }

    /// Task #162: 「署名: なし」「署名: <署名名>」形式 — 実機フィードバック
    ///「いきなり『なし』だけだと分かりにくい」を受けて、常に「署名: 」を
    /// 前置きする (以前は選択済みなら署名名のみ、未選択なら「署名なし」と
    /// 前置きなしだった)。
    private var selectedSignatureLabel: String {
        "署名: " + (selectedSignature?.name ?? "なし")
    }

    /// Task #162: 選択中の署名の本文を、編集不可・グレーのプレビューとして
    /// 表示する — 本文欄には何も挿入しない代わりに、送信時にどう結合される
    /// かをここで見せる。署名が「なし」なら何も描画しない。
    @ViewBuilder
    private var signatureBodyPreview: some View {
        if let selectedSignature, !selectedSignature.body.isEmpty {
            Text(selectedSignature.body)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("composer.signaturePreview")
        }
    }

    /// Task #162 (アカウント別の前回署名記憶): the `Picker`s' own binding —
    /// distinct from the raw `$selectedSignatureId` so a genuine user pick
    /// (routed through this binding's `set`) records
    /// `LastSignatureSettingsStore`'s per-account memory, while
    /// `loadAvailableSignatures()`'s programmatic clear-on-account-switch/
    /// auto-select (which assigns `selectedSignatureId` directly, bypassing
    /// this binding entirely) never does — see that store's doc comment for
    /// why conflating the two would corrupt the memory during an account
    /// switch.
    private var selectedSignatureIdBinding: Binding<Int64?> {
        Binding(
            get: { selectedSignatureId },
            set: { newValue in
                selectedSignatureId = newValue
                if let selectedAccountId {
                    LastSignatureSettingsStore.recordSelection(newValue, forAccountId: selectedAccountId)
                }
            }
        )
    }

    /// Reloads `availableSignatures` for `selectedAccountId` (`.task(id:)`
    /// in `body`, fired on every From-account switch too) and, whenever
    /// `selectedSignatureId` is still `nil` at that point, auto-selects one
    /// at the priority "前回選択 (`LastSignatureSettingsStore`) > アカウント
    /// 既定署名 (`AccountRecord.defaultSignatureId`) > なし".
    ///
    /// Task #162: this used to be restricted to a brand-new composition
    /// only (`payload.kind == .new`) — reply/forward/draft avoided
    /// auto-selecting because doing so used to *insert the signature's text
    /// into `bodyText`*, which could race against those flows' own
    /// asynchronous quoted-body prefill in `prepare()` (whichever finished
    /// last would win, unpredictably). Signatures no longer touch the body
    /// at all (only `send()` combines them, transiently — see
    /// `RichTextDocument.appendingSignature(_:)`), so that race can no
    /// longer happen, and this now runs for every composition kind — a
    /// reply/forward switched to a different `From` account now also picks
    /// up that account's last-used (or default) signature, matching the
    /// plan's "差出人アカウントを切り替えたらそのアカウントの前回署名に追随".
    private func loadAvailableSignatures() async {
        guard let selectedAccountId else {
            availableSignatures = []
            return
        }
        let all = (try? await environment.database.dbWriter.read { db in
            try SignatureTemplateRecord.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
        availableSignatures = all.filter { $0.accountIds.contains(selectedAccountId) }

        if let selectedSignatureId, !availableSignatures.contains(where: { $0.id == selectedSignatureId }) {
            // The previous pick doesn't apply to the (possibly just-
            // switched) account anymore.
            self.selectedSignatureId = nil
        }

        guard selectedSignatureId == nil else { return }
        if let lastSelection = LastSignatureSettingsStore.lastSelection(forAccountId: selectedAccountId) {
            // A past explicit choice is on record for this account — honor
            // it verbatim, including an explicit past "なし"
            // (`lastSelection == .some(nil)`, which leaves `selectedSignatureId`
            // at its current `nil` and does nothing further below). If the
            // recorded id no longer resolves to a signature actually scoped
            // to this account (deleted, or reassigned to a different
            // account since), fall through to the account-default check
            // below instead of leaving a stale, unusable id selected.
            if let lastId = lastSelection, availableSignatures.contains(where: { $0.id == lastId }) {
                selectedSignatureId = lastId
                return
            }
            if lastSelection == nil { return }
        }
        if let account = environment.accounts.first(where: { $0.id == selectedAccountId }),
           let defaultId = account.defaultSignatureId,
           availableSignatures.contains(where: { $0.id == defaultId }) {
            selectedSignatureId = defaultId
        }
    }

    private var navigationTitle: String {
        // `.navigationTitle(navigationTitle)`は`String`版のオーバーロードに
        // 解決されるため (verbatim)、`String(localized:)`で明示的に
        // ローカライズする。
        switch payload.kind {
        case .new: String(localized: "新規作成")
        case .reply(_, let replyAll): replyAll ? String(localized: "全員に返信") : String(localized: "返信")
        case .forward: String(localized: "転送")
        case .draft, .serverDraft: String(localized: "下書き")
        case .cancelledSend: String(localized: "新規作成")
        case .mailto: String(localized: "新規作成")
        }
    }

    private var isFormValid: Bool {
        selectedAccountId != nil && !toText.trimmingCharacters(in: .whitespaces).isEmpty && !subject.isEmpty
    }

    // MARK: - Setup

    private func prepare() async {
        if selectedAccountId == nil {
            // G「デフォルトのアカウント」: prefer the configured default when
            // it still matches a current account; otherwise fall back to
            // the pre-existing "first account" behavior (also what runs
            // when no default has ever been picked, since `defaultAccountId`
            // defaults to `""`, which never matches a real account id).
            selectedAccountId = environment.accounts.first(where: { $0.id == defaultAccountId })?.id
                ?? environment.accounts.first?.id
        }
        attachUITestFixtureIfRequested()
        switch payload.kind {
        case .new:
            break
        case .reply(let originalMessageId, let replyAll):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await prefillReply(toOriginalMessageId: originalMessageId, replyAll: replyAll)
        case .forward(let originalMessageId):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await prefillForward(originalMessageId: originalMessageId)
        case .draft(let draftId):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await loadDraft(draftId: draftId)
        case .serverDraft(let messageId):
            isLoadingReplyContext = true
            defer { isLoadingReplyContext = false }
            await loadServerDraft(messageId: messageId)
        case .cancelledSend(let snapshot):
            // C7: everything needed travels in the payload itself — no
            // database/network round trip, unlike `.draft`/`.serverDraft`
            // (see `ComposerLaunchPayload.Kind.cancelledSend`'s doc
            // comment for why).
            loadCancelledSend(snapshot)
        case .mailto(let prefill):
            // Task #48: `MailtoComposePrefill`'s address lists are already
            // plain `addr-spec` strings (`MailtoURLParser`'s output, never
            // display names), so joining them is enough — no
            // `EmailAddress.description` round-trip needed the way
            // `loadDraft`/`loadServerDraft` do from a stored `[EmailAddress]`.
            toText = prefill.to.joined(separator: ", ")
            ccText = prefill.cc.joined(separator: ", ")
            bccText = prefill.bcc.joined(separator: ", ")
            subject = prefill.subject
            setPlainBody(prefill.body)
        }
        // Baseline for `hasUnsavedChanges` — captured last, after whatever
        // prefill above (reply quoting, or a resumed draft's saved text)
        // has already landed in the `@State` fields. See its doc comment.
        initialSnapshot = currentSnapshot
    }

    /// Resuming a saved local draft (M10): loads its fields, then deletes
    /// the row immediately — `ComposerLaunchPayload.Kind.draft`'s doc
    /// comment explains why ("load transfers ownership" avoids needing
    /// update-vs-insert branching in `saveDraft()`). Best-effort: if the
    /// row is already gone (e.g. deleted from `DraftsView` in another
    /// window right as this one opened), the Composer just opens blank
    /// rather than erroring.
    ///
    /// Drafts IMAP sync: also carries forward `serverMailboxId`/`serverUid`/
    /// `serverUidValidity` (this row may itself be a mirror of a previous
    /// save's server copy) into `draftServerMailboxId`/etc. for
    /// `saveDraft()`'s replace flow, and restores any `draftAttachment`
    /// rows into `pendingAttachments` by reading their bytes back off disk
    /// — read *before* the row delete (which cascades them away), then the
    /// now-orphaned files are removed once their bytes are safely in memory
    /// (mirrors `OpQueueProcessor.deleteOutboxMessage`'s "read paths,
    /// delete row, then unlink" order). A fresh `saveDraft()` re-stages
    /// whatever's still in `pendingAttachments` to new files, so nothing
    /// keeps pointing at the removed ones.
    private func loadDraft(draftId: Int64) async {
        struct Loaded {
            var draft: DraftMessageRecord
            var attachments: [DraftAttachmentRecord]
        }
        let loaded: Loaded? = try? await environment.database.dbWriter.write { db in
            guard let draft = try DraftMessageRecord.fetchOne(db, key: draftId) else { return nil }
            let attachments = try DraftAttachmentRecord.filter(Column("draftMessageId") == draftId).fetchAll(db)
            try draft.delete(db)
            return Loaded(draft: draft, attachments: attachments)
        }
        guard let loaded else { return }
        let draft = loaded.draft
        selectedAccountId = draft.accountId
        toText = draft.toAddresses.map(\.description).joined(separator: ", ")
        ccText = draft.ccAddresses.map(\.description).joined(separator: ", ")
        subject = draft.subject
        // Task #161: restore formatting when this draft has an
        // `htmlBody` (every draft saved from here on) — same decode
        // path `loadCancelledSend(_:)` already uses for C7's cancelled-
        // send restore. Falls back to the plain-text projection for a
        // draft saved before this task (schema predates `htmlBody`, or
        // resumed from a `.serverDraft` this Composer session itself
        // hasn't re-saved yet).
        if let htmlBody = draft.htmlBody {
            attributedBodyText = RichTextAttributedString.makeAttributedString(from: RichTextHTMLCoder.decode(html: htmlBody))
        } else {
            setPlainBody(draft.plainTextBody)
        }
        // Task #162: the signature choice this draft was saved with —
        // restored verbatim (never re-derived) rather than left for
        // `loadAvailableSignatures()`'s auto-select to fill in, same as
        // every other field above. `nil` for a draft this schema predates
        // (no migration) or one whose signature was still literal text
        // inside `plainTextBody` back then — either way `selectedSignatureId`
        // simply falls through to the normal auto-select priority chain.
        selectedSignatureId = draft.signatureId
        inReplyToMessageId = draft.inReplyToMessageId
        references = draft.references
        draftServerMailboxId = draft.serverMailboxId
        draftServerUid = draft.serverUid
        draftServerUidValidity = draft.serverUidValidity

        for attachment in loaded.attachments {
            guard let data = FileManager.default.contents(atPath: attachment.localPath) else { continue }
            pendingAttachments.append(PendingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        for attachment in loaded.attachments {
            try? FileManager.default.removeItem(atPath: attachment.localPath)
        }
    }

    /// C7 送信キャンセル: restores every field a cancelled pending send had,
    /// synchronously — see `ComposerLaunchPayload.Kind.cancelledSend`'s doc
    /// comment.
    ///
    /// Task #156: restores formatting too when `snapshot.htmlBody` is
    /// present (decode the HTML back to a `RichTextDocument`, then rebuild
    /// the live `NSAttributedString` — `RichTextAttributedString
    /// .makeAttributedString(from:)`'s doc comment) instead of always
    /// falling back to the plain-text projection, so cancelling a formatted
    /// send and reopening it doesn't silently strip the bold/italic/
    /// underline/strikethrough/list/indent the user had applied.
    private func loadCancelledSend(_ snapshot: PendingSendDraftSnapshot) {
        selectedAccountId = snapshot.accountId
        toText = snapshot.toText
        ccText = snapshot.ccText
        bccText = snapshot.bccText
        subject = snapshot.subject
        if let htmlBody = snapshot.htmlBody {
            attributedBodyText = RichTextAttributedString.makeAttributedString(from: RichTextHTMLCoder.decode(html: htmlBody))
        } else {
            setPlainBody(snapshot.bodyText)
        }
        // Task #162: the signature selected at send time — restored
        // straight into `selectedSignatureId` (not mixed back into the
        // body, which `snapshot.bodyText`/`.htmlBody` never contained in
        // the first place).
        selectedSignatureId = snapshot.signatureId
        inReplyToMessageId = snapshot.inReplyToMessageId
        references = snapshot.references
        pendingAttachments = snapshot.attachments
        draftServerMailboxId = snapshot.draftServerMailboxId
        draftServerUid = snapshot.draftServerUid
        draftServerUidValidity = snapshot.draftServerUidValidity
    }

    /// Resuming a server-origin draft (Drafts IMAP sync): a `message` row
    /// living in a `MailboxRoleRecord.drafts` mailbox that no local
    /// `draftMessage` row has claimed (`DraftQuery.UnifiedRow.server`).
    /// Unlike `loadDraft(draftId:)`, this deletes/consumes nothing — the
    /// server remains the sole source of truth until (and unless) the user
    /// actually saves an edit, at which point `saveDraft()` creates a new
    /// `draftMessage` row carrying `draftServerMailboxId`/`draftServerUid`/
    /// `draftServerUidValidity` (captured here) forward as "the old copy to
    /// replace". Fetches the body over the network first if it hasn't been
    /// fetched yet (same on-demand pattern `MessageView.load()` uses for
    /// any message) and downloads every attachment's bytes into
    /// `pendingAttachments` the same way (`AttachmentFetcher`, via
    /// `SyncCoordinator.fetchAttachment`) — best-effort throughout: a
    /// network failure here just leaves the Composer with whatever text/
    /// attachments it already had (from local `message`/`messageBody`/
    /// `attachment` rows if any), never an error blocking the open.
    private func loadServerDraft(messageId: Int64) async {
        struct Context {
            var message: MessageRecord
            var accountId: String
            var mailboxPath: String
            var mailboxId: Int64
            var mailboxUidValidity: Int64
            var referenceValues: [String]
            var bodyRecord: MessageBodyRecord?
            var attachments: [AttachmentRecord]
        }

        let context: Context? = try? await environment.database.dbWriter.read { db -> Context? in
            guard let message = try MessageRecord.fetchOne(db, key: messageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId), let mailboxId = mailbox.id else { return nil }
            let referenceValues = try MessageReferenceRecord
                .filter(Column("messageId") == messageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: messageId)
            let attachments = try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
            return Context(
                message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path,
                mailboxId: mailboxId, mailboxUidValidity: mailbox.uidValidity,
                referenceValues: referenceValues, bodyRecord: bodyRecord, attachments: attachments
            )
        }
        guard var context else { return }

        selectedAccountId = context.accountId
        toText = context.message.toAddresses.map(\.description).joined(separator: ", ")
        ccText = context.message.ccAddresses.map(\.description).joined(separator: ", ")
        subject = context.message.subject ?? ""
        inReplyToMessageId = context.message.inReplyTo
        references = context.referenceValues

        draftServerMailboxId = context.mailboxId
        draftServerUid = context.message.uid
        draftServerUidValidity = context.mailboxUidValidity

        let account = environment.accounts.first { $0.id == context.accountId }
        var auth: MailAuth?
        if let account {
            auth = try? await environment.auth(for: account)
        }

        if context.message.bodyState != .fetched, let account, let auth {
            try? await environment.syncCoordinator.fetchBody(for: context.message, mailboxPath: context.mailboxPath, account: account, auth: auth)
            context.bodyRecord = try? await environment.database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: messageId) }
            context.attachments = (try? await environment.database.dbWriter.read { db in
                try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
            }) ?? context.attachments
        }

        if let plainText = context.bodyRecord?.plainText, !plainText.isEmpty {
            setPlainBody(plainText)
        } else if let html = context.bodyRecord?.html, !html.isEmpty {
            setPlainBody(HTMLTextExtractor.plainText(fromHTML: html))
        } else {
            setPlainBody("")
        }

        if let account, let auth {
            for attachment in context.attachments {
                guard let fetched = try? await environment.syncCoordinator.fetchAttachment(
                    attachment, messageUID: context.message.uid, mailboxPath: context.mailboxPath, account: account, auth: auth
                ), let localPath = fetched.localPath, let data = FileManager.default.contents(atPath: localPath) else { continue }
                pendingAttachments.append(
                    PendingAttachment(
                        filename: fetched.filename ?? "attachment",
                        mimeType: "\(fetched.mimeType)/\(fetched.mimeSubtype)",
                        data: data
                    )
                )
            }
        }
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

    /// Persists the current fields as a new `DraftMessageRecord` row, stages
    /// any `pendingAttachments` to disk as `draftAttachment` rows, and
    /// enqueues `OpQueueKind.saveDraft` to `APPEND` it to the account's
    /// Drafts mailbox (Drafts IMAP sync milestone — the M10-era
    /// local-only/attachment-dropping behavior this doc comment used to
    /// describe is superseded; see `DraftMessageRecord`'s doc comment for
    /// the full replace-flow design). `draftServerMailboxId`/`draftServerUid`/
    /// `draftServerUidValidity` — populated by `loadDraft(draftId:)`/
    /// `loadServerDraft(messageId:)` when this Composer session resumed an
    /// already-uploaded-or-downloaded draft — are carried onto the new row
    /// as "the old server copy to replace"; `OpQueueProcessor`'s
    /// `.saveDraft` replay reads them back off that row at replay time.
    private func saveDraft() async {
        guard let accountId = selectedAccountId else { return }
        let toAddresses = Self.parseAddresses(toText)
        let ccAddresses = Self.parseAddresses(ccText)
        // Nothing at all to save (a blank "新規作成" opened and immediately
        // cancelled without `hasUnsavedChanges` ever going true reaches
        // `dismiss()` directly in `handleCloseRequested()`, so this handles
        // the rarer case of unsaved *whitespace-only* edits) — skip writing
        // an empty row. Attachments alone (no text at all) still count as
        // "something to save" — `pendingAttachments` reaching here nonempty
        // only happens via an explicit user action (picker/photo/loaded
        // from an existing draft), never as a side effect of doing nothing.
        guard !toAddresses.isEmpty || !ccAddresses.isEmpty || !subject.isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
        else {
            return
        }
        do {
            let stagedAttachments = try Self.stageAttachments(pendingAttachments, subdirectory: "Drafts")

            try await environment.database.dbWriter.write { db in
                var draft = DraftMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    subject: subject,
                    plainTextBody: bodyText,
                    htmlBody: bodySnapshotString,
                    // Task #162: the signature choice, kept separate from
                    // the body above (never mixed in) — see
                    // `DraftMessageRecord.signatureId`'s doc comment.
                    signatureId: selectedSignatureId,
                    inReplyToMessageId: inReplyToMessageId,
                    references: references,
                    serverMailboxId: draftServerMailboxId,
                    serverUid: draftServerUid,
                    serverUidValidity: draftServerUidValidity
                )
                try draft.insert(db)
                guard let draftId = draft.id else { return }
                for staged in stagedAttachments {
                    var attachmentRecord = DraftAttachmentRecord(
                        draftMessageId: draftId, filename: staged.filename,
                        mimeType: staged.mimeType, localPath: staged.url.path, size: staged.size
                    )
                    try attachmentRecord.insert(db)
                }
                try OpQueue.enqueueSaveDraft(accountId: accountId, draftMessageId: draftId, db: db)
            }

            // Best-effort immediate replay, same pattern as `send()` below
            // — harmless if offline, the op just waits for the next
            // successful connection.
            if let account = environment.accounts.first(where: { $0.id == accountId }), let auth = try? await environment.auth(for: account) {
                Task { _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth) }
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

        setPlainBody("\n\n" + quotedBody(from: context.bodyRecord))
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

    /// 新画面構成 (3): メール本文画面フッターツールバーの「転送」。件名に `Fwd: `
    /// を付け、`quotedBody(from:)` (返信と同じ `> ` 引用) の前に転送元の
    /// From/Date/Subject/To を示すヘッダーブロックを差し込む。宛先 (To/Cc) は
    /// 空のまま — 転送は「誰に送るか」をユーザーが必ず選び直す操作なので、
    /// 元メールの宛先を引き継がない (`prefillReply`との一番の違い)。
    ///
    /// **添付ファイルの引き継ぎ**: `loadServerDraft(messageId:)`と全く同じ経路
    /// (`environment.syncCoordinator.fetchAttachment`) で、本文が未取得なら
    /// ネットワーク越しに取得してから引き継ぐ。取得できなかった添付が1つでも
    /// あれば (オフライン、認証エラー等)、本文の末尾にその旨を追記する —
    /// 指示の「引き継がないなら本文にその旨表示」を、"全く引き継がない"では
    /// なく "引き継げなかった分だけ明示する" 形で実装した (取得できる限りは
    /// 引き継ぐ方が実用的なため)。
    private func prefillForward(originalMessageId: Int64) async {
        struct ForwardContext {
            var message: MessageRecord
            var accountId: String
            var mailboxPath: String
            var bodyRecord: MessageBodyRecord?
            var attachments: [AttachmentRecord]
        }

        let context: ForwardContext? = try? await environment.database.dbWriter.read { db -> ForwardContext? in
            guard let message = try MessageRecord.fetchOne(db, key: originalMessageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { return nil }
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: originalMessageId)
            let attachments = try AttachmentRecord.filter(Column("messageId") == originalMessageId).order(Column("id")).fetchAll(db)
            return ForwardContext(message: message, accountId: mailbox.accountId, mailboxPath: mailbox.path, bodyRecord: bodyRecord, attachments: attachments)
        }
        guard var context else { return }

        selectedAccountId = context.accountId
        subject = "Fwd: " + SubjectNormalizer.normalize(context.message.subject ?? "")
        // Deliberately no `inReplyToMessageId`/`references` — see
        // `ComposerLaunchPayload.Kind.forward`'s doc comment.

        let account = environment.accounts.first { $0.id == context.accountId }
        var auth: MailAuth?
        if let account {
            auth = try? await environment.auth(for: account)
        }

        if context.message.bodyState != .fetched, let account, let auth {
            try? await environment.syncCoordinator.fetchBody(for: context.message, mailboxPath: context.mailboxPath, account: account, auth: auth)
            context.bodyRecord = try? await environment.database.dbWriter.read { db in try MessageBodyRecord.fetchOne(db, key: originalMessageId) }
            context.attachments = (try? await environment.database.dbWriter.read { db in
                try AttachmentRecord.filter(Column("messageId") == originalMessageId).order(Column("id")).fetchAll(db)
            }) ?? context.attachments
        }

        setPlainBody("\n\n" + forwardHeaderBlock(for: context.message) + "\n\n" + quotedBody(from: context.bodyRecord))

        var someAttachmentFailedToCarryOver = false
        if let account, let auth {
            for attachment in context.attachments {
                guard let fetched = try? await environment.syncCoordinator.fetchAttachment(
                    attachment, messageUID: context.message.uid, mailboxPath: context.mailboxPath, account: account, auth: auth
                ), let localPath = fetched.localPath, let data = FileManager.default.contents(atPath: localPath) else {
                    someAttachmentFailedToCarryOver = true
                    continue
                }
                pendingAttachments.append(
                    PendingAttachment(
                        filename: fetched.filename ?? "attachment",
                        mimeType: "\(fetched.mimeType)/\(fetched.mimeSubtype)",
                        data: data
                    )
                )
            }
        } else if !context.attachments.isEmpty {
            someAttachmentFailedToCarryOver = true
        }
        if someAttachmentFailedToCarryOver {
            appendPlainBody("\n\n(元メールの添付ファイルを一部引き継げませんでした。必要であれば改めて添付してください。)")
        }
    }

    /// 転送メールの本文冒頭に差し込む「---------- 転送されたメッセージ ----------」
    /// ブロック — 多くのメールクライアントが転送時に付ける慣習的な見出し。
    private func forwardHeaderBlock(for message: MessageRecord) -> String {
        var lines = ["---------- 転送されたメッセージ ----------"]
        if let from = message.fromAddresses.first {
            lines.append("From: \(from.description)")
        }
        lines.append("Date: \((message.date ?? message.internalDate).formatted(.dateTime.year().month().day().hour().minute()))")
        lines.append("Subject: \(message.subject ?? "")")
        if !message.toAddresses.isEmpty {
            lines.append("To: \(message.toAddresses.map(\.description).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
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
        let bccAddresses = Self.parseAddresses(bccText)

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
            let stagedAttachments = try Self.stageAttachments(pendingAttachments, subdirectory: "Outbox")

            // Task #162: "本文 + 空行 + 署名" combined exactly once, here, for
            // the actual RFC822 payload — see `bodyDocumentWithSignature`'s
            // doc comment for why the plain/HTML pair is derived from one
            // shared `RichTextDocument` rather than two independently-built
            // strings.
            let sendDocument = bodyDocumentWithSignature
            let outboxId: Int64? = try await environment.database.dbWriter.write { db in
                var outbox = OutboxMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    bccAddresses: bccAddresses,
                    subject: subject,
                    plainTextBody: sendDocument.plainText,
                    htmlBody: RichTextHTMLCoder.encode(sendDocument),
                    inReplyToMessageId: inReplyToMessageId,
                    references: references,
                    draftServerMailboxId: draftServerMailboxId,
                    draftServerUid: draftServerUid,
                    draftServerUidValidity: draftServerUidValidity
                )
                try outbox.insert(db)
                guard let outboxId = outbox.id else { return nil }
                for staged in stagedAttachments {
                    var attachmentRecord = OutboxAttachmentRecord(
                        outboxMessageId: outboxId, filename: staged.filename,
                        mimeType: staged.mimeType, localPath: staged.url.path, size: staged.size
                    )
                    try attachmentRecord.insert(db)
                }
                try OpQueue.enqueueSend(accountId: accountId, outboxMessageId: outboxId, db: db)
                return outboxId
            }

            // C6/C7: the message is already durably queued at this point
            // (the transaction above committed) — everything from here on
            // only decides *when* it's allowed to actually leave, never
            // whether it's lost. `dismiss()` happens unconditionally
            // either way, matching the pre-C7 behavior of closing the
            // Composer the instant the local write succeeds.
            dismiss()
            guard let outboxId else { return }
            Self.pendingSendLogger.notice("enqueued: outboxMessageId=\(outboxId, privacy: .public) accountId=\(accountId, privacy: .private)")

            #if os(iOS)
            // iOS only (`SendCancelWindow`'s doc comment covers the "why
            // not 30s/60s" reasoning; macOS's Composer is its own window
            // rather than a sheet over a persistent tab bar, so there's no
            // natural home for `SendCountdownBar` there — send stays
            // immediate on that platform, matching every prior milestone's
            // behavior).
            if let duration = SendCancelWindow(rawValue: sendCancelWindowRaw)?.duration ?? SendCancelSettingsStore.defaultWindow.duration {
                // Task #162: deliberately the *unmerged* body (`bodyText`/
                // `bodySnapshotString`, not `sendDocument` above) plus the
                // signature choice kept separate — reopening a cancelled
                // send should show the same editable body and signature
                // preview the Composer had, not the body with the
                // signature already baked into it.
                let snapshot = PendingSendDraftSnapshot(
                    accountId: accountId, toText: toText, ccText: ccText, bccText: bccText, subject: subject, bodyText: bodyText,
                    htmlBody: bodySnapshotString,
                    signatureId: selectedSignatureId,
                    inReplyToMessageId: inReplyToMessageId, references: references,
                    attachments: pendingAttachments,
                    draftServerMailboxId: draftServerMailboxId, draftServerUid: draftServerUid, draftServerUidValidity: draftServerUidValidity
                )
                await environment.pendingSendCoordinator.schedule(outboxMessageId: outboxId, accountId: accountId, duration: duration, snapshot: snapshot)
                return
            }
            #endif

            // Cancel window is "なし" (or this is macOS): best-effort
            // immediate replay, same pattern as
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
    /// `<Application Support>/otegami/<subdirectory>/<UUID>/<filename>` —
    /// one fresh, randomly-named directory per attachment (rather than
    /// nesting under the not-yet-known outbox/draft message id, since these
    /// files are written *before* that row's `db.write` transaction even
    /// starts; `OutboxAttachmentRecord`/`DraftAttachmentRecord.localPath` is
    /// what associates the file back to its message afterward, not its
    /// position in this directory tree). `subdirectory` is `"Outbox"` for
    /// `send()`, `"Drafts"` for `saveDraft()` — two separate trees under one
    /// `otegami/` folder (mirrors `AttachmentFetcher.storageURL`'s "everything
    /// under one `otegami/` folder in Application Support" convention on the
    /// received side) so a draft's staged files are never mistaken for (or
    /// cleaned up alongside) an outbox message's.
    private static func stageAttachments(_ pending: [PendingAttachment], subdirectory: String) throws -> [StagedAttachment] {
        guard !pending.isEmpty else { return [] }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("otegami/\(subdirectory)", isDirectory: true)

        return try pending.map { attachment in
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
/// holds raw `Data` rather than a URL. Not `private` (unlike this file's
/// other small helper types): C7's `PendingSendCoordinator` also needs this
/// shape to carry a cancelled send's attachments back into a freshly
/// reopened `ComposerView` without re-reading them from disk — see
/// `PendingSendDraftSnapshot.attachments`.
struct PendingAttachment: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
}

/// One row inside `ComposerView.attachmentsSection`'s `ForEach` — pulled out
/// into its own `View` type (not just a smaller closure) since it still has
/// a multi-line `HStack`/`VStack`/two-`Text` shape; see `ComposerView`'s
/// "MARK: - Form sections" doc comment for why this split was necessary.
private struct AttachmentRow: View {
    let attachment: PendingAttachment
    /// 2026-07-29デザイン指示: iOSのフラットレイアウト (`ComposerView
    /// .flatAttachmentsSection`) は`List`の外なので`.onDelete`のスワイプ
    /// 削除が使えない — その代わりにこの行自身へ明示的な削除ボタンを渡す。
    /// macOS側の`attachmentsSection`（`List`/`.onDelete`のまま）は`nil`の
    /// ままなので見た目は変わらない。
    var onRemove: (() -> Void)? = nil

    var body: some View {
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
            if let onRemove {
                Spacer(minLength: OtegamiSpacing.sm)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OtegamiColor.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachment.\(attachment.id).remove")
            }
        }
        .accessibilityIdentifier("composer.attachment.\(attachment.id)")
    }
}

/// 2026-07-29デザイン指示: 宛先行の「ラベル: フィールド」という最小限の
/// インライン表記 — Cc/Bcc両方に使う小さな共通行。`accessibilityIdentifier`
/// は行全体ではなく`TextField`自体に付ける（既存のUITestが
/// `app.textFields["composer.cc"]`のように`textFields`経由でクエリする
/// ため、`HStack`側に付けても見つからない）。
private struct ComposerFieldRow: View {
    let label: String
    @Binding var text: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Text(label)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
            TextField("", text: $text)
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

/// 2026-07-29デザイン指示: 宛先行の右端に出す「Cc: Bcc:」丸角アウトライン
/// ピルボタン。`OtegamiRadius`は原則フラット（角丸0）だが、`SearchTopBar`
/// が検索画面のトップバーで既に確立した「カプセル/円は個別ビュー内だけの
/// 閉じたスコープの例外として`Capsule()`/`Circle()`を直接使う」という前例
/// (`OtegamiBorder.swift`のdoc comment参照) に倣い、ここでも新しい
/// `OtegamiRadius`トークンを追加せず`Capsule()`をこのビュー内だけで使う。
#if os(iOS)
/// Task #161 (下部バーのSpark準拠再構成): the "T" button that toggles
/// `RichTextFormattingBar`'s visibility in `flatBottomActionBar` — same
/// small-leaf-view shape as `RichTextFormattingBar`'s own `FormatBarButton`
/// (not reused directly since that one is `private` to that file and this
/// button's highlighted-when-open state is `ComposerView`'s own concern,
/// not the formatting bar's).
private struct FormatBarToggleButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "T")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 32)
                .foregroundStyle(isActive ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? OtegamiColor.paleBaseStrong : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.formatBarToggle")
    }
}
#endif

private struct ComposerCcBccPillButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "Cc: Bcc:")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .padding(.horizontal, OtegamiSpacing.md)
                .padding(.vertical, OtegamiSpacing.xs)
                .overlay(
                    Capsule().strokeBorder(OtegamiColor.dividerSubtle, lineWidth: OtegamiStroke.secondary)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.showCcBccButton")
    }
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
