import Foundation
import Testing
@testable import OtegamiCore

@Suite("ICSReplyBuilder")
struct ICSReplyBuilderTests {
    static let invite = CalendarInvite(
        uid: "abc123@google.com",
        sequence: 2,
        method: "REQUEST",
        summary: "Quarterly Planning Sync",
        location: "Conference Room A",
        organizer: EmailAddress(name: "Otegami Organizer", address: "organizer@example.com"),
        attendees: [
            CalendarAttendee(email: EmailAddress(name: "Test One", address: "test1@otegami.test"), partStat: .needsAction)
        ]
    )

    static let selfAddress = EmailAddress(name: "Test One", address: "test1@otegami.test")

    @Test(
        "buildReply produces a METHOD:REPLY VCALENDAR with matching UID/SEQUENCE and the chosen PARTSTAT",
        arguments: [CalendarPartStat.accepted, .declined, .tentative]
    )
    func buildReplyRoundTripsCoreFields(partStat: CalendarPartStat) throws {
        let ics = ICSReplyBuilder.buildReply(for: Self.invite, partStat: partStat, selfAddress: Self.selfAddress)

        #expect(ics.contains("METHOD:REPLY"))
        #expect(ics.contains("UID:abc123@google.com"))
        #expect(ics.contains("SEQUENCE:2"))
        #expect(ics.contains("PARTSTAT=\(partStat.rawValue)"))
        #expect(ics.contains("mailto:test1@otegami.test"))
        #expect(ics.contains("mailto:organizer@example.com"))
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))

        // The reply itself should re-parse back into a well-formed invite,
        // confirming this is round-trippable ICS text, not just a string
        // that happens to contain the right substrings.
        let reparsed = try #require(ICSCalendarParser.parse(ics))
        #expect(reparsed.uid == Self.invite.uid)
        #expect(reparsed.sequence == Self.invite.sequence)
        #expect(reparsed.method == "REPLY")
        #expect(reparsed.attendee(matching: "test1@otegami.test")?.partStat == partStat)
    }

    @Test(
        "subject(for:partStat:) matches Google Calendar's own reply subject convention",
        arguments: [
            (CalendarPartStat.accepted, "Accepted: Quarterly Planning Sync"),
            (CalendarPartStat.declined, "Declined: Quarterly Planning Sync"),
            (CalendarPartStat.tentative, "Tentative: Quarterly Planning Sync")
        ]
    )
    func subjectMatchesConvention(partStat: CalendarPartStat, expected: String) {
        #expect(ICSReplyBuilder.subject(for: Self.invite, partStat: partStat) == expected)
    }

    @Test("subject falls back to just the verb when the invite has no title")
    func subjectFallsBackWithNoSummary() {
        let untitled = CalendarInvite(uid: "no-title@example.com")
        #expect(ICSReplyBuilder.subject(for: untitled, partStat: .accepted) == "Accepted")
    }

    @Test("plainTextBody names the responder and the event for every PARTSTAT")
    func plainTextBodyIsHumanReadable() {
        let accepted = ICSReplyBuilder.plainTextBody(for: Self.invite, partStat: .accepted, selfAddress: Self.selfAddress)
        #expect(accepted.contains("Test One"))
        #expect(accepted.contains("Quarterly Planning Sync"))
        #expect(accepted.contains("accepted"))

        let declined = ICSReplyBuilder.plainTextBody(for: Self.invite, partStat: .declined, selfAddress: Self.selfAddress)
        #expect(declined.contains("declined"))
    }
}
