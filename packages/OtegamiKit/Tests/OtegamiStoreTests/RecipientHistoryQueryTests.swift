import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

@Suite("RecipientHistoryQuery")
struct RecipientHistoryQueryTests {
    private func makeAccount(_ database: AppDatabase, email: String) throws -> AccountRecord {
        let account = AccountRecord(
            displayName: "Test", email: email, authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: email
        )
        try database.dbWriter.write { db in try account.insert(db) }
        return account
    }

    private func makeInbox(_ database: AppDatabase, accountId: String) throws -> Int64 {
        try database.dbWriter.write { db in
            var mailbox = MailboxRecord(accountId: accountId, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            return mailbox.id!
        }
    }

    @Test("flattens from/to/cc into occurrences, using date or internalDate as the fallback")
    func flattensAddresses() throws {
        let database = try AppDatabase.makeInMemory()
        let account = try makeAccount(database, email: "me@otegami.test")
        let mailboxId = try makeInbox(database, accountId: account.id)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            var withDate = MessageRecord(
                mailboxId: mailboxId, uid: 1,
                fromAddresses: [EmailAddress(name: "Tanaka", address: "tanaka@example.com")],
                toAddresses: [EmailAddress(address: "me@otegami.test")],
                ccAddresses: [EmailAddress(name: "Suzuki", address: "suzuki@example.com")],
                date: base, internalDate: base.addingTimeInterval(-10)
            )
            try withDate.insert(db)
            // No `date` header (some messages never had one) — falls back
            // to internalDate.
            var noDate = MessageRecord(
                mailboxId: mailboxId, uid: 2,
                fromAddresses: [EmailAddress(name: "Sato", address: "sato@example.com")],
                internalDate: base.addingTimeInterval(100)
            )
            try noDate.insert(db)
        }

        let occurrences = try database.dbWriter.read { db in
            try RecipientHistoryQuery.occurrences(scanLimit: 100, db: db)
        }
        let addresses = Set(occurrences.map(\.address))
        #expect(addresses == ["tanaka@example.com", "me@otegami.test", "suzuki@example.com", "sato@example.com"])

        let satoOccurrence = try #require(occurrences.first { $0.address == "sato@example.com" })
        #expect(satoOccurrence.date == base.addingTimeInterval(100))
        let tanakaOccurrence = try #require(occurrences.first { $0.address == "tanaka@example.com" })
        #expect(tanakaOccurrence.date == base)
    }

    @Test("excludingAddresses drops the account's own address, case-insensitively")
    func excludesOwnAddress() throws {
        let database = try AppDatabase.makeInMemory()
        let account = try makeAccount(database, email: "Me@Otegami.test")
        let mailboxId = try makeInbox(database, accountId: account.id)

        try database.dbWriter.write { db in
            var message = MessageRecord(
                mailboxId: mailboxId, uid: 1,
                toAddresses: [EmailAddress(address: "me@otegami.test"), EmailAddress(address: "other@example.com")],
                internalDate: Date()
            )
            try message.insert(db)
        }

        let occurrences = try database.dbWriter.read { db in
            try RecipientHistoryQuery.occurrences(
                scanLimit: 100, excludingAddresses: ["me@otegami.test"], db: db
            )
        }
        #expect(occurrences.map(\.address) == ["other@example.com"])
    }

    @Test("scanLimit bounds the query to the most recent messages")
    func respectsScanLimit() throws {
        let database = try AppDatabase.makeInMemory()
        let account = try makeAccount(database, email: "me@otegami.test")
        let mailboxId = try makeInbox(database, accountId: account.id)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try database.dbWriter.write { db in
            for i in 0..<10 {
                var message = MessageRecord(
                    mailboxId: mailboxId, uid: Int64(i + 1),
                    toAddresses: [EmailAddress(address: "person\(i)@example.com")],
                    internalDate: base.addingTimeInterval(Double(i))
                )
                try message.insert(db)
            }
        }

        let occurrences = try database.dbWriter.read { db in
            try RecipientHistoryQuery.occurrences(scanLimit: 3, db: db)
        }
        // Only the 3 newest (highest `i`) messages should be scanned.
        #expect(Set(occurrences.map(\.address)) == ["person7@example.com", "person8@example.com", "person9@example.com"])
    }
}

