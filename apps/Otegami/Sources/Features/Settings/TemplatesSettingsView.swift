import SwiftUI
import GRDB
import OtegamiStore

/// C8 「メール作成のテンプレート機能」— Settings → テンプレート. Lists every
/// `MailTemplateRecord`, lets the user add/edit (`TemplateEditView`, a
/// sheet) and delete (swipe). Reachable from `AccountsListContent` the same
/// way "プッシュ通知"/"このアプリについて" are (a `NavigationLink` push, not a
/// second-level sheet — see that file's doc comment on why nested sheets
/// are avoided in this app).
struct TemplatesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var templates: [MailTemplateRecord] = []
    @State private var isAddingNew = false
    @State private var editingTemplate: MailTemplateRecord?
    @State private var pendingDeletion: MailTemplateRecord?

    var body: some View {
        settingsContainer
            .navigationTitle("テンプレート")
            #if os(macOS)
            // Task #155 follow-up: see `MacSettingsBackButton`'s doc
            // comment — this screen is pushed from
            // `MailComposeSettingsView`.
            .macSettingsBackButton()
            #endif
            .task { await loadTemplates() }
            .sheet(isPresented: $isAddingNew, onDismiss: { Task { await loadTemplates() } }) {
                TemplateEditView(template: nil)
            }
            .sheet(item: $editingTemplate, onDismiss: { Task { await loadTemplates() } }) { template in
                TemplateEditView(template: template)
            }
            .alert(
                "テンプレートを削除しますか？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { template in
                Button("削除", role: .destructive) {
                    Task { await deleteTemplate(template) }
                }
                .accessibilityIdentifier("settings.templates.confirmDeleteButton")
                Button("キャンセル", role: .cancel) {}
            } message: { template in
                Text("「\(template.name)」を削除します。")
            }
    }

    /// Task #155: see `MailListSettingsView`'s identical doc comment on
    /// this same property.
    @ViewBuilder
    private var settingsContainer: some View {
        #if os(macOS)
        Form {
            sections
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        #else
        List {
            sections
        }
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        if templates.isEmpty {
            Text("テンプレートがありません。")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.templates.emptyState")
        } else {
            ForEach(templates) { template in
                templateRow(template)
            }
        }
        Section {
            Button {
                isAddingNew = true
            } label: {
                Label("テンプレートを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.templates.addButton")
        }
    }

    /// One row — pulled out into its own `@ViewBuilder` method (not inlined
    /// in the `ForEach`) per `docs/ci.md`'s type-check-timeout precedent:
    /// this row already has a multi-argument `VStack`/`HStack` shape close
    /// to the ones that pattern warns about.
    @ViewBuilder
    private func templateRow(_ template: MailTemplateRecord) -> some View {
        Button {
            editingTemplate = template
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(template.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let scopedAccountName = accountName(for: template.accountId) {
                        Text(scopedAccountName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, OtegamiSpacing.xs)
                            .background(OtegamiColor.paleBase)
                    }
                }
                if let subject = template.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = template
            } label: {
                Label("削除", systemImage: "trash")
            }
            .accessibilityIdentifier("settings.templates.row.\(template.id ?? 0).delete")
        }
        .accessibilityIdentifier("settings.templates.row.\(template.id ?? 0)")
    }

    private func accountName(for accountId: String?) -> String? {
        guard let accountId else { return nil }
        return environment.accounts.first(where: { $0.id == accountId })?.displayName
    }

    private func loadTemplates() async {
        templates = (try? await environment.database.dbWriter.read { db in
            try MailTemplateRecord.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
    }

    private func deleteTemplate(_ template: MailTemplateRecord) async {
        guard let id = template.id else { return }
        try? await environment.database.dbWriter.write { db in
            _ = try MailTemplateRecord.deleteOne(db, key: id)
        }
        // Task #186: see `SignatureTemplatesSettingsView.deleteSignature(_:)`'s
        // identical comment.
        await environment.pushMailTemplateDeletionToCloud(syncId: template.syncId)
        await loadTemplates()
    }
}
