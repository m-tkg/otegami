import Foundation
import Testing
@testable import OtegamiCore

@Suite("ICSCalendarParser")
struct ICSCalendarParserTests {
    /// A realistic Google Calendar-style `METHOD:REQUEST` invite: UTC
    /// `DTSTART`/`DTEND`, an `ORGANIZER`, two `ATTENDEE`s (one already
    /// `NEEDS-ACTION`), matching the shape of `dev/mailstack/seed/fixtures/
    /// 36-calendar-invite-google.eml`'s `text/calendar` part.
    static let googleStyleInvite = """
    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART:20260803T060000Z
    DTEND:20260803T070000Z
    DTSTAMP:20260728T000000Z
    ORGANIZER;CN=Otegami Organizer:mailto:organizer@example.com
    UID:abc123@google.com
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Test One:mailto:test1@otegami.test
    CREATED:20260728T000000Z
    DESCRIPTION:Quarterly planning sync\\nAgenda attached.
    LAST-MODIFIED:20260728T000000Z
    LOCATION:Conference Room A
    SEQUENCE:0
    STATUS:CONFIRMED
    SUMMARY:Quarterly Planning Sync
    TRANSP:OPAQUE
    END:VEVENT
    END:VCALENDAR
    """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test("parses UID, sequence, method, summary, location, organizer, attendees")
    func parsesCoreFields() throws {
        let invite = try #require(ICSCalendarParser.parse(Self.googleStyleInvite))
        #expect(invite.uid == "abc123@google.com")
        #expect(invite.sequence == 0)
        #expect(invite.method == "REQUEST")
        #expect(invite.summary == "Quarterly Planning Sync")
        #expect(invite.location == "Conference Room A")
        #expect(invite.organizer?.address == "organizer@example.com")
        #expect(invite.organizer?.name == "Otegami Organizer")
        #expect(invite.attendees.count == 1)
        #expect(invite.attendees.first?.email.address == "test1@otegami.test")
        #expect(invite.attendees.first?.partStat == .needsAction)
    }

    @Test("parses UTC DTSTART/DTEND into the correct absolute instant")
    func parsesUTCDateTime() throws {
        let invite = try #require(ICSCalendarParser.parse(Self.googleStyleInvite))
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 3
        components.hour = 6; components.minute = 0; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expectedStart = calendar.date(from: components)
        #expect(invite.start?.date == expectedStart)
        #expect(invite.start?.isAllDay == false)
    }

    @Test("attendee(matching:) finds self case-insensitively")
    func attendeeMatchingIsCaseInsensitive() throws {
        let invite = try #require(ICSCalendarParser.parse(Self.googleStyleInvite))
        let selfAttendee = invite.attendee(matching: "TEST1@Otegami.Test")
        #expect(selfAttendee?.email.address == "test1@otegami.test")
    }

    @Test("all-day VALUE=DATE event has no time-of-day and isAllDay is true")
    func parsesAllDayEvent() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20260901
        DTEND;VALUE=DATE:20260902
        UID:allday-1@example.com
        SUMMARY:Company Holiday
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try #require(ICSCalendarParser.parse(ics))
        #expect(invite.start?.isAllDay == true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 1
        #expect(invite.start?.date == calendar.date(from: components))
    }

    @Test("DTSTART with a named TZID resolves against that timezone, not UTC")
    func parsesTZIDDateTime() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        DTSTART;TZID=Asia/Tokyo:20260803T150000
        UID:tzid-1@example.com
        SUMMARY:Tokyo Meeting
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try #require(ICSCalendarParser.parse(ics))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 3
        components.hour = 15; components.minute = 0; components.second = 0
        #expect(invite.start?.date == calendar.date(from: components))
    }

    @Test("folded (wrapped) lines are unfolded before parsing")
    func unfoldsWrappedLines() throws {
        // A continuation line begins with a single space, per RFC 5545
        // §3.1 — SUMMARY here is split mid-word the way a real 75-octet
        // wrap would.
        let ics = "BEGIN:VCALENDAR\r\n" +
            "VERSION:2.0\r\n" +
            "METHOD:REQUEST\r\n" +
            "BEGIN:VEVENT\r\n" +
            "SUMMARY:This is a very long event title that wraps across \r\n" +
            " multiple folded lines in the real ICS text\r\n" +
            "UID:folded-1@example.com\r\n" +
            "SEQUENCE:0\r\n" +
            "END:VEVENT\r\n" +
            "END:VCALENDAR\r\n"
        let invite = try #require(ICSCalendarParser.parse(ics))
        #expect(invite.summary == "This is a very long event title that wraps across multiple folded lines in the real ICS text")
    }

    @Test("backslash escapes in SUMMARY/LOCATION are decoded")
    func unescapesText() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:Line one\\nLine two\\, with a comma\\; and a semicolon
        LOCATION:Room A\\, Building 2
        UID:escape-1@example.com
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try #require(ICSCalendarParser.parse(ics))
        #expect(invite.summary == "Line one\nLine two, with a comma; and a semicolon")
        #expect(invite.location == "Room A, Building 2")
    }

    @Test("no VEVENT at all returns nil")
    func noVEventReturnsNil() {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"
        #expect(ICSCalendarParser.parse(ics) == nil)
    }

    @Test("a VEVENT missing UID returns nil")
    func missingUIDReturnsNil() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        SUMMARY:No UID here
        SEQUENCE:0
        END:VEVENT
        END:VCALENDAR
        """
        #expect(ICSCalendarParser.parse(ics) == nil)
    }

    /// Task #94 (「応答済み表示」): the existing coverage above only ever
    /// exercised `PARTSTAT=NEEDS-ACTION` — this pins down that `ACCEPTED`/
    /// `DECLINED`/`TENTATIVE` (the three values `CalendarInviteLoader
    /// .loadCurrentResponse` actually needs to recognize, to show "すでに
    /// 別のクライアントで回答済み" for an invite this app itself never
    /// responded to) parse correctly too, one attendee per status.
    @Test("ATTENDEE PARTSTAT of ACCEPTED/DECLINED/TENTATIVE all parse correctly, not just NEEDS-ACTION")
    func parsesNonDefaultAttendeePartStats() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:partstat-variety@example.com
        SUMMARY:Partstat Variety
        SEQUENCE:0
        ATTENDEE;PARTSTAT=ACCEPTED;CN=Accepted Person:mailto:accepted@example.com
        ATTENDEE;PARTSTAT=DECLINED;CN=Declined Person:mailto:declined@example.com
        ATTENDEE;PARTSTAT=TENTATIVE;CN=Tentative Person:mailto:tentative@example.com
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try #require(ICSCalendarParser.parse(ics))
        #expect(invite.attendee(matching: "accepted@example.com")?.partStat == .accepted)
        #expect(invite.attendee(matching: "declined@example.com")?.partStat == .declined)
        #expect(invite.attendee(matching: "tentative@example.com")?.partStat == .tentative)
    }

    @Test("missing SEQUENCE defaults to 0")
    func missingSequenceDefaultsToZero() throws {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:no-sequence@example.com
        SUMMARY:No sequence
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try #require(ICSCalendarParser.parse(ics))
        #expect(invite.sequence == 0)
    }
}
