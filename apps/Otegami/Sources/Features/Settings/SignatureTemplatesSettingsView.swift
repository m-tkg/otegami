import SwiftUI
import GRDB
import OtegamiStore

/// F「署名テンプレート」— Settings → 署名テンプレート. Lists every
/// `SignatureTemplateRecord`, lets the user add/edit (`SignatureTemplateEditView`,
/// a sheet) and delete (swipe). Mirrors `TemplatesSettingsView`'s shape
/// closely (same list/add/delete/sheet structure) — see
/// `SignatureTemplateRecord`'s doc comment for why signatures are a
/// separate feature/type from C8's templates rather than an extension of
/// them.
struct SignatureTemplatesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var signatures: [SignatureTemplateRecord] = []
    @State private var isAddingNew = false
    @State private var editingSignature: SignatureTemplateRecord?
    @State private var pendingDeletion: SignatureTemplateRecord?

    var body: some View {
        List {
            if signatures.isEmpty {
                Text("署名テンプレートがありません。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.signatures.emptyState")
            } else {
                ForEach(signatures) { signature in
                    signatureRow(signature)
                }
            }
            Section {
                Button {
                    isAddingNew = true
                } label: {
                    Label("署名テンプレートを追加", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.signatures.addButton")
            }
        }
        .navigationTitle("署名テンプレート")
        .task { await loadSignatures() }
        .sheet(isPresented: $isAddingNew, onDismiss: { Task { await loadSignatures() } }) {
            SignatureTemplateEditView(signature: nil)
        }
        .sheet(item: $editingSignature, onDismiss: { Task { await loadSignatures() } }) { signature in
            SignatureTemplateEditView(signature: signature)
        }
        .alert(
            "署名テンプレートを削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { signature in
            Button("削除", role: .destructive) {
                Task { await deleteSignature(signature) }
            }
            .accessibilityIdentifier("settings.signatures.confirmDeleteButton")
            Button("キャンセル", role: .cancel) {}
        } message: { signature in
            Text("「\(signature.name)」を削除します。デフォルト署名に設定しているアカウントがあれば、その設定も解除されます。")
        }
    }

    /// One row — its own `@ViewBuilder` method, not inlined in the
    /// `ForEach`, per `docs/ci.md`'s type-check-timeout precedent
    /// (`TemplatesSettingsView.templateRow(_:)`'s identical reasoning).
    @ViewBuilder
    private func signatureRow(_ signature: SignatureTemplateRecord) -> some View {
        Button {
            editingSignature = signature
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(signature.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(scopedAccountsSummary(signature))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = signature
            } label: {
                Label("削除", systemImage: "trash")
            }
            .accessibilityIdentifier("settings.signatures.row.\(signature.id ?? 0).delete")
        }
        .accessibilityIdentifier("settings.signatures.row.\(signature.id ?? 0)")
    }

    private func scopedAccountsSummary(_ signature: SignatureTemplateRecord) -> String {
        guard !signature.accountIds.isEmpty else {
            return String(localized: "使用するアカウントが選択されていません")
        }
        let names = signature.accountIds.compactMap { id in
            environment.accounts.first(where: { $0.id == id })?.displayName
        }
        return names.isEmpty ? String(localized: "使用するアカウントが選択されていません") : names.joined(separator: ", ")
    }

    private func loadSignatures() async {
        signatures = (try? await environment.database.dbWriter.read { db in
            try SignatureTemplateRecord.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
    }

    private func deleteSignature(_ signature: SignatureTemplateRecord) async {
        guard let id = signature.id else { return }
        try? await environment.database.dbWriter.write { db in
            // `onDelete: .setNull` (v24 migration) clears any account's
            // `defaultSignatureId` pointing here automatically — no manual
            // cleanup needed.
            _ = try SignatureTemplateRecord.deleteOne(db, key: id)
        }
        await loadSignatures()
    }
}
