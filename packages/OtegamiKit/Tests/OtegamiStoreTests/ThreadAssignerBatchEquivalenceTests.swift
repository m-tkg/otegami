import Foundation
import GRDB
import Testing
import OtegamiCore
@testable import OtegamiStore

/// Correctness guardrail for `ThreadAssigner.assignAllUnthreaded`'s batched
/// implementation (`docs/performance.md`): generates a randomized-but-
/// reproducible set of unthreaded messages (reference chains, bridging
/// messages that merge two threads, subject-only fallback pairs, gmail
/// thread id groupings, and unrelated singletons), feeds the *identical*
/// message set into two separate databases, threads one the old way
/// (`ThreadAssigner.assignThread` looped in date order — exactly what
/// `assignAllUnthreaded` itself used to do before it was batched) and the
/// other the new way (`ThreadAssigner.assignAllUnthreaded`), and asserts
/// the two runs produce the same thread *structure*: which messages end up
/// grouped together, and each group's `messageCount`/`unreadCount`/
/// `lastMessageDate`.
///
/// Deliberately does not compare raw `ThreadRecord.id` values — those
/// depend on SQLite's autoincrement counter/insertion order, which the old
/// and new algorithms exercise differently (the old one inserts a thread
/// row the moment each message needs one; the new one inserts them all at
/// the end) and were never a documented part of either algorithm's
/// contract. What must match is the *grouping* (via each message's stable
/// `uid`, shared between both runs since both insert the same specs in the
/// same order) and the aggregates computed for each group.
@Suite("ThreadAssigner batched vs sequential equivalence")
struct ThreadAssignerBatchEquivalenceTests {
    // MARK: - Deterministic pseudo-random source

