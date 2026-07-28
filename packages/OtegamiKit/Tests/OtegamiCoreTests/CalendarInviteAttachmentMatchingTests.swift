import Testing
@testable import OtegamiCore

/// Task #84: covers `CalendarInviteAttachmentMatching` against the shapes a
/// real Google Calendar invite (and the app's own original fixture) can take
/// — see its own doc comment for the two-separate-parts background.
struct CalendarInviteAttachmentMatchingTests {
    private struct Part {
        var mimeType: String
        var mimeSubtype: String
        var filename: String?
    }

    // MARK: - isInvitePart

    @Test("recognizes an unnamed text/calendar part")
    func recognizesUnnamedTextCalendar() {
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "text", mimeSubtype: "calendar", filename: nil))
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "Text", mimeSubtype: "Calendar", filename: nil))
    }

    @Test("recognizes an unnamed application/ics part")
    func recognizesUnnamedApplicationICS() {
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "application", mimeSubtype: "ics", filename: nil))
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "application", mimeSubtype: "x-ics", filename: nil))
    }

    @Test("recognizes a .ics-named attachment regardless of MIME type")
    func recognizesICSFilenameFallback() {
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "application", mimeSubtype: "octet-stream", filename: "invite.ics"))
        #expect(CalendarInviteAttachmentMatching.isInvitePart(mimeType: "application", mimeSubtype: "octet-stream", filename: "INVITE.ICS"))
    }

    @Test("does not misclassify an unrelated attachment")
    func rejectsUnrelatedAttachment() {
        #expect(!CalendarInviteAttachmentMatching.isInvitePart(mimeType: "application", mimeSubtype: "pdf", filename: "resume.pdf"))
        #expect(!CalendarInviteAttachmentMatching.isInvitePart(mimeType: "image", mimeSubtype: "png", filename: nil))
    }

    // MARK: - primaryInvitePart

    @Test("prefers the text/calendar part over a same-message application/ics part")
    func prefersTextCalendarOverApplicationICS() {
        let parts = [
            Part(mimeType: "application", mimeSubtype: "ics", filename: "invite.ics"),
            Part(mimeType: "text", mimeSubtype: "calendar", filename: nil),
        ]
        let match = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(match?.mimeType == "text")
    }

    @Test("finds the real Google Calendar invite shape: text/calendar nested alongside text/plain and text/html, plus a separate invite.ics")
    func realGoogleInviteShape() {
        let parts = [
            Part(mimeType: "text", mimeSubtype: "plain", filename: nil),
            Part(mimeType: "text", mimeSubtype: "html", filename: nil),
            Part(mimeType: "text", mimeSubtype: "calendar", filename: nil),
            Part(mimeType: "application", mimeSubtype: "ics", filename: "invite.ics"),
        ]
        let match = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(match?.mimeType == "text")
        #expect(match?.mimeSubtype == "calendar")
    }

    @Test("falls back to an application/ics part when no text/calendar part exists")
    func fallsBackToApplicationICS() {
        let parts = [
            Part(mimeType: "text", mimeSubtype: "plain", filename: nil),
            Part(mimeType: "application", mimeSubtype: "ics", filename: nil),
        ]
        let match = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(match?.mimeType == "application")
    }

    @Test("falls back to a .ics-named attachment when MIME type is generic")
    func fallsBackToICSFilename() {
        let parts = [
            Part(mimeType: "text", mimeSubtype: "plain", filename: nil),
            Part(mimeType: "application", mimeSubtype: "octet-stream", filename: "invite.ics"),
        ]
        let match = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(match?.filename == "invite.ics")
    }

    @Test("returns nil when nothing matches")
    func returnsNilWhenNoInvitePart() {
        let parts = [Part(mimeType: "text", mimeSubtype: "plain", filename: nil)]
        let match = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(match == nil)
    }
}
