import Foundation

/// `TemplateCloudSyncEngine`'s bridge to the real GRDB `signatureTemplate`/
/// `mailTemplate` tables — `LocalAccountDirectory`'s counterpart for
/// templates (Task #186). One protocol covering both kinds (rather than two
/// parallel `LocalSignatureDirectory`/`LocalMailTemplateDirectory`
/// protocols) since the app layer's conformer (`CloudTemplateDirectory`)
/// naturally wants to be one type backed by one `AppDatabase` reference —
/// splitting it in two would just mean instantiating two nearly-identical
/// structs.
public protocol LocalTemplateDirectory: Sendable {
    func allSignatureSnapshots() async -> [CloudSignatureSnapshot]
    /// A cloud-only signature was found — insert it as a brand-new local
    /// row (GRDB assigns this device's own `id`; `syncId` is preserved from
    /// the snapshot).
    func insertSignatureFromCloud(_ snapshot: CloudSignatureSnapshot) async
    /// An existing local signature (matched by `syncId`) lost a
    /// last-writer-wins conflict — overwrite its fields from the cloud
    /// snapshot.
    func updateSignatureFromCloud(_ snapshot: CloudSignatureSnapshot) async
    /// A tombstone for a signature this device still has — delete it
    /// locally (`onDelete: .setNull` on `account.defaultSignatureId`
    /// already handles clearing any account that had it as their default,
    /// exactly like a local user-initiated deletion does).
    func deleteSignatureLocally(syncId: String) async

    func allMailTemplateSnapshots() async -> [CloudMailTemplateSnapshot]
    func insertMailTemplateFromCloud(_ snapshot: CloudMailTemplateSnapshot) async
    func updateMailTemplateFromCloud(_ snapshot: CloudMailTemplateSnapshot) async
    func deleteMailTemplateLocally(syncId: String) async
}
