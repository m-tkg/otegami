import Foundation
import OtegamiStore

/// Task #186 (iCloud で設定全般を同期): the non-local slice of
/// `OtegamiStore.SignatureTemplateRecord` that travels through
/// `TemplateCloudSyncEngine`'s `"templates.v1"` iCloud KVS payload —
/// `CloudAccountSnapshot`'s counterpart for signatures. Deliberately
/// excludes `id` (a device-local `AUTOINCREMENT` value — see the v37
/// migration's doc comment in `AppDatabase.swift` for why `syncId`, not
/// `id`, is this type's identity).
public struct CloudSignatureSnapshot: Codable, Equatable, Sendable {
    public var syncId: String
    public var name: String
    public var body: String
    public var accountIds: [String]
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        syncId: String,
        name: String,
        body: String,
        accountIds: [String],
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.syncId = syncId
        self.name = name
        self.body = body
        self.accountIds = accountIds
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Captures every synced field of `record` as it stands right now —
    /// mirrors `CloudAccountSnapshot.init(account:)`'s role exactly.
    public init(record: SignatureTemplateRecord) {
        self.init(
            syncId: record.syncId,
            name: record.name,
            body: record.body,
            accountIds: record.accountIds,
            sortOrder: record.sortOrder,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    /// Builds a brand-new `SignatureTemplateRecord` for a cloud-discovered
    /// signature that doesn't exist locally yet (`id: nil`, so GRDB assigns
    /// this device's own fresh row number on insert — only `syncId` needs
    /// to match across devices).
    public func makeRecord() -> SignatureTemplateRecord {
        SignatureTemplateRecord(
            name: name,
            body: body,
            accountIds: accountIds,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncId: syncId
        )
    }

    /// Overwrites every synced field of an *existing* local record with
    /// this (newer, per last-writer-wins) cloud snapshot. Leaves `id` (the
    /// local merge key) untouched.
    public func apply(to record: inout SignatureTemplateRecord) {
        record.name = name
        record.body = body
        record.accountIds = accountIds
        record.sortOrder = sortOrder
        record.createdAt = createdAt
        record.updatedAt = updatedAt
    }
}

extension CloudSignatureSnapshot: TemplateSyncSnapshot {
    /// A same-content identity used only to dedupe a genuinely brand-new
    /// cloud entry against one this device already created independently
    /// (two devices both making "a signature called 削除済み with this
    /// exact body" before either had synced) — mirrors `CloudAccountSnapshot
    /// .identityKey`'s reasoning and the duplicate-insertion bug it guards
    /// against (`docs/icloud-sync.md`'s「重複挿入バグ」). Deliberately
    /// excludes `accountIds`/`sortOrder` — a user reordering or rescoping a
    /// signature on one device before the other has synced shouldn't be
    /// read as "these are two different signatures".
    public var identityKey: String { "\(name.lowercased())\u{0}\(body)" }
}

/// Task #186: `CloudSignatureSnapshot`'s counterpart for
/// `OtegamiStore.MailTemplateRecord` (C8 の作成テンプレート) — same
/// reasoning throughout, see that type's doc comments.
public struct CloudMailTemplateSnapshot: Codable, Equatable, Sendable {
    public var syncId: String
    public var name: String
    public var subject: String?
    public var body: String
    public var accountId: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        syncId: String,
        name: String,
        subject: String?,
        body: String,
        accountId: String?,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.syncId = syncId
        self.name = name
        self.subject = subject
        self.body = body
        self.accountId = accountId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(record: MailTemplateRecord) {
        self.init(
            syncId: record.syncId,
            name: record.name,
            subject: record.subject,
            body: record.body,
            accountId: record.accountId,
            sortOrder: record.sortOrder,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    public func makeRecord() -> MailTemplateRecord {
        MailTemplateRecord(
            name: name,
            subject: subject,
            body: body,
            accountId: accountId,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            syncId: syncId
        )
    }

    public func apply(to record: inout MailTemplateRecord) {
        record.name = name
        record.subject = subject
        record.body = body
        record.accountId = accountId
        record.sortOrder = sortOrder
        record.createdAt = createdAt
        record.updatedAt = updatedAt
    }
}

extension CloudMailTemplateSnapshot: TemplateSyncSnapshot {
    public var identityKey: String { "\(name.lowercased())\u{0}\(subject?.lowercased() ?? "")\u{0}\(body)" }
}

/// One synced signature/mail-template's deletion record — `AccountTombstone`'s
/// counterpart, keyed on `syncId` instead of `accountId`.
public struct TemplateSyncTombstone: Codable, Equatable, Sendable {
    public var syncId: String
    public var deletedAt: Date

    public init(syncId: String, deletedAt: Date) {
        self.syncId = syncId
        self.deletedAt = deletedAt
    }
}
