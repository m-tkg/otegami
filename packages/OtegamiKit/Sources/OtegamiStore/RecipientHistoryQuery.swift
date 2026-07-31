import Foundation
import GRDB
import OtegamiCore

/// Loads the raw material for the composer's To/Cc/Bcc suggestion dropdown
/// (Task #200) — every `from`/`to`/`cc` address across a bounded window of
/// the most recent messages, decoded into `RecipientOccurrence`s that
/// `OtegamiCore.RecipientSuggestionEngine` then aggregates/ranks/filters.
///
/// Deliberately *not* a `SELECT DISTINCT address, COUNT(*), MAX(date) ...
/// GROUP BY address` in SQL: `fromAddresses`/`toAddresses`/`ccAddresses`
/// are JSON blobs (`MessageRecord`'s doc comment explains why — GRDB's
/// automatic `Codable` array (de)serialization, not a normalized column),
/// so SQL has no way to see an individual address inside them. Aggregation
/// has to happen after decoding, in `RecipientSuggestionEngine`.
public enum RecipientHistoryQuery {
    /// Every occurrence of an address in `from`/`to`/`cc`, scanning at most
    /// `scanLimit` of the most recent messages (across every account —
    /// suggestions aren't scoped to the composer's currently-selected From
    /// account, since who you've mailed from one account is still a
    /// reasonable suggestion when sending from another).
    ///
    /// `scanLimit` bounds the cost of this query independent of total
    /// mailbox size — see `RecipientHistoryQueryPerformanceTests` for the
    /// measurement behind the default (`RecipientSuggestionSource
    /// .defaultScanLimit`), which lives in the app layer since only it
    /// knows the real device/app tradeoff; this function just takes
    /// whatever limit it's given.
    ///
    /// `excludingAddresses` (lowercased) drops the account's own address(es)
    /// — every received message has the receiving account in `to`, which
    /// would otherwise make "yourself" the single most frequent, most
    /// recent "correspondent" in every mailbox.
    public static func occurrences(
        scanLimit: Int,
        excludingAddresses: Set<String> = [],
        db: Database
    ) throws -> [RecipientOccurrence] {
        let rows = try AddressColumnsRow.fetchAll(
            db,
            sql: """
                SELECT fromAddresses, toAddresses, ccAddresses,
                       COALESCE(date, internalDate) AS sortDate
                FROM message
                ORDER BY sortDate DESC
                LIMIT ?
                """,
            arguments: [scanLimit]
        )
        var occurrences: [RecipientOccurrence] = []
        occurrences.reserveCapacity(rows.count * 2)
        for row in rows {
            for address in row.fromAddresses + row.toAddresses + row.ccAddresses {
                let trimmed = address.address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !excludingAddresses.contains(trimmed.lowercased()) else { continue }
                occurrences.append(RecipientOccurrence(name: address.name, address: trimmed, date: row.sortDate))
            }
        }
        return occurrences
    }
}

/// One `message` row's address columns + effective sort date — exactly the
/// columns ``RecipientHistoryQuery/occurrences(scanLimit:excludingAddresses:db:)``
/// needs, not a full `MessageRecord` (no subject/flags/body-state/etc. to
/// decode for every one of `scanLimit` rows).
private struct AddressColumnsRow: FetchableRecord, Decodable {
    var fromAddresses: [EmailAddress]
    var toAddresses: [EmailAddress]
    var ccAddresses: [EmailAddress]
    var sortDate: Date
}
