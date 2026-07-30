import Foundation
import GRDB

/// C8 「メール作成のテンプレート機能」— a reusable snippet a `ComposerView`
/// session can insert into `subject`/`bodyText`. Managed as one flat,
/// globally-visible list (`accountId == nil`) with an *optional* per-
/// template account scope (`accountId` set) rather than a separate "each
/// account has its own template set" model — see the `v17` migration's doc
/// comment (`AppDatabase.swift`) for why this reading of "アカウントごとに
///設定できる" was chosen.
///
/// `subject` is optional (nullable): a template can be signature-style
/// (body only, appended to whatever's already been typed) or a full
/// canned message (subject + body, used to fill a blank Composer). Which
/// behavior a given template gets isn't a stored property of the template
/// itself — `ComposerView.applyTemplate(_:)` decides purely from the
/// Composer's *current* state at the moment of insertion (empty vs.
/// already-has-content), so the same template works either way depending
/// on when it's applied.
public struct MailTemplateRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "mailTemplate"

    public var id: Int64?
    public var name: String
    public var subject: String?
    public var body: String
    /// `nil` = visible from every account's Composer. Non-nil restricts
    /// this template to that one account only (`AccountRecord.id`).
    public var accountId: String?
    /// Manual ordering for the Settings list / Composer picker — new
    /// templates append to the end (`TemplatesSettingsView.addTemplate`
    /// assigns `(existing.map(\.sortOrder).max() ?? -1) + 1`), and nothing
    /// currently lets a user reorder existing ones (a documented, accepted
    /// gap — see that view's doc comment).
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Task #186 (v37 migration): mirrors `SignatureTemplateRecord.syncId`'s
    /// doc comment exactly — the cross-device-stable identity
    /// `TemplateCloudSyncEngine` reconciles mail templates on.
    public var syncId: String

    public init(
        id: Int64? = nil,
        name: String,
        subject: String? = nil,
        body: String,
        accountId: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        syncId: String = UUID().uuidString
    ) {
        self.id = id
        self.name = name
        self.subject = subject
        self.body = body
        self.accountId = accountId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncId = syncId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
