import Foundation

/// One historical appearance of an address in a message's `from`/`to`/`cc`
/// — the raw input `RecipientSuggestionEngine` aggregates and ranks. Task
/// #200 (Composer 宛先サジェスト).
public struct RecipientOccurrence: Sendable, Equatable {
    public var name: String?
    public var address: String
    /// The message's date (`COALESCE(date, internalDate)` at the call
    /// site) — always present for a real history entry. There is currently
    /// no source that constructs an occurrence without one (see
    /// `RecipientSuggestionSource`'s doc comment for why device Contacts
    /// aren't mixed in for this feature's first pass); the type stays a
    /// plain non-optional `Date` rather than anticipating that.
    public var date: Date

    public init(name: String?, address: String, date: Date) {
        self.name = name
        self.address = address
        self.date = date
    }
}

/// One ranked, deduplicated candidate the composer's To/Cc/Bcc suggestion
/// dropdown can offer.
public struct RecipientSuggestion: Sendable, Equatable, Identifiable, Hashable {
    public var name: String?
    public var address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }

    /// Stable identity for SwiftUI `ForEach`/`Identifiable` — the address
    /// is what's actually unique (see the dedup note on
    /// ``RecipientSuggestionEngine``), lowercased to match how dedup itself
    /// keys.
    public var id: String { address.lowercased() }

    /// `"Name <address>"` (matches `EmailAddress.description`) or just the
    /// bare address when there's no display name — what the composer
    /// inserts into its comma-separated To/Cc/Bcc field when this
    /// suggestion is picked, and round-trips cleanly back through
    /// `ComposerView.parseAddresses(_:)`.
    public var formatted: String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}

/// Pure ranking/filtering logic for the composer's To/Cc/Bcc address
/// suggestions (Task #200, 実装済みの意思決定は下記/`docs/design-system.md`
/// 「宛先サジェスト」節参照). No I/O, no dependency on `OtegamiStore` — takes
/// whatever occurrences the caller already loaded (typically
/// `RecipientHistoryQuery` in `OtegamiStore`, cached by the app layer) and
/// re-derives the candidate list on every call, which is the part that
/// actually runs per keystroke; see `RecipientSuggestionEngineTests` for the
/// perf measurement behind treating that as cheap enough to not cache.
///
/// **Ranking**: frequency and recency both matter and neither alone is
/// right — a person mailed 50 times two years ago and never since shouldn't
/// permanently outrank someone mailed twice this week, but a single message
/// from years ago shouldn't beat a regular correspondent just because it's
/// technically "in history" at all. `score = frequencyScore(count) +
/// recencyScore(latestDate)`, both in comparable, unbounded-additive
/// ranges:
/// - `frequencyScore` is `log2(count + 1)` — each additional exchange with
///   the same person counts for less than the last, so one very chatty
///   correspondent (or a mailing list that lands in `to`/`cc` on every
///   message) can't bury everyone else just by volume.
/// - `recencyScore` decays linearly from 1 (today) to 0 at
///   `recencyHalfLifeDays` (180) and stays 0 (never negative) beyond that —
///   an old but frequent correspondent keeps their `frequencyScore`, they
///   just stop getting a recency bonus on top of it.
///
/// **Dedup**: keyed by the address, lowercased (email addresses are
/// case-insensitive in practice; two rows differing only in address case
/// are the same person). A person's display name can change over time (a
/// literal example this app's own fixtures use: "Tanaka Taro" →
/// "田中太郎"), so the *display* name shown for a deduplicated address is
/// whichever occurrence has the latest date, not the most frequent one or a
/// simple last-write-wins over insertion order — `count`/recency for
/// scoring still aggregate across every occurrence regardless of which
/// name each one carried.
public enum RecipientSuggestionEngine {
    /// See the type's doc comment's "recencyScore" paragraph.
    static let recencyHalfLifeDays: Double = 180

    static func recencyScore(date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86400)
        return max(0, 1 - days / recencyHalfLifeDays)
    }

    static func frequencyScore(count: Int) -> Double {
        log2(Double(count) + 1)
    }

    /// Ranked, deduplicated, query-filtered suggestions.
    ///
    /// - Parameters:
    ///   - query: the in-progress token the composer field's current
    ///     comma-separated segment holds (whitespace-trimmed by the
    ///     caller's tokenizer, not here). Empty/whitespace-only always
    ///     yields `[]` — this feature triggers on typing, not on merely
    ///     focusing an empty field (matches the request: "メールアドレス
    ///     入力時にサジェストが出る").
    ///   - occurrences: raw history, not yet aggregated/deduplicated.
    ///   - now: injectable for deterministic tests; defaults to the real
    ///     current time.
    ///   - limit: caps the result count — the composer only has room to
    ///     show a handful of rows without the dropdown overwhelming the
    ///     rest of the form.
    public static func suggestions(
        for query: String,
        occurrences: [RecipientOccurrence],
        now: Date = Date(),
        limit: Int = 8
    ) -> [RecipientSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        struct Aggregate {
            // The original-casing address to actually display/insert —
            // kept alongside the lowercased dedup key so display never
            // shows a forced-lowercase address just because that's what
            // merging keys off; updated together with `name` (latest
            // occurrence wins), so an address whose casing changed over
            // time still shows its most recent form.
            var displayAddress: String
            var name: String?
            var latestDate: Date?
            var count = 0
        }
        var aggregates: [String: Aggregate] = [:]
        aggregates.reserveCapacity(occurrences.count)
        for occurrence in occurrences {
            let address = occurrence.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let key = address.lowercased()
            var aggregate = aggregates[key] ?? Aggregate(displayAddress: address, name: nil, latestDate: nil, count: 0)
            aggregate.count += 1
            if aggregate.latestDate == nil || occurrence.date > aggregate.latestDate! {
                aggregate.latestDate = occurrence.date
                aggregate.displayAddress = address
                if let name = occurrence.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    aggregate.name = name
                }
            }
            aggregates[key] = aggregate
        }

        let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func matches(name: String?, address: String) -> Bool {
            if address.range(of: trimmedQuery, options: matchOptions) != nil { return true }
            if let name, name.range(of: trimmedQuery, options: matchOptions) != nil { return true }
            return false
        }

        let scored: [(suggestion: RecipientSuggestion, score: Double, key: String)] = aggregates.compactMap { key, aggregate in
            guard matches(name: aggregate.name, address: aggregate.displayAddress) else { return nil }
            let score = frequencyScore(count: aggregate.count)
                + (aggregate.latestDate.map { recencyScore(date: $0, now: now) } ?? 0)
            return (RecipientSuggestion(name: aggregate.name, address: aggregate.displayAddress), score, key)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.suggestion)
    }
}
