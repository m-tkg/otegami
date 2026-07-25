import Foundation

/// Pure, in-memory bulk-threading engine backing `OtegamiStore
/// .ThreadAssigner.assignAllUnthreaded`'s batched implementation
/// (`docs/performance.md`: the original per-message loop cost ~7-8 SQL
/// statements per message — several read queries per `Threader.decide`
/// call plus a `recomputeAggregates` that re-fetched a thread's full
/// membership after every single join — which made a 20k-message backfill
/// take ~14 seconds).
///
/// `plan(...)` computes the *entire* batch's final thread assignments in
/// memory, calling `Threader.decide` exactly once per message in the same
/// date order the old per-message loop did — same inputs in the same
/// sequence, so the same decisions come out — but keeps the "context that
/// grows as more messages are folded in" (see `Threader`'s doc comment)
/// as in-memory dictionaries plus a union-find over thread ids instead of
/// re-querying the database after every message. `OtegamiStore
/// .ThreadAssigner` then applies the resulting `Plan` to the database in a
/// handful of bulk statements instead of thousands of small ones.
///
/// Stays dependency-free and Linux-portable (no GRDB, no Foundation beyond
/// `Date`), matching `Threader`'s own placement in this module.
public enum BatchThreader {
    /// One already-threaded message, as needed to seed the in-memory
    /// context before folding in the unthreaded batch. Callers only need to
    /// supply messages that could plausibly be matched by *some* message in
    /// the unthreaded batch (same `messageId`/`inReplyTo`/`references`
    /// token, same `gmailThreadId`, or same `normalizedSubject`) — see
    /// `OtegamiStore.ThreadAssigner`'s targeted preload query, which is why
    /// this isn't "every already-threaded message in the account."
    public struct ExistingMessage: Sendable {
        public var threadId: Int64
        public var messageId: String?
        public var gmailThreadId: Int64?
        public var normalizedSubject: String?
        public var participants: Set<String>
        public var date: Date

        public init(
            threadId: Int64,
            messageId: String?,
            gmailThreadId: Int64?,
            normalizedSubject: String?,
            participants: Set<String>,
            date: Date
        ) {
            self.threadId = threadId
            self.messageId = messageId
            self.gmailThreadId = gmailThreadId
            self.normalizedSubject = normalizedSubject
            self.participants = participants
            self.date = date
        }
    }

    /// Where one message (existing-thread-relative) or a newly created
    /// thread group ends up, in a form `OtegamiStore.ThreadAssigner` can
    /// resolve to a real `ThreadRecord.id` without this module needing to
    /// know anything about the database (new threads don't have a real id
    /// yet at `plan(...)` time — they're only inserted afterward).
    public enum ThreadTarget: Sendable, Equatable, Hashable {
        /// An already-existing thread (its real `ThreadRecord.id`), either
        /// one supplied via `existingMessages` or one created earlier in
        /// *this* batch that's since been superseded — no, `.existing` is
        /// only ever a pre-batch id; a batch-local new thread is always
        /// `.new` even after surviving to the end. See `newThreadSubjects`.
        case existing(Int64)
        /// A thread created during this batch — `index` into
        /// `Plan.newThreadSubjects`, in creation order among the new
        /// threads that survived to the end of the batch (one that was
        /// itself later merged into something else never appears here).
        case new(Int)
    }

    public struct Plan: Sendable, Equatable {
        /// `Threader.MessageFacts.id` (the unthreaded message's row id) →
        /// its final thread.
        public var assignments: [Int64: ThreadTarget]
        /// `normalizedSubject` to seed each surviving new `ThreadRecord`
        /// with (mirrors the original per-message `ThreadAssigner
        /// .assignThread`'s `.createNew` case, which sets `thread
        /// .normalizedSubject` once at creation and never touches it
        /// again) — index-addressed, in creation order.
        public var newThreadSubjects: [String?]
        /// An existing thread id that got merged away during this batch →
        /// the target it was merged into. `OtegamiStore.ThreadAssigner`
        /// uses this to reparent that thread's *pre-existing* member
        /// messages (rows this batch never touched directly) and delete
        /// the now-empty `ThreadRecord`. A thread created during this
        /// batch that gets merged away doesn't appear here at all — it was
        /// never inserted, so there's nothing to reparent or delete.
        public var reparentedThreadIds: [Int64: ThreadTarget]

        public init(
            assignments: [Int64: ThreadTarget] = [:],
            newThreadSubjects: [String?] = [],
            reparentedThreadIds: [Int64: ThreadTarget] = [:]
        ) {
            self.assignments = assignments
            self.newThreadSubjects = newThreadSubjects
            self.reparentedThreadIds = reparentedThreadIds
        }
    }

