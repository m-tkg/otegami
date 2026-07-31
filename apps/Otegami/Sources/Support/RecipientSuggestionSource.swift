import Foundation
import GRDB
import OtegamiCore
import OtegamiStore

/// Backs the composer's To/Cc/Bcc suggestion dropdown (Task #200,
/// `docs/design-system.md`'s「宛先サジェスト」note). Owned once by
/// `AppEnvironment` (`environment.recipientSuggestionSource`) — every
/// composer session shares the same cached candidate list rather than each
/// one re-scanning message history from scratch.
///
/// **Source**: past correspondence only (`from`/`to`/`cc` of synced mail,
/// via `RecipientHistoryQuery`), not device Contacts — a deliberate choice,
/// not a placeholder: (1) it needs no permission at all, so suggestions
/// always work the moment there's any mail history, satisfying the "許可が
/// 無い/拒否されていても過去のやり取りだけで動く" requirement trivially
/// (there's no permission to be missing); (2) a contact with no mail
/// history is unlikely to be who someone's about to write to, so it's a
/// weaker relevance signal for *this* feature than an address book; (3)
/// mixing sources adds a precedence/merge policy and doubles what needs
/// testing for comparatively little payoff in a first version. Nothing here
/// forecloses layering in already-authorized Contacts data later as a
/// supplementary, lower-priority source.
///
/// **Caching**: `RecipientHistoryQuery.occurrences` decodes every recent
/// message's JSON address columns — cheap per row but not something to redo
/// on every keystroke (measured in `RecipientHistoryQueryPerformanceTests`,
/// `packages/OtegamiKit`). This actor loads the candidate list once
/// (lazily, on first use) and reuses it; `refresh()` re-scans on demand —
/// `ComposerView` calls it once per compose session (its own `.task`, not
/// per keystroke) so mail that arrived since the cache was last built is
/// picked up without needing an app relaunch.
public actor RecipientSuggestionSource {
    /// See `RecipientHistoryQueryPerformanceTests` (`packages/OtegamiKit`)
    /// for the measurement this is based on: scanning the most recent 3,000
    /// messages' address columns decoded in well under 200ms even against a
    /// 50,000-message seeded mailbox with realistic address JSON on every
    /// row (real numbers recorded in `docs/performance.md`) — and the query
    /// cost stays flat regardless of total mailbox size (`ORDER BY ...
    /// LIMIT`, not a full scan). 3,000 messages is already a deep recency
    /// window for suggestions to feel complete in normal use, so there was
    /// no reason to push it higher and pay more decode cost for no
    /// perceptible benefit.
    public static let defaultScanLimit = 3000

    private let dbWriter: any DatabaseWriter
    private let scanLimit: Int
    private var cachedOccurrences: [RecipientOccurrence]?

    public init(dbWriter: any DatabaseWriter, scanLimit: Int = RecipientSuggestionSource.defaultScanLimit) {
        self.dbWriter = dbWriter
        self.scanLimit = scanLimit
    }

    /// The cached candidate list, loading it first if this is the first
    /// call since launch (or since the last ``refresh()``).
    ///
    /// - Parameter excludingAddresses: lowercased addresses to drop —
    ///   typically the user's own account address(es), so "yourself" (in
    ///   `to` on every received message) never dominates the ranking.
    ///   Applied fresh on every call (a cheap filter over an already-cached
    ///   array — see the type's caching note) rather than baked into the
    ///   cached scan, so it can safely differ between calls without
    ///   invalidating the cache.
    public func occurrences(excludingAddresses: Set<String> = []) async -> [RecipientOccurrence] {
        let all: [RecipientOccurrence]
        if let cachedOccurrences {
            all = cachedOccurrences
        } else {
            all = await load()
        }
        guard !excludingAddresses.isEmpty else { return all }
        return all.filter { !excludingAddresses.contains($0.address.lowercased()) }
    }

    /// Re-scans message history from scratch, replacing the cache.
    @discardableResult
    public func refresh() async -> [RecipientOccurrence] {
        await load()
    }

    private func load() async -> [RecipientOccurrence] {
        // Captured by value into a local before crossing into the
        // `@Sendable` closure below — `dbWriter.read` runs it off-actor,
        // so it can't reach back into `self`'s actor-isolated storage.
        let limit = scanLimit
        let occurrences = (try? await dbWriter.read { db in
            try RecipientHistoryQuery.occurrences(scanLimit: limit, db: db)
        }) ?? []
        cachedOccurrences = occurrences
        return occurrences
    }
}
