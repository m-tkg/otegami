import Foundation
import GRDB

/// F「署名テンプレート」— a distinct feature from `MailTemplateRecord` (C8):
/// a template is a whole canned message body (or subject+body) a user
/// explicitly inserts from a menu; a signature is appended to whatever's
/// already been typed and, unlike a template, can be assigned to **multiple**
/// accounts at once and have a per-account default (`AccountRecord
/// .defaultSignatureId`) that auto-applies without any explicit action.
/// Deliberately its own table/type rather than extending `MailTemplateRecord`
/// with an accounts array — the two features' shapes diverge enough
/// (single optional `accountId` vs. `[String]`, no per-account "default"
/// concept for templates) that bolting signature-only fields onto the
/// existing template row would make every template-only call site have to
/// reason about fields that don't apply to it.
public struct SignatureTemplateRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "signatureTemplate"

    public var id: Int64?
    public var name: String
    public var body: String
    /// Which accounts this signature is offered for in the Composer's
    /// "署名" picker (`ComposerView.availableSignatures`) — GRDB's
    /// Codable-record support JSON-encodes a plain `[String]` column
    /// automatically (same mechanism `OutboxMessageRecord.toAddresses`
    /// already relies on for `[EmailAddress]`), so no custom
    /// `DatabaseValueConvertible` conformance is needed here. An empty
    /// array means "not offered to any account yet" (the state right after
    /// creating a signature with no accounts checked) rather than "all
    /// accounts" — unlike `MailTemplateRecord.accountId`, there's no `nil`-
    /// means-everywhere convenience for signatures, since the whole point
    /// of this field is letting a user explicitly scope each signature.
    public var accountIds: [String]
    /// Manual ordering for the Settings list / Composer picker — mirrors
    /// `MailTemplateRecord.sortOrder`'s identical doc comment.
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Task #186 (v37 migration): the cross-device-stable identity
    /// `TemplateCloudSyncEngine` (`AccountCloudSync`) reconciles signatures
    /// on — see the v37 migration's doc comment (`AppDatabase.swift`) for
    /// why this exists separately from `id`. Generated once, here, the
    /// moment a signature is first created (either locally or via
    /// `CloudSignatureSnapshot.makeRecord()` for one arriving from another
    /// device) and never changed again for that signature's lifetime.
    public var syncId: String

    public init(
        id: Int64? = nil,
        name: String,
        body: String,
        accountIds: [String] = [],
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        syncId: String = UUID().uuidString
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.accountIds = accountIds
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncId = syncId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
