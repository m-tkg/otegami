import Foundation

/// Pure conversation-threading logic (M4 plan §スレッディング). Decides which
/// existing thread (if any) a single message belongs to, given a small,
/// already-narrowed slice of "what's already known" handed in by the DB
/// layer (`OtegamiStore.ThreadAssigner`) — this type never touches GRDB or
/// any store directly, so it stays Linux-compatible and unit-testable
/// without a database.
///
/// Priority order (plan): (1) Gmail's `X-GM-THRID`, when present, always
/// wins. (2) References/In-Reply-To/Message-ID: if the message points at
/// one or more already-threaded messages, join that thread (or, if it
/// bridges two previously-separate threads, merge them). (3) Fallback: same
/// normalized subject, overlapping participants, within a time window.
/// (4) Otherwise, start a new thread.
///
/// The same `decide(for:context:)` entry point serves both incremental
/// application (one new message synced, `ThreadAssigner.assignThread`
/// builds a narrow `ExistingThreadContext` from the database) and bulk
/// computation (`ThreadAssigner.assignAllUnthreaded` folds messages in one
/// account over date order, feeding each decision's outcome into the next
/// call's context) — there's no separate "batch mode" here, just repeated
/// single-message decisions against a context that grows as more messages
/// are folded in.
public enum Threader {
    /// One message's threading-relevant facts, already extracted from
    /// whatever store-specific record holds them.
    public struct MessageFacts: Sendable, Equatable {
        public var id: Int64
        public var messageId: String?
        public var inReplyTo: String?
        /// `References` header tokens, oldest first (order doesn't matter
        /// to `decide` itself, only that every token is present).
        public var references: [String]
        /// Already reply/forward-prefix-stripped (see `SubjectNormalizer`).
        public var normalizedSubject: String?
        /// Lowercased participant addresses (from + to + cc), for the
        /// subject-fallback overlap check.
        public var participants: Set<String>
        /// The message's best-known date (`date ?? internalDate`).
        public var date: Date
        /// Gmail's `X-GM-THRID`, when known (bit-pattern `Int64`, matching
        /// `OtegamiStore.MessageRecord.gmailThreadId`).
        public var gmailThreadId: Int64?

        public init(
            id: Int64,
            messageId: String?,
            inReplyTo: String?,
            references: [String],
            normalizedSubject: String?,
            participants: Set<String>,
            date: Date,
            gmailThreadId: Int64? = nil
        ) {
            self.id = id
            self.messageId = messageId
            self.inReplyTo = inReplyTo
            self.references = references
            self.normalizedSubject = normalizedSubject
            self.participants = participants
            self.date = date
            self.gmailThreadId = gmailThreadId
        }
    }

    /// A previously-threaded message this decision might match against,
    /// for the subject-fallback pass (step 3). One entry per already-seen
    /// message sharing the candidate message's `normalizedSubject`.
    public struct SubjectCandidate: Sendable, Equatable {
        public var threadId: Int64
        public var participants: Set<String>
        public var date: Date

        public init(threadId: Int64, participants: Set<String>, date: Date) {
            self.threadId = threadId
            self.participants = participants
            self.date = date
        }
    }

    /// Everything already known that a threading decision for one message
    /// might need to consult. The DB layer narrows each field to just what
    /// the candidate message could plausibly reference — e.g.
    /// `threadIdByMessageId` only needs entries for the message's own
    /// `references`/`inReplyTo` tokens, not the whole account.
    public struct ExistingThreadContext: Sendable, Equatable {
        /// `Message-ID` token → the thread that message already belongs to.
        public var threadIdByMessageId: [String: Int64]
        /// Gmail thread id → the local thread already assigned to another
        /// message sharing it.
        public var threadIdByGmailThreadId: [Int64: Int64]
        /// How many messages each candidate thread already has — used to
        /// decide which side of a merge is "smaller" (plan: "小さい方を付け替
        /// え").
        public var threadMessageCounts: [Int64: Int]
        /// Subject-fallback candidates, keyed by normalized subject.
        public var subjectCandidatesByNormalizedSubject: [String: [SubjectCandidate]]

        public init(
            threadIdByMessageId: [String: Int64] = [:],
            threadIdByGmailThreadId: [Int64: Int64] = [:],
            threadMessageCounts: [Int64: Int] = [:],
            subjectCandidatesByNormalizedSubject: [String: [SubjectCandidate]] = [:]
        ) {
            self.threadIdByMessageId = threadIdByMessageId
            self.threadIdByGmailThreadId = threadIdByGmailThreadId
            self.threadMessageCounts = threadMessageCounts
            self.subjectCandidatesByNormalizedSubject = subjectCandidatesByNormalizedSubject
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Join an existing thread as-is.
        case join(threadId: Int64)
        /// Join `threadId`, and reparent every message currently in
        /// `mergedThreadIds` onto it too — this message's References
        /// header bridges two threads that were previously separate.
        case joinAndMerge(threadId: Int64, mergedThreadIds: Set<Int64>)
        /// No existing thread matched; start a new one.
        case createNew
    }

    /// Default subject-fallback window (plan: "7 日以内").
    public static let defaultSubjectFallbackWindow: TimeInterval = 7 * 24 * 60 * 60

    public static func decide(
        for message: MessageFacts,
        context: ExistingThreadContext,
        subjectFallbackWindow: TimeInterval = defaultSubjectFallbackWindow
    ) -> Decision {
        // 1. Gmail X-GM-THRID always wins when it resolves to a known thread.
        if let gmailThreadId = message.gmailThreadId,
           let threadId = context.threadIdByGmailThreadId[gmailThreadId] {
            return .join(threadId: threadId)
        }

        // 2. References / In-Reply-To / Message-ID union-find, one step at
        // a time: collect every distinct thread any referenced message
        // already belongs to.
        var referencedIds = message.references
        if let inReplyTo = message.inReplyTo, !referencedIds.contains(inReplyTo) {
            referencedIds.append(inReplyTo)
        }
        var matchedThreadIds: [Int64] = []
        var seen = Set<Int64>()
        for reference in referencedIds {
            guard let threadId = context.threadIdByMessageId[reference], !seen.contains(threadId) else { continue }
            seen.insert(threadId)
            matchedThreadIds.append(threadId)
        }

        if matchedThreadIds.count == 1 {
            return .join(threadId: matchedThreadIds[0])
        }
        if matchedThreadIds.count > 1 {
            // This message bridges previously-separate threads — merge the
            // smaller one(s) into the largest (by message count; ties
            // broken by the lowest thread id, for determinism).
            let ordered = matchedThreadIds.sorted { lhs, rhs in
                let lhsCount = context.threadMessageCounts[lhs] ?? 0
                let rhsCount = context.threadMessageCounts[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs < rhs
            }
            let target = ordered[0]
            let merged = Set(ordered.dropFirst())
            return .joinAndMerge(threadId: target, mergedThreadIds: merged)
        }

        // 3. Fallback: same normalized subject, overlapping participants,
        // within the time window. Ties broken toward the most recently
        // active candidate thread.
        if let subject = message.normalizedSubject, !subject.isEmpty {
            let candidates = context.subjectCandidatesByNormalizedSubject[subject] ?? []
            let matching = candidates.filter { candidate in
                !candidate.participants.isDisjoint(with: message.participants)
                    && abs(candidate.date.timeIntervalSince(message.date)) <= subjectFallbackWindow
            }
            if let best = matching.max(by: { $0.date < $1.date }) {
                return .join(threadId: best.threadId)
            }
        }

        // 4. Nothing matched.
        return .createNew
    }
}
