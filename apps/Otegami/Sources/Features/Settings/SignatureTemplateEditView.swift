import SwiftUI
import GRDB
import OtegamiStore

/// Add/edit sheet for one `SignatureTemplateRecord` (F) — `signature == nil`
/// means "creating a new one". Mirrors `TemplateEditView`'s overall shape
/// (plain state-in-`@State`, save-on-toolbar-button form) with one
/// structural difference: `accountSection` is a multi-select (`Set<String>`
/// of checked account ids) rather than `TemplateEditView.accountSection`'s
/// single-selection `Picker`, since a signature can be assigned to several
/// accounts at once (`SignatureTemplateRecord.accountIds`'s doc comment).
struct SignatureTemplateEditView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let signature: SignatureTemplateRecord?

    @State private var name = ""
    @State private var bodyText = ""
    @State private var selectedAccountIds: Set<String> = []
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
                bodySection
            }
            .navigationTitle(signature == nil ? "署名テンプレートを追加" : "署名テンプレートを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("signatureEdit.cancelButton")
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
                    .accessibilityIdentifier("signatureEdit.saveButton")
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
            TextField("例: 会社用の署名", text: $name)
                .accessibilityIdentifier("signatureEdit.name")
        }
    }

    private var accountSection: some View {
        Section {
            ForEach(environment.accounts) { account in
                accountToggleRow(account)
            }
        } header: {
            Text("使用するアカウント")
        } footer: {
            Text("チェックしたアカウントで作成中のメールの「署名」欄からこの署名を選べます。複数選択できます。")
        }
    }

    /// One account row — pulled into its own `@ViewBuilder` method (not
    /// inlined in the `ForEach`), same `docs/ci.md` precedent every other
    /// row-shaped view in this app follows.
    @ViewBuilder
    private func accountToggleRow(_ account: AccountRecord) -> some View {
        Button {
            toggleAccount(account.id)
        } label: {
            HStack {
                Text(account.displayName)
                    .foregroundStyle(OtegamiColor.ink)
                Spacer()
                if selectedAccountIds.contains(account.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(OtegamiColor.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("signatureEdit.accountToggle.\(account.id)")
        .accessibilityAddTraits(selectedAccountIds.contains(account.id) ? .isSelected : [])
    }

    private func toggleAccount(_ accountId: String) {
        if selectedAccountIds.contains(accountId) {
            selectedAccountIds.remove(accountId)
        } else {
            selectedAccountIds.insert(accountId)
        }
    }

    private var bodySection: some View {
        Section("本文") {
            TextEditor(text: $bodyText)
                .frame(minHeight: 160)
                .accessibilityIdentifier("signatureEdit.body")
        }
    }

    private func loadExistingIfNeeded() {
        guard let signature else { return }
        name = signature.name
        bodyText = signature.body
        selectedAccountIds = Set(signature.accountIds)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // Built fully before the `dbWriter.write` closure below — same
        // "no captured `var` inside a `@Sendable` closure" reasoning as
        // `TemplateEditView.save()`'s identical comment.
        let editedFields = signature ?? SignatureTemplateRecord(name: name, body: bodyText)
        let existingId = editedFields.id
        let accountIdsToSave = Array(selectedAccountIds)

        try? await environment.database.dbWriter.write { db in
            var record = editedFields
            record.name = name
            record.body = bodyText
            record.accountIds = accountIdsToSave
            record.updatedAt = Date()
            if existingId == nil {
                let existingMaxSortOrder = try SignatureTemplateRecord.select(max(Column("sortOrder"))).asRequest(of: Int.self).fetchOne(db)
                record.sortOrder = (existingMaxSortOrder ?? -1) + 1
                try record.insert(db)
            } else {
                try record.update(db)
            }
        }
        dismiss()
    }
}
