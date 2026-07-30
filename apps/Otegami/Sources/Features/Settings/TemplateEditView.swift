import SwiftUI
import GRDB
import OtegamiStore

/// Add/edit sheet for one `MailTemplateRecord` (C8) — `template == nil`
/// means "creating a new one". A plain state-in-`@State`, save-on-toolbar-
/// button form, same shape as `AccountSetupView`'s simpler fields (no
/// save-as-draft/discard confirmation dance like `ComposerView`'s, since a
/// template being edited isn't itself a message anyone could lose — "キャン
/// セル" just discards the in-progress edit).
struct TemplateEditView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let template: MailTemplateRecord?

    @State private var name = ""
    @State private var subject = ""
    @State private var bodyText = ""
    /// `nil` = "すべてのアカウント" (visible everywhere) — see
    /// `MailTemplateRecord.accountId`'s doc comment.
    @State private var scopedAccountId: String?
    @State private var isSaving = false

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                accountSection
                subjectSection
                bodySection
            }
            .navigationTitle(template == nil ? "テンプレートを追加" : "テンプレートを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("templateEdit.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .accessibilityIdentifier("templateEdit.saveButton")
                    .disabled(!isFormValid || isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
        .onAppear { loadExistingIfNeeded() }
    }

    private var nameSection: some View {
        Section("名前") {
            TextField("例: 定型の署名", text: $name)
                .accessibilityIdentifier("templateEdit.name")
        }
    }

    private var accountSection: some View {
        Section {
            Picker("使用するアカウント", selection: $scopedAccountId) {
                Text("すべてのアカウント").tag(String?.none)
                ForEach(environment.accounts) { account in
                    Text(account.displayName).tag(Optional(account.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("templateEdit.accountPicker")
        } footer: {
            Text("特定のアカウントを選ぶと、そのアカウントで作成中のメールでだけこのテンプレートを使えます。")
        }
    }

    private var subjectSection: some View {
        Section {
            TextField("件名", text: $subject)
                .accessibilityIdentifier("templateEdit.subject")
        } header: {
            Text("件名（任意）")
        } footer: {
            Text("件名を入れておくと、新規作成の本文・件名が両方空のときにこのテンプレートで両方埋められます。空のままなら本文だけが挿入されます（署名のような使い方）。")
        }
    }

    private var bodySection: some View {
        Section("本文") {
            TextEditor(text: $bodyText)
                .frame(minHeight: 200)
                .accessibilityIdentifier("templateEdit.body")
        }
    }

    private func loadExistingIfNeeded() {
        guard let template else { return }
        name = template.name
        subject = template.subject ?? ""
        bodyText = template.body
        scopedAccountId = template.accountId
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // Built fully before the `dbWriter.write` closure below and never
        // mutated again from this scope — Swift 6 strict concurrency
        // otherwise flags mutating a captured `var` inside that closure
        // (it runs on GRDB's own queue, so the closure is `@Sendable`).
        // The closure below makes its own local `var` copy to actually
        // insert/update.
        let editedFields = template ?? MailTemplateRecord(name: name, body: bodyText)
        let existingId = editedFields.id

        // See `SignatureTemplateEditView.save()`'s identical comment on why
        // this is the closure's return value, not a captured `var` mutated
        // from inside it.
        let savedRecord = try? await environment.database.dbWriter.write { db -> MailTemplateRecord in
            var record = editedFields
            record.name = name
            record.subject = trimmedSubject.isEmpty ? nil : trimmedSubject
            record.body = bodyText
            record.accountId = scopedAccountId
            record.updatedAt = Date()
            if existingId == nil {
                let existingMaxSortOrder = try MailTemplateRecord.select(max(Column("sortOrder"))).asRequest(of: Int.self).fetchOne(db)
                record.sortOrder = (existingMaxSortOrder ?? -1) + 1
                try record.insert(db)
            } else {
                try record.update(db)
            }
            return record
        }
        // Task #186: see `SignatureTemplateEditView.save()`'s identical
        // comment.
        if let savedRecord {
            await environment.pushMailTemplateToCloud(savedRecord)
        }
        dismiss()
    }
}
