import Foundation

/// A single calendar invitation extracted from a `text/calendar`
/// (`METHOD:REQUEST`) MIME part — Task #66 (カレンダー招待メール対応).
///
/// Deliberately holds only what the invite card UI (`承諾`/`辞退`/`未定`
/// buttons) needs, not a general-purpose iCalendar object model: no
/// recurrence rules, no `VALARM`, no `VTIMEZONE` component parsing (`DTSTART`/
/// `DTEND`'s own `TZID` param is resolved directly against `TimeZone
/// (identifier:)` — see `ICSCalendarParser.parseDate`'s doc comment for why
/// that's good enough here). `ICSCalendarParser.parse(_:)` is the only
/// production of this type; `ICSReplyBuilder.buildReply` is its inverse
/// (an invite + a chosen `CalendarPartStat` → the `METHOD:REPLY` text to
/// send back).
public struct CalendarInvite: Sendable, Equatable {
    /// The `VEVENT`'s `UID` — must round-trip verbatim into the `REPLY`'s
    /// own `UID` for Google Calendar (and any other CalDAV-backed calendar)
    /// to associate the reply with the original event.
    public var uid: String
    /// The `VEVENT`'s `SEQUENCE` (defaults to `0` when absent, per RFC
    /// 5545 §3.8.7.4) — echoed back unchanged in the `REPLY`, not
    /// incremented (only the organizer's own edits bump it).
    public var sequence: Int
    /// The top-level `VCALENDAR`'s `METHOD` (`"REQUEST"`, `"CANCEL"`, ...),
    /// uppercased. `nil` if the ICS text had none (malformed, but parsed
    /// anyway on a best-effort basis).
    public var method: String?
    public var summary: String?
    public var location: String?
    public var organizer: EmailAddress?
    public var attendees: [CalendarAttendee]
    public var start: CalendarInviteDate?
    public var end: CalendarInviteDate?

    public init(
        uid: String,
        sequence: Int = 0,
        method: String? = nil,
        summary: String? = nil,
        location: String? = nil,
        organizer: EmailAddress? = nil,
        attendees: [CalendarAttendee] = [],
        start: CalendarInviteDate? = nil,
        end: CalendarInviteDate? = nil
    ) {
        self.uid = uid
        self.sequence = sequence
        self.method = method
        self.summary = summary
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.start = start
        self.end = end
    }

    /// The attendee row matching `email` (case-insensitive address
    /// comparison, `mailto:`-stripped by `ICSCalendarParser` already) — how
    /// the invite card finds "my own" RSVP status among the event's
    /// attendee list to show as already-responded, and what
    /// `ICSReplyBuilder.buildReply` reads `selfAddress`'s current status
    /// from before overwriting it with the newly chosen one.
    public func attendee(matching email: String) -> CalendarAttendee? {
        let normalized = email.lowercased()
        return attendees.first { $0.email.address.lowercased() == normalized }
    }
}

/// One `ATTENDEE` line of a `VEVENT`.
public struct CalendarAttendee: Sendable, Equatable {
    public var email: EmailAddress
    public var partStat: CalendarPartStat

    public init(email: EmailAddress, partStat: CalendarPartStat) {
        self.email = email
        self.partStat = partStat
    }
}

/// RFC 5545 §3.2.12 `PARTSTAT` values this app's invite card cares about.
/// Only `.accepted`/`.declined`/`.tentative` are ever *sent* (the three
/// buttons the plan calls for); `.needsAction`/`.delegated` only ever show
/// up when *reading* an existing attendee list (an invite nobody has
/// responded to yet, or one delegated to someone else).
public enum CalendarPartStat: String, Sendable, Equatable, Codable {
    case needsAction = "NEEDS-ACTION"
    case accepted = "ACCEPTED"
    case declined = "DECLINED"
    case tentative = "TENTATIVE"
    case delegated = "DELEGATED"

    /// The invite card's label for this status — both the three response
    /// buttons' titles and "すでに回答済み" history display reuse this single
    /// source of truth so the two can never drift apart.
    public var label: String {
        switch self {
        case .needsAction: "未回答"
        case .accepted: "参加"
        case .declined: "不参加"
        case .tentative: "未定"
        case .delegated: "委任"
        }
    }
}

/// A `DTSTART`/`DTEND` value, resolved to an absolute `Date` (already
/// timezone-adjusted — see `ICSCalendarParser.parseDate`) plus whether the
/// original property was an all-day `VALUE=DATE` (no time-of-day at all,
/// as opposed to midnight in some specific zone).
public struct CalendarInviteDate: Sendable, Equatable {
    public var date: Date
    public var isAllDay: Bool

    public init(date: Date, isAllDay: Bool) {
        self.date = date
        self.isAllDay = isAllDay
    }
}
