import Foundation
import GRDB
import Testing
@testable import OtegamiStore

/// 新画面構成: 検索履歴 (v20 migration).
@Suite("SearchHistoryQuery")
struct SearchHistoryQueryTests {
    @Test("record inserts a new entry, most recent first")
    func recordInsertsNewEntries() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SearchHistoryQuery.record("from:aiko@otegami.test", db: db)
            try SearchHistoryQuery.record("budget report", db: db)
        }
        let recent = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
        #expect(recent.map(\.queryText) == ["budget report", "from:aiko@otegami.test"])
    }

    @Test("recording the same query text again moves it to the top instead of duplicating it")
    func recordingSameTextAgainBumpsItToTop() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SearchHistoryQuery.record("first", db: db)
            try SearchHistoryQuery.record("second", db: db)
            try SearchHistoryQuery.record("first", db: db)
        }
        let recent = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
        #expect(recent.map(\.queryText) == ["first", "second"])
    }

    @Test("a blank or whitespace-only query is never recorded")
    func blankQueryIsNotRecorded() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SearchHistoryQuery.record("", db: db)
            try SearchHistoryQuery.record("   ", db: db)
        }
        let recent = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
        #expect(recent.isEmpty)
    }

    @Test("delete removes one entry by id; deleteAll clears everything")
    func deleteRemovesEntries() throws {
        let database = try AppDatabase.makeInMemory()
        try database.dbWriter.write { db in
            try SearchHistoryQuery.record("keep me", db: db)
            try SearchHistoryQuery.record("remove me", db: db)
        }
        let toRemove = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
            .first { $0.queryText == "remove me" }
        try database.dbWriter.write { db in try SearchHistoryQuery.delete(id: toRemove!.id!, db: db) }
        var recent = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
        #expect(recent.map(\.queryText) == ["keep me"])

        try database.dbWriter.write { db in try SearchHistoryQuery.deleteAll(db: db) }
        recent = try database.dbWriter.read { db in try SearchHistoryQuery.recent(db: db) }
        #expect(recent.isEmpty)
    }
}
