import Foundation

/// The single JSON blob stored under `TemplateCloudSyncEngine`'s
/// `"templates.v1"` KVS key — `AccountCloudPayload`'s (`"accounts.v1"`)
/// sibling for signatures and mail templates (Task #186). Both kinds share
/// one payload/one KVS key rather than getting one each: they're the same
/// small shape (a list + a tombstone list, reconciled the same way), so a
/// second `NSUbiquitousKeyValueStore` key would only add another
/// `didChangeExternallyNotification`-triggered `reconcile()` call site for
/// no real isolation benefit — a corrupted/oversized payload for one kind
/// would need the exact same `maxPayloadBytes` guard either way.
public struct TemplateCloudPayload: Codable, Equatable, Sendable {
    public var signatures: [CloudSignatureSnapshot]
    public var signatureTombstones: [TemplateSyncTombstone]
    public var mailTemplates: [CloudMailTemplateSnapshot]
    public var mailTemplateTombstones: [TemplateSyncTombstone]

    public init(
        signatures: [CloudSignatureSnapshot] = [],
        signatureTombstones: [TemplateSyncTombstone] = [],
        mailTemplates: [CloudMailTemplateSnapshot] = [],
        mailTemplateTombstones: [TemplateSyncTombstone] = []
    ) {
        self.signatures = signatures
        self.signatureTombstones = signatureTombstones
        self.mailTemplates = mailTemplates
        self.mailTemplateTombstones = mailTemplateTombstones
    }
}
