import Foundation
import GRDB
import Testing
@testable import OtegamiStore

/// 検索画面再構成 (Task #86): 検索画面の「保存済み」タブ (v29 migration).
@Suite("SavedSearchQuery")
struct SavedSearchQueryTests {
    @Test("toggle saves a new query+filter+account combination")
    func toggleSavesNewEntry() throws {
        let database = try AppDatabase.makeInMemory()
        let nowSaved = try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "budget report", filter: "unread", accountId: "acct-1", db: db)
        }
        #expect(nowSaved)
        let recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.map(\.queryText) == ["budget report"])
        #expect(recent.first?.filter == "unread")
        #expect(recent.first?.accountId == "acct-1")
    }

    @Test("toggling an already-saved combination removes it instead of duplicating it")
    func togglingAgainRemovesEntry() throws {
        let database = try AppDatabase.makeInMemory()
        _ = try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "invoice", filter: "all", accountId: nil, db: db)
        }
        let nowSaved = try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "invoice", filter: "all", accountId: nil, db: db)
        }
        #expect(!nowSaved)
        let recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.isEmpty)
    }

    @Test("the same query text under a different filter or account is a distinct saved entry")
    func sameQueryTextDifferentFilterOrAccountAreDistinct() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "invoice", filter: "all", accountId: nil, db: db)
            try SavedSearchQuery.toggle(queryText: "invoice", filter: "unread", accountId: nil, db: db)
            try SavedSearchQuery.toggle(queryText: "invoice", filter: "all", accountId: "acct-2", db: db)
        }
        let recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.count == 3)
    }

    @Test("a blank or whitespace-only query is never saved")
    func blankQueryIsNotSaved() throws {
        let database = try AppDatabase.makeInMemory()
        let nowSaved = try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "   ", filter: "all", accountId: nil, db: db)
        }
        #expect(!nowSaved)
        let recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.isEmpty)
    }

    @Test("delete removes one entry by id")
    func deleteRemovesEntry() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "keep me", filter: "all", accountId: nil, db: db)
            try SavedSearchQuery.toggle(queryText: "remove me", filter: "all", accountId: nil, db: db)
        }
        let toRemove = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
            .first { $0.queryText == "remove me" }
        try database.dbWriter.write { db in try SavedSearchQuery.delete(id: toRemove!.id!, db: db) }
        let recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.map(\.queryText) == ["keep me"])
    }

    @Test("saving beyond maxEntries evicts the oldest saved entry")
    func savingBeyondMaxEntriesEvictsOldest() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            for index in 0..<SavedSearchQuery.maxEntries {
                try SavedSearchQuery.toggle(queryText: "query \(index)", filter: "all", accountId: nil, db: db)
            }
        }
        var recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.count == SavedSearchQuery.maxEntries)
        #expect(recent.contains { $0.queryText == "query 0" })

        _ = try database.dbWriter.write { db in
            try SavedSearchQuery.toggle(queryText: "one more", filter: "all", accountId: nil, db: db)
        }
        recent = try database.dbWriter.read { db in try SavedSearchQuery.recent(db: db) }
        #expect(recent.count == SavedSearchQuery.maxEntries)
        #expect(!recent.contains { $0.queryText == "query 0" }, "expected the oldest saved entry to be evicted once the cap was exceeded")
        #expect(recent.contains { $0.queryText == "one more" })
    }
}