    /// Union-find over thread ids. Existing thread ids (from
    /// `existingMessages`/`existingThreadMessageCounts`) are always
    /// `<= maxExistingThreadId`; batch-local new threads are assigned
    /// synthetic ids starting at `maxExistingThreadId + 1` and counting
    /// up — *larger*, never smaller, than every existing id, so `Threader
    /// .decide`'s merge tie-break ("largest message count; ties broken by
    /// the lowest thread id") keeps favoring an older pre-existing thread
    /// over a thread this very batch just created, exactly as it would if
    /// the new thread's id had actually been assigned by the database's
    /// autoincrement counter (which only ever grows).
    private final class UnionFind {
        private var parent: [Int64: Int64] = [:]

        func find(_ id: Int64) -> Int64 {
            var root = id
            while let next = parent[root] {
                root = next
            }
            var current = id
            while current != root {
                let next = parent[current]!
                parent[current] = root
                current = next
            }
            return root
        }

        /// `loser`'s tree is grafted onto `target`'s — both must already be
        /// roots (callers only ever union freshly `find`-resolved ids).
        /// `target` always survives; that's not a generic union-by-rank
        /// choice, it's required to match `Threader.decide`'s
        /// `.joinAndMerge(threadId: target, ...)` contract (the caller
        /// picked `target` deliberately — the largest/oldest of the
        /// matched threads).
        func union(_ loser: Int64, into target: Int64) {
            guard loser != target else { return }
            parent[loser] = target
        }
    }

