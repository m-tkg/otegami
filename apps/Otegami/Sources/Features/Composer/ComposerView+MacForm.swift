import SwiftUI

extension ComposerView {
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
    var fromSection: some View {
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

    var addressSection: some View {
        Section {
            RecipientInputField(
                style: .labeled("宛先:"), text: $toText, prompt: Text("カンマ区切りで複数指定可"),
                accessibilityIdentifier: "composer.to", occurrences: recipientOccurrences
            )
            RecipientInputField(
                style: .labeled("Cc:"), text: $ccText, prompt: Text("カンマ区切りで複数指定可"),
                accessibilityIdentifier: "composer.cc", occurrences: recipientOccurrences
            )
            RecipientInputField(
                style: .labeled("Bcc:"), text: $bccText, prompt: Text("カンマ区切りで複数指定可"),
                accessibilityIdentifier: "composer.bcc", occurrences: recipientOccurrences
            )
        }
    }

    var subjectSection: some View {
        Section {
            TextField("件名:", text: $subject)
                .accessibilityIdentifier("composer.subject")
        }
    }

    var bodySection: some View {
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
    var attachmentsSection: some View {
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

    /// C8: only shown when at least one template is available to the
    /// currently-selected `From` account (`availableTemplates`, kept in
    /// sync by `.task(id: selectedAccountId)` in `body`) — an empty `Menu`
    /// with nothing to pick would just be confusing. A `Menu` (not a
    /// `Picker`) since applying a template is an *action* (inserts text
    /// right away), not a persistent selection state.
    #if os(macOS)
    @ViewBuilder
    var templateSection: some View {
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
    var signatureSection: some View {
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
}

/// One row inside `ComposerView.attachmentsSection`'s `ForEach` — pulled out
/// into its own `View` type (not just a smaller closure) since it still has
/// a multi-line `HStack`/`VStack`/two-`Text` shape; see `ComposerView`'s
/// "MARK: - Form sections" doc comment for why this split was necessary.
struct AttachmentRow: View {
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
