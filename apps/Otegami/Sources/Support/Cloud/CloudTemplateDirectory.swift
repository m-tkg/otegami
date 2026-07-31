import AccountCloudSync
import Foundation
import GRDB
import OtegamiStore

/// The app's `LocalTemplateDirectory` conformance — `CloudAccountDirectory`'s
/// counterpart for `TemplateCloudSyncEngine` (Task #186). Much smaller than
/// `CloudAccountDirectory`: no Keychain, no `SyncCoordinator`, no push-watch
/// registration — a signature/mail template is inert data with nothing to
/// start/stop syncing once it exists locally, so every method here is a
/// plain GRDB read/insert/update/delete.
struct CloudTemplateDirectory: LocalTemplateDirectory, @unchecked Sendable {
    let database: AppDatabase

    func allSignatureSnapshots() async -> [CloudSignatureSnapshot] {
        let records = (try? await database.dbWriter.read { db in try SignatureTemplateRecord.fetchAll(db) }) ?? []
        return records.map(CloudSignatureSnapshot.init(record:))
    }

    func insertSignatureFromCloud(_ snapshot: CloudSignatureSnapshot) async {
        try? await database.dbWriter.write { db in
            var record = snapshot.makeRecord()
            try record.insert(db)
        }
    }

    func updateSignatureFromCloud(_ snapshot: CloudSignatureSnapshot) async {
        try? await database.dbWriter.write { db in
            guard var record = try SignatureTemplateRecord.filter(Column("syncId") == snapshot.syncId).fetchOne(db) else { return }
            snapshot.apply(to: &record)
            try record.update(db)
        }
    }

    func deleteSignatureLocally(syncId: String) async {
        try? await database.dbWriter.write { db in
            _ = try SignatureTemplateRecord.filter(Column("syncId") == syncId).deleteAll(db)
        }
    }

    func allMailTemplateSnapshots() async -> [CloudMailTemplateSnapshot] {
        let records = (try? await database.dbWriter.read { db in try MailTemplateRecord.fetchAll(db) }) ?? []
        return records.map(CloudMailTemplateSnapshot.init(record:))
    }

    func insertMailTemplateFromCloud(_ snapshot: CloudMailTemplateSnapshot) async {
        try? await database.dbWriter.write { db in
            var record = snapshot.makeRecord()
            try record.insert(db)
        }
    }

    func updateMailTemplateFromCloud(_ snapshot: CloudMailTemplateSnapshot) async {
        try? await database.dbWriter.write { db in
            guard var record = try MailTemplateRecord.filter(Column("syncId") == snapshot.syncId).fetchOne(db) else { return }
            snapshot.apply(to: &record)
            try record.update(db)
        }
    }

    func deleteMailTemplateLocally(syncId: String) async {
        try? await database.dbWriter.write { db in
            _ = try MailTemplateRecord.filter(Column("syncId") == syncId).deleteAll(db)
        }
    }
}