/// Task #200 の性能要件の実測: 「メールが多い環境でも入力が引っかからない
/// ように、まず実際のデータ量で測ってから対処する」。`PerformanceTests.swift`
/// と同じ opt-in 規約 (`OTEGAMI_PERF_TEST=1`) に乗せる — 本体10万通計測とは
/// 別の専用データセット (`fromAddresses`/`toAddresses`/`ccAddresses`を実際に
/// 埋める必要があるため、既存の`PerformanceTests`のシードとは共有しない)。
///
/// ```sh
/// cd packages/OtegamiKit
/// OTEGAMI_PERF_TEST=1 swift test --filter RecipientHistoryQueryPerformanceTests
/// ```
@Suite("Performance (RecipientHistoryQuery)", .enabled(if: ProcessInfo.processInfo.environment["OTEGAMI_PERF_TEST"] == "1"))
struct RecipientHistoryQueryPerformanceTests {
    /// 「メールが多い環境」の想定規模。`PerformanceTests`の10万通ケースより
    /// 小さいのは、この計測が測りたいのは「メールボックス総数」ではなく
    /// 「`scanLimit`で切り取った窓の中身をデコード・集計する速さ」であり、
    /// スキャン件数自体は`scanLimit`で頭打ちになる設計だから (下記参照) —
    /// とはいえ「総メッセージ数が多くてもクエリのコストは変わらない」こと
    /// 自体もこのテストで確認する (`ORDER BY ... LIMIT`が全表スキャンに
    /// ならないことの実測)。
    static let totalMessageCount = 50_000
    /// 実際の相手先の多様性を模した、送受信相手の異なりの数。
    static let correspondentCount = 300

    private func makeFileBackedDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("otegami-recipient-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("otegami-recipient-perf.sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let database = try AppDatabase(pool)
        return (database, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test("seed 50k messages with realistic address diversity, measure occurrences() + suggestions()")
    func measureRecipientHistoryQuery() async throws {
        let (database, cleanup) = try makeFileBackedDatabase()
        defer { cleanup() }

        let ownEmail = "me@otegami.test"
        let account = AccountRecord(
            displayName: "Me", email: ownEmail, authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: ownEmail
        )
        let mailboxId = try await database.dbWriter.write { db -> Int64 in
            try account.insert(db)
            var inbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try inbox.insert(db)
            return inbox.id!
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let seedStart = CFAbsoluteTimeGetCurrent()
        try await database.dbWriter.write { db in
            for i in 0..<Self.totalMessageCount {
                let correspondentIndex = i % Self.correspondentCount
                let correspondent = EmailAddress(
                    name: "Correspondent \(correspondentIndex)",
                    address: "correspondent\(correspondentIndex)@example.com"
                )
                let date = base.addingTimeInterval(Double(i))
                var message = MessageRecord(
                    mailboxId: mailboxId, uid: Int64(i + 1),
                    fromAddresses: [correspondent],
                    // Every real inbox message carries the receiving
                    // account's own address in `to` — included here so
                    // the `excludingAddresses` cost is measured too, not
                    // just the happy-path decode.
                    toAddresses: [EmailAddress(address: ownEmail)],
                    ccAddresses: i % 5 == 0 ? [EmailAddress(name: "CC Person", address: "cc\(i % 50)@example.com")] : [],
                    date: date, internalDate: date
                )
                try message.insert(db)
            }
        }
        let seedElapsed = (CFAbsoluteTimeGetCurrent() - seedStart) * 1000
        print("[perf] seed \(Self.totalMessageCount) messages with addresses: \(String(format: "%.1f", seedElapsed))ms")

        // Checkpoint 1: the proposed default scan window
        // (`RecipientSuggestionSource.defaultScanLimit`, 3000) — covers a
        // substantial recency window regardless of total mailbox size.
        for scanLimit in [1000, 3000, 10_000] {
            let start = CFAbsoluteTimeGetCurrent()
            let occurrences = try await database.dbWriter.read { db in
                try RecipientHistoryQuery.occurrences(scanLimit: scanLimit, excludingAddresses: [ownEmail], db: db)
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[perf] RecipientHistoryQuery.occurrences(scanLimit: \(scanLimit)): \(String(format: "%.1f", elapsed))ms (\(occurrences.count) occurrences)")
            if scanLimit == 3000 {
                #expect(elapsed < 200, "scanLimit=3000 occurrences() took \(elapsed)ms, expected comfortably under 200ms")

                // Checkpoint 2: feed the result into the pure ranking
                // engine, as the composer does on every keystroke —
                // confirms the two costs together (DB decode once per
                // compose session + engine per keystroke) both stay cheap.
                let engineStart = CFAbsoluteTimeGetCurrent()
                let suggestions = RecipientSuggestionEngine.suggestions(for: "correspondent1", occurrences: occurrences)
                let engineElapsed = (CFAbsoluteTimeGetCurrent() - engineStart) * 1000
                print("[perf] RecipientSuggestionEngine.suggestions() over \(occurrences.count) occurrences: \(String(format: "%.3f", engineElapsed))ms (\(suggestions.count) results)")
                #expect(engineElapsed < 50, "engine call took \(engineElapsed)ms, expected comfortably under 50ms")
            }
        }
    }
}