    /// A tiny xorshift64 generator — deterministic across runs/platforms
    /// (unlike `SystemRandomNumberGenerator`) so a failure is reproducible
    /// from the seed alone, and fast enough that generating a few hundred
    /// messages per seed is negligible next to the test's own DB work.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private struct MessageSpec {
        var uid: Int64
        var messageId: String
        var inReplyTo: String?
        var references: [String]
        var subject: String
        var from: [EmailAddress]
        var to: [EmailAddress]
        var date: Date
        var gmailThreadId: Int64?
    }

    /// Builds a randomized batch of `MessageSpec`s covering every path
    /// `Threader.decide` can take, sorted by `date` (the order
    /// `assignAllUnthreaded` itself processes messages in). `seed` makes
    /// generation reproducible; different seeds exercise different random
    /// cluster shapes/orderings.
    private static func generateSpecs(seed: UInt64, clusterCount: Int) -> [MessageSpec] {
        var rng = SeededGenerator(seed: seed)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let people = (0..<8).map { EmailAddress(address: "user\($0)@otegami.test") }

        var specs: [MessageSpec] = []
        var nextMessageIdCounter = 0
        func freshMessageId() -> String {
            nextMessageIdCounter += 1
            return "<gen-\(seed)-\(nextMessageIdCounter)@otegami.test>"
        }

        // Reference-chain clusters: 1-4 messages each, References-linked in
        // sequence (JWZ style: message N's References is every prior
        // message's Message-ID in the chain), a shared normalized subject
        // (later messages get a "Re: " prefix — SubjectNormalizer strips it
        // back off), and 2 alternating participants. Each cluster's own
        // start time is spread far enough apart (multiples of 30 days) that
        // no cluster accidentally falls in another's subject-fallback
        // window, so only the References chain (not subject fallback) is
        // what's expected to link a cluster's own messages together.
        var clusterLastMessageId: [Int: String] = [:]
        var clusterStartDate: [Int: Date] = [:]
        for cluster in 0..<clusterCount {
            let length = Int(rng.next() % 4) + 1
            let clusterBase = base.addingTimeInterval(Double(cluster) * 30 * 24 * 3600)
            clusterStartDate[cluster] = clusterBase
            let subject = "cluster subject \(cluster)"
            let a = people[Int(rng.next() % UInt64(people.count))]
            var b = people[Int(rng.next() % UInt64(people.count))]
            if b == a { b = people[(people.firstIndex(of: a)! + 1) % people.count] }

            var chain: [String] = []
            for step in 0..<length {
                let messageId = freshMessageId()
                let date = clusterBase.addingTimeInterval(Double(step) * 3600)
                let displaySubject = step == 0 ? subject : "Re: \(subject)"
                let (from, to) = step % 2 == 0 ? ([a], [b]) : ([b], [a])
                specs.append(MessageSpec(
                    uid: 0, messageId: messageId,
                    inReplyTo: chain.last,
                    references: chain,
                    subject: displaySubject, from: from, to: to, date: date, gmailThreadId: nil
                ))
                chain.append(messageId)
            }
            clusterLastMessageId[cluster] = chain.last
        }

        // Bridging messages: reference the *last* message of two distinct
        // earlier clusters, forcing `Threader.decide`'s `.joinAndMerge`
        // path. Dated after both clusters so it doesn't also collide with
        // any subject-fallback window.
        let bridgeCount = min(5, clusterCount / 4)
        for i in 0..<bridgeCount {
            let clusterA = Int(rng.next() % UInt64(clusterCount))
            var clusterB = Int(rng.next() % UInt64(clusterCount))
            if clusterB == clusterA { clusterB = (clusterB + 1) % clusterCount }
            guard let lastA = clusterLastMessageId[clusterA], let lastB = clusterLastMessageId[clusterB] else { continue }
            let bridgeDate = max(clusterStartDate[clusterA]!, clusterStartDate[clusterB]!).addingTimeInterval(400 * 24 * 3600 + Double(i))
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(),
                inReplyTo: nil, references: [lastA, lastB],
                subject: "Fwd: bridge \(i)", from: [people[0]], to: [people[1]],
                date: bridgeDate, gmailThreadId: nil
            ))
        }

        // Subject-only fallback pairs: no References/In-Reply-To at all,
        // same normalized subject, overlapping participants, within the
        // 7-day window.
        let subjectPairCount = max(3, clusterCount / 5)
        for i in 0..<subjectPairCount {
            let subject = "subject-fallback topic \(seed)-\(i)"
            let a = people[Int(rng.next() % UInt64(people.count))]
            var b = people[Int(rng.next() % UInt64(people.count))]
            if b == a { b = people[(people.firstIndex(of: a)! + 1) % people.count] }
            let pairBase = base.addingTimeInterval(Double(10_000 + i) * 30 * 24 * 3600)
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(), inReplyTo: nil, references: [],
                subject: subject, from: [a], to: [b], date: pairBase, gmailThreadId: nil
            ))
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(), inReplyTo: nil, references: [],
                subject: "Re: \(subject)", from: [b], to: [a],
                date: pairBase.addingTimeInterval(Double(rng.next() % (6 * 24 * 3600))), gmailThreadId: nil
            ))
        }

        // gmailThreadId-linked pairs: distinct subjects/no references, but
        // share a synthetic gmail thread id — `Threader.decide`'s highest-
        // priority path.
        let gmailPairCount = max(3, clusterCount / 5)
        for i in 0..<gmailPairCount {
            let gmailThreadId = Int64(90_000 + seed % 1000) * 1000 + Int64(i)
            let gmailBase = base.addingTimeInterval(Double(20_000 + i) * 30 * 24 * 3600)
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(), inReplyTo: nil, references: [],
                subject: "gmail thread \(i) part A", from: [people[2]], to: [people[3]],
                date: gmailBase, gmailThreadId: gmailThreadId
            ))
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(), inReplyTo: nil, references: [],
                subject: "totally different subject \(i)", from: [people[4]], to: [people[5]],
                date: gmailBase.addingTimeInterval(3600), gmailThreadId: gmailThreadId
            ))
        }

        // Unrelated singletons: unique subject, no references, no overlap
        // — guaranteed `.createNew` with no future matches either.
        let singletonCount = max(5, clusterCount / 3)
        for i in 0..<singletonCount {
            let singletonBase = base.addingTimeInterval(Double(30_000 + i) * 30 * 24 * 3600)
            specs.append(MessageSpec(
                uid: 0, messageId: freshMessageId(), inReplyTo: nil, references: [],
                subject: "singleton \(seed)-\(i)", from: [people[6]], to: [people[7]],
                date: singletonBase, gmailThreadId: nil
            ))
        }

        specs.sort { $0.date < $1.date }
        return specs.enumerated().map { index, spec in
            var copy = spec
            copy.uid = Int64(index + 1)
            return copy
        }
    }

    /// Shifts every `uid` by `offset` — for inserting a second generated
    /// batch into a mailbox that already has a first batch's `uid`s
    /// occupying `1...firstBatch.count` (`message`'s `(mailboxId, uid)`
    /// uniqueness constraint would otherwise collide, since `generateSpecs`
    /// always numbers its own output starting at 1).
    private static func offsettingUids(of specs: [MessageSpec], by offset: Int64) -> [MessageSpec] {
        specs.map { spec in
            var copy = spec
            copy.uid += offset
            return copy
        }
    }

    // MARK: - Fixture wiring

    private func makeDatabaseWithInbox() throws -> (database: AppDatabase, accountId: String, mailboxId: Int64) {
        let database = try AppDatabase.makeInMemory()
        let account = AccountRecord(
            displayName: "Test", email: "test1@otegami.test", authType: .password,
            imapHost: "localhost", imapPort: 1143, imapSecurity: .plain, imapUsername: "test1@otegami.test"
        )
        let mailboxId = try database.dbWriter.write { db -> Int64 in
            try account.insert(db)
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            try mailbox.insert(db)
            return mailbox.id!
        }
        return (database, account.id, mailboxId)
    }

    @discardableResult
    private func insertSpecs(_ specs: [MessageSpec], mailboxId: Int64, db: Database) throws -> [Int64: Int64] {
        var rowIdByUid: [Int64: Int64] = [:]
        for spec in specs {
            var message = MessageRecord(
                mailboxId: mailboxId, uid: spec.uid,
                messageId: spec.messageId, inReplyTo: spec.inReplyTo,
                subject: spec.subject, normalizedSubject: SubjectNormalizer.normalize(spec.subject),
                fromAddresses: spec.from, toAddresses: spec.to,
                date: spec.date, internalDate: spec.date,
                gmailThreadId: spec.gmailThreadId
            )
            try message.insert(db)
            let rowId = message.id!
            for (index, reference) in spec.references.enumerated() {
                var ref = MessageReferenceRecord(messageId: rowId, referenceValue: reference, position: index)
                try ref.insert(db)
            }
            rowIdByUid[spec.uid] = rowId
        }
        return rowIdByUid
    }

    /// A structural snapshot keyed by each thread's member `uid` set (stable
    /// across both runs, unlike `ThreadRecord.id`), so the old and new
    /// algorithms' results can be compared without caring which literal
    /// thread ids either one happened to assign.
    private func snapshot(_ database: AppDatabase) throws -> [Set<Int64>: (messageCount: Int, unreadCount: Int, lastMessageDate: Date?)] {
        try database.dbWriter.read { db in
            let messages = try MessageRecord.fetchAll(db)
            let threads = try ThreadRecord.fetchAll(db)
            var membersByThreadId: [Int64: Set<Int64>] = [:]
            for message in messages {
                guard let threadId = message.threadId else { continue }
                membersByThreadId[threadId, default: []].insert(message.uid)
            }
            var result: [Set<Int64>: (messageCount: Int, unreadCount: Int, lastMessageDate: Date?)] = [:]
            for thread in threads {
                guard let id = thread.id, let members = membersByThreadId[id] else { continue }
                result[members] = (thread.messageCount, thread.unreadCount, thread.lastMessageDate)
            }
            return result
        }
    }

    @Test("batched assignAllUnthreaded produces the same thread structure as the old per-message loop, across several randomized datasets", arguments: [1, 2, 3, 4, 5] as [UInt64])
    func batchedMatchesSequential(seed: UInt64) throws {
        let specs = Self.generateSpecs(seed: seed, clusterCount: 40)
        #expect(specs.count > 100)

        let (oldDatabase, oldAccountId, oldMailboxId) = try makeDatabaseWithInbox()
        let oldRowIds = try oldDatabase.dbWriter.write { db in try insertSpecs(specs, mailboxId: oldMailboxId, db: db) }
        // The old algorithm: exactly what `assignAllUnthreaded` did before
        // it was batched — `assignThread` looped in date order (`specs` is
        // already date-sorted, and `uid`s were assigned in that same order).
        try oldDatabase.dbWriter.write { db in
            for spec in specs {
                guard let rowId = oldRowIds[spec.uid] else { continue }
                _ = try ThreadAssigner.assignThread(messageId: rowId, accountId: oldAccountId, db: db)
            }
        }

        let (newDatabase, newAccountId, newMailboxId) = try makeDatabaseWithInbox()
        _ = try newDatabase.dbWriter.write { db in try insertSpecs(specs, mailboxId: newMailboxId, db: db) }
        try newDatabase.dbWriter.write { db in
            try ThreadAssigner.assignAllUnthreaded(accountId: newAccountId, db: db)
        }

        let oldSnapshot = try snapshot(oldDatabase)
        let newSnapshot = try snapshot(newDatabase)

        #expect(Set(oldSnapshot.keys) == Set(newSnapshot.keys), "seed \(seed): thread groupings (by member uid set) differ")
        for (members, oldAggregate) in oldSnapshot {
            guard let newAggregate = newSnapshot[members] else { continue }
            #expect(oldAggregate.messageCount == newAggregate.messageCount, "seed \(seed): messageCount mismatch for group \(members.sorted())")
            #expect(oldAggregate.unreadCount == newAggregate.unreadCount, "seed \(seed): unreadCount mismatch for group \(members.sorted())")
            #expect(oldAggregate.lastMessageDate == newAggregate.lastMessageDate, "seed \(seed): lastMessageDate mismatch for group \(members.sorted())")
        }

        // Every message ended up threaded exactly once in both runs, with
        // no message left behind.
        let (oldMessages, newMessages) = try (
            oldDatabase.dbWriter.read { db in try MessageRecord.fetchAll(db) },
            newDatabase.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        )
        #expect(oldMessages.allSatisfy { $0.threadId != nil })
        #expect(newMessages.allSatisfy { $0.threadId != nil })
        #expect(oldMessages.count == specs.count)
        #expect(newMessages.count == specs.count)
    }

    @Test("assignAllUnthreaded is idempotent-safe to call again with nothing left to thread (no crash, no duplicate work)")
    func rerunningAfterFullyThreadedIsANoOp() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let specs = Self.generateSpecs(seed: 7, clusterCount: 20)
        try database.dbWriter.write { db in
            _ = try insertSpecs(specs, mailboxId: mailboxId, db: db)
            try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db)
        }
        let before = try snapshot(database)
        try database.dbWriter.write { db in
            try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db)
        }
        let after = try snapshot(database)
        #expect(Set(before.keys) == Set(after.keys))
        for (members, beforeAggregate) in before {
            guard let afterAggregate = after[members] else { continue }
            #expect(beforeAggregate.messageCount == afterAggregate.messageCount)
            #expect(beforeAggregate.unreadCount == afterAggregate.unreadCount)
            #expect(beforeAggregate.lastMessageDate == afterAggregate.lastMessageDate)
        }
    }

    @Test("a mix of already-threaded and newly-unthreaded messages merges correctly in a second batched pass")
    func secondBatchMergesWithAlreadyThreadedHistory() throws {
        let (database, accountId, mailboxId) = try makeDatabaseWithInbox()
        let firstBatch = Self.generateSpecs(seed: 11, clusterCount: 15)
        try database.dbWriter.write { db in
            _ = try insertSpecs(firstBatch, mailboxId: mailboxId, db: db)
            try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db)
        }
        let afterFirst = try snapshot(database)
        #expect(!afterFirst.isEmpty)

        // A second, independently generated batch, inserted on top of the
        // now-partially-threaded account — exercises the targeted existing-
        // message preload query (`existingThreadedMatches`), not just a
        // from-scratch account.
        let secondBatch = Self.offsettingUids(of: Self.generateSpecs(seed: 12, clusterCount: 15), by: Int64(firstBatch.count))
        try database.dbWriter.write { db in
            _ = try insertSpecs(secondBatch, mailboxId: mailboxId, db: db)
            try ThreadAssigner.assignAllUnthreaded(accountId: accountId, db: db)
        }

        let messages = try database.dbWriter.read { db in try MessageRecord.fetchAll(db) }
        #expect(messages.allSatisfy { $0.threadId != nil })
        #expect(messages.count == firstBatch.count + secondBatch.count)
    }
}
