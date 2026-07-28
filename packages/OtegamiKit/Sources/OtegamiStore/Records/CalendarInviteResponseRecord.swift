import Foundation
import GRDB
import OtegamiCore

/// This device's own last-sent RSVP for a calendar invite message (Task
/// #66) — one row per `message.id`, keyed uniquely so re-responding
/// (tapping a different button, or the same one again) simply replaces the
/// previous row rather than accumulating history. Exists purely so
/// `MessageView`'s invite card can show "すでに『参加』で回答済み" (with the
/// buttons still available to change the response) the next time the same
/// message is opened, without re-sending anything — the actual RSVP send
/// itself is `SyncCoordinator.sendCalendarReply`, entirely independent of
/// this table.
///
/// Deliberately not synced anywhere (iCloud account sync, another device,
/// ...) — this is purely a local "what did *this* device already tell the
/// organizer" cache; the organizer's own copy of the event is the actual
/// source of truth for the RSVP itself.
public struct CalendarInviteResponseRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "calendarInviteResponse"

    public var id: Int64?
    public var messageId: Int64
    public var partStat: CalendarPartStat
    public var respondedAt: Date

    public init(
        id: Int64? = nil,
        messageId: Int64,
        partStat: CalendarPartStat,
        respondedAt: Date = Date()
    ) {
        self.id = id
        self.messageId = messageId
        self.partStat = partStat
        self.respondedAt = respondedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