    public static func plan(
        unthreadedMessages: [Threader.MessageFacts],
        existingMessages: [ExistingMessage],
        existingThreadMessageCounts: [Int64: Int],
        maxExistingThreadId: Int64,
        subjectFallbackWindow: TimeInterval = Threader.defaultSubjectFallbackWindow
    ) -> Plan {
        let unionFind = UnionFind()
        var messageCounts = existingThreadMessageCounts

        var messageIdIndex: [String: Int64] = [:]
        var gmailThreadIdIndex: [Int64: Int64] = [:]
        // subjectIndex[subject][threadId] — one *combined* candidate per
        // (subject, thread), participants unioned and date maxed across
        // every message contributing to it. This has to stay combined
        // (rather than one entry per contributing message) because
        // `Threader.decide`'s subject-fallback check ties the *thread's*
        // most recent date to the window check independently of which
        // member has overlapping participants — splitting it into several
        // separate per-message candidates for the same thread would make
        // some (date, participants) pairings the original single-query
        // `ThreadAssigner.buildContext` never produced.
        var subjectIndex: [String: [Int64: (participants: Set<String>, date: Date)]] = [:]
        var threadIdToSubjects: [Int64: Set<String>] = [:]

        for existing in existingMessages {
            let threadId = existing.threadId
            if let messageId = existing.messageId {
                messageIdIndex[messageId] = threadId
            }
            if let gmailThreadId = existing.gmailThreadId {
                gmailThreadIdIndex[gmailThreadId] = threadId
            }
            if let subject = existing.normalizedSubject, !subject.isEmpty {
                mergeSubjectCandidate(
                    subject: subject, threadId: threadId,
                    participants: existing.participants, date: existing.date,
                    into: &subjectIndex, threadIdToSubjects: &threadIdToSubjects
                )
            }
        }

        var nextVirtualId = maxExistingThreadId + 1
        var newThreadSubjectsByVirtualId: [Int64: String?] = [:]
        var virtualCreationOrder: [Int64] = []
        var rawAssignments: [Int64: Int64] = [:]
        // Existing thread ids ever used as a `.joinAndMerge` loser — the
        // only ones that might need a real reparent/delete in the DB.
        var everMergedExistingLosers: Set<Int64> = []

        for facts in unthreadedMessages {
            var referencedIds = facts.references
            if let inReplyTo = facts.inReplyTo, !referencedIds.contains(inReplyTo) {
                referencedIds.append(inReplyTo)
            }

            var threadIdByMessageId: [String: Int64] = [:]
            var threadMessageCountsSlice: [Int64: Int] = [:]
            for reference in referencedIds {
                guard let raw = messageIdIndex[reference] else { continue }
                let root = unionFind.find(raw)
                threadIdByMessageId[reference] = root
                threadMessageCountsSlice[root] = messageCounts[root] ?? 0
            }

            var threadIdByGmailThreadId: [Int64: Int64] = [:]
            if let gmailThreadId = facts.gmailThreadId, let raw = gmailThreadIdIndex[gmailThreadId] {
                let root = unionFind.find(raw)
                threadIdByGmailThreadId[gmailThreadId] = root
                threadMessageCountsSlice[root] = messageCounts[root] ?? 0
            }

            var subjectCandidatesByNormalizedSubject: [String: [Threader.SubjectCandidate]] = [:]
            if let subject = facts.normalizedSubject, !subject.isEmpty, let bucket = subjectIndex[subject] {
                var candidates: [Threader.SubjectCandidate] = []
                candidates.reserveCapacity(bucket.count)
                for (rawId, aggregate) in bucket {
                    let root = unionFind.find(rawId)
                    candidates.append(Threader.SubjectCandidate(threadId: root, participants: aggregate.participants, date: aggregate.date))
                    threadMessageCountsSlice[root] = messageCounts[root] ?? 0
                }
                subjectCandidatesByNormalizedSubject[subject] = candidates
            }

            let context = Threader.ExistingThreadContext(
                threadIdByMessageId: threadIdByMessageId,
                threadIdByGmailThreadId: threadIdByGmailThreadId,
                threadMessageCounts: threadMessageCountsSlice,
                subjectCandidatesByNormalizedSubject: subjectCandidatesByNormalizedSubject
            )
            let decision = Threader.decide(for: facts, context: context, subjectFallbackWindow: subjectFallbackWindow)

            let resultThreadId: Int64
            switch decision {
            case .join(let threadId):
                resultThreadId = threadId
                messageCounts[threadId, default: 0] += 1

            case .joinAndMerge(let threadId, let mergedThreadIds):
                for loser in mergedThreadIds where loser != threadId {
                    let countLoser = messageCounts[loser] ?? 0
                    unionFind.union(loser, into: threadId)
                    messageCounts[threadId, default: 0] += countLoser
                    messageCounts.removeValue(forKey: loser)
                    if loser <= maxExistingThreadId {
                        everMergedExistingLosers.insert(loser)
                    }
                    for subject in threadIdToSubjects[loser] ?? [] {
                        if let losing = subjectIndex[subject]?[loser] {
                            mergeSubjectCandidate(
                                subject: subject, threadId: threadId,
                                participants: losing.participants, date: losing.date,
                                into: &subjectIndex, threadIdToSubjects: &threadIdToSubjects
                            )
                            subjectIndex[subject]?.removeValue(forKey: loser)
                        }
                    }
                    threadIdToSubjects.removeValue(forKey: loser)
                }
                resultThreadId = threadId
                messageCounts[threadId, default: 0] += 1

            case .createNew:
                let virtualId = nextVirtualId
                nextVirtualId += 1
                messageCounts[virtualId] = 1
                newThreadSubjectsByVirtualId[virtualId] = facts.normalizedSubject
                virtualCreationOrder.append(virtualId)
                resultThreadId = virtualId
            }

            if let messageId = facts.messageId {
                messageIdIndex[messageId] = resultThreadId
            }
            if let gmailThreadId = facts.gmailThreadId {
                gmailThreadIdIndex[gmailThreadId] = resultThreadId
            }
            if let subject = facts.normalizedSubject, !subject.isEmpty {
                mergeSubjectCandidate(
                    subject: subject, threadId: resultThreadId,
                    participants: facts.participants, date: facts.date,
                    into: &subjectIndex, threadIdToSubjects: &threadIdToSubjects
                )
            }

            rawAssignments[facts.id] = resultThreadId
        }

        // Only new threads still their own root survived to the end —
        // one merged into something else (existing or another new thread)
        // never gets a real `ThreadRecord` row of its own.
        var indexByVirtualId: [Int64: Int] = [:]
        var newThreadSubjects: [String?] = []
        for virtualId in virtualCreationOrder where unionFind.find(virtualId) == virtualId {
            indexByVirtualId[virtualId] = newThreadSubjects.count
            newThreadSubjects.append(newThreadSubjectsByVirtualId[virtualId] ?? nil)
        }

        func target(for root: Int64) -> ThreadTarget {
            if root > maxExistingThreadId {
                // Every virtual id that's still a root at the end must have
                // survived (by definition of "root"), so it's always found.
                return .new(indexByVirtualId[root]!)
            }
            return .existing(root)
        }

        var assignments: [Int64: ThreadTarget] = [:]
        assignments.reserveCapacity(rawAssignments.count)
        for (messageFactsId, raw) in rawAssignments {
            assignments[messageFactsId] = target(for: unionFind.find(raw))
        }

        var reparentedThreadIds: [Int64: ThreadTarget] = [:]
        for loser in everMergedExistingLosers {
            let root = unionFind.find(loser)
            guard root != loser else { continue }
            reparentedThreadIds[loser] = target(for: root)
        }

        return Plan(assignments: assignments, newThreadSubjects: newThreadSubjects, reparentedThreadIds: reparentedThreadIds)
    }

    private static func mergeSubjectCandidate(
        subject: String,
        threadId: Int64,
        participants: Set<String>,
        date: Date,
        into subjectIndex: inout [String: [Int64: (participants: Set<String>, date: Date)]],
        threadIdToSubjects: inout [Int64: Set<String>]
    ) {
        var bucket = subjectIndex[subject] ?? [:]
        if var existing = bucket[threadId] {
            existing.participants.formUnion(participants)
            existing.date = max(existing.date, date)
            bucket[threadId] = existing
        } else {
            bucket[threadId] = (participants, date)
        }
        subjectIndex[subject] = bucket
        threadIdToSubjects[threadId, default: []].insert(subject)
    }
}
