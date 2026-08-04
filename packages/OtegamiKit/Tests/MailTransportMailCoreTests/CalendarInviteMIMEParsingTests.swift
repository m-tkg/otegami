import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// Task #94 follow-up to #84/#66's `CalendarInviteIntegrationTests`: those
/// tests are opt-in (`.enabled(if: TestIMAPEnvironment.primary != nil, ...)`)
/// because they round-trip through a real Dovecot connection, so they don't
/// run as part of a plain `make test`/CI — a regression there could go
/// unnoticed indefinitely. `MCOMessageParser(data:)` parses a raw RFC 822
/// blob entirely locally (the same fact `MessageBuilderTests` in this same
/// target already relies on), so this suite feeds real-Gmail-shaped MIME
/// bytes straight into `MailCoreIMAPSession.bodyContent(from:)` — the exact
/// function `MailCoreIMAPSession.fetchBody` calls — without any network or
/// dev mailstack, so it always runs.
///
/// The real-device report behind Task #94 ("添付ファイル 0 個", no invite
/// card) raised the question of whether some Gmail MIME shape *deeper* than
/// fixtures 36/37 (`multipart/mixed` > `multipart/alternative` > `[text/
/// plain, text/html, text/calendar]`) fails to surface the `text/calendar`
/// part — specifically `multipart/related` wrapping that `multipart/
/// alternative` (Gmail adds this extra layer when the HTML body references
/// an inline image by `cid:`, which some invite templates do). This suite
/// confirms that extra nesting level doesn't matter either — mailcore2's
/// `MCHTMLRenderer` (`docs/calendar-invites.md`) walks every multipart
/// container type generically, so the `text/calendar` part still surfaces
/// through `attachments()`/`htmlInlineAttachments()` regardless of how many
/// containers deep it sits.
extension MailCoreLocalSuite {
    @Suite("Calendar invite MIME parsing (no dev mailstack required)")
    struct CalendarInviteMIMEParsingTests {
        /// `multipart/mixed` > `multipart/related` > `multipart/alternative` >
        /// `[text/plain, text/html, text/calendar; method=REQUEST]`, plus a
        /// sibling `application/ics` attachment under the top-level `mixed` —
        /// one level deeper than `37-calendar-invite-nested-alternative.eml`.
        private static let nestedInRelatedEML = """
        From: Otani Organizer <organizer@example.com>\r
        To: test1@otegami.test\r
        Subject: Invitation: Weekly Sync\r
        Message-ID: <related-invite@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="mixedBoundary"\r
        \r
        --mixedBoundary\r
        Content-Type: multipart/related; boundary="relatedBoundary"\r
        \r
        --relatedBoundary\r
        Content-Type: multipart/alternative; boundary="altBoundary"\r
        \r
        --altBoundary\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        Weekly Sync, see attached invite.\r
        \r
        --altBoundary\r
        Content-Type: text/html; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        <html><body><img src="cid:tracking-pixel"><p>Weekly Sync</p></body></html>\r
        \r
        --altBoundary\r
        Content-Type: text/calendar; charset="UTF-8"; method=REQUEST\r
        Content-Transfer-Encoding: 7bit\r
        \r
        BEGIN:VCALENDAR\r
        PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
        VERSION:2.0\r
        CALSCALE:GREGORIAN\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        DTSTART:20260803T060000Z\r
        DTEND:20260803T070000Z\r
        DTSTAMP:20260728T000000Z\r
        ORGANIZER;CN=Otani Organizer:mailto:organizer@example.com\r
        UID:related-invite-event@example.com\r
        ATTENDEE;PARTSTAT=NEEDS-ACTION;CN=Test One:mailto:test1@otegami.test\r
        SEQUENCE:0\r
        STATUS:CONFIRMED\r
        SUMMARY:Weekly Sync\r
        TRANSP:OPAQUE\r
        END:VEVENT\r
        END:VCALENDAR\r
        \r
        --altBoundary--\r
        --relatedBoundary\r
        Content-Type: image/png\r
        Content-Transfer-Encoding: base64\r
        Content-ID: <tracking-pixel>\r
        Content-Disposition: inline\r
        \r
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YA\r
        AAAASUVORK5CYII=\r
        \r
        --relatedBoundary--\r
        --mixedBoundary\r
        Content-Type: application/ics; name="invite.ics"\r
        Content-Disposition: attachment; filename="invite.ics"\r
        Content-Transfer-Encoding: base64\r
        \r
        QkVHSU46VkNBTEVOREFSDQpFTkQ6VkNBTEVOREFSDQo=\r
        \r
        --mixedBoundary--\r
        """

        @Test("BodyFetcher's underlying bodyContent(from:) discovers text/calendar nested inside multipart/related > multipart/alternative")
        func discoversCalendarPartNestedInsideRelatedThenAlternative() throws {
            let parser = MCOMessageParser(data: Data(Self.nestedInRelatedEML.utf8))
            let content = MailCoreIMAPSession.bodyContent(from: parser)

            let calendarPart = try #require(content.parts.first { $0.mimeType == "text" && $0.mimeSubtype == "calendar" })
            #expect(calendarPart.filename == nil)

            let icsAttachment = try #require(content.parts.first { ($0.filename ?? "").lowercased() == "invite.ics" })
            #expect(icsAttachment.mimeType == "application")

            // Same recognition `MessageView.calendarInviteAttachment`/
            // `CalendarInviteAttachmentMatching` use in production — both parts
            // are recognized, and the text/calendar one wins as primary.
            for part in [calendarPart, icsAttachment] {
                #expect(CalendarInviteAttachmentMatching.isInvitePart(
                    mimeType: part.mimeType, mimeSubtype: part.mimeSubtype, filename: part.filename
                ))
            }
            let primary = CalendarInviteAttachmentMatching.primaryInvitePart(
                among: content.parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
            )
            #expect(primary?.partId == calendarPart.partId)

            // The inline cid: image must not be mistaken for the invite, and
            // must not itself count as a "listable" plain attachment either
            // (out of scope here — `MessageView.listableAttachments` already
            // excludes it via `isInline`; this just confirms the MIME layer
            // still reports it distinctly from the calendar part).
            let inlineImage = try #require(content.parts.first { $0.contentId != nil })
            #expect(inlineImage.mimeType == "image")
            #expect(!CalendarInviteAttachmentMatching.isInvitePart(
                mimeType: inlineImage.mimeType, mimeSubtype: inlineImage.mimeSubtype, filename: inlineImage.filename
            ))
        }

        /// A minimal, non-nested shape: a bare `multipart/mixed` with only a
        /// `text/calendar; method=REQUEST` part and no separate `.ics`
        /// attachment at all (some non-Google calendar senders — and Gmail
        /// invites forwarded through a relay that strips the redundant
        /// attachment — only send the inline representation). Confirms the
        /// card-driving lookup doesn't require *both* parts to be present.
        @Test("a lone text/calendar part with no separate .ics attachment is still discovered")
        func discoversLoneCalendarPartWithNoSeparateAttachment() throws {
            let eml = """
            From: Otani Organizer <organizer@example.com>\r
            To: test1@otegami.test\r
            Subject: Invitation: Solo Calendar Part\r
            Message-ID: <solo-invite@example.com>\r
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="soloBoundary"\r
            \r
            --soloBoundary\r
            Content-Type: text/plain; charset="UTF-8"\r
            Content-Transfer-Encoding: 7bit\r
            \r
            See attached invite.\r
            \r
            --soloBoundary\r
            Content-Type: text/calendar; charset="UTF-8"; method=REQUEST\r
            Content-Transfer-Encoding: 7bit\r
            \r
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            METHOD:REQUEST\r
            BEGIN:VEVENT\r
            DTSTART:20260803T060000Z\r
            UID:solo-invite-event@example.com\r
            SEQUENCE:0\r
            SUMMARY:Solo Calendar Part\r
            END:VEVENT\r
            END:VCALENDAR\r
            \r
            --soloBoundary--\r
            """
            let parser = MCOMessageParser(data: Data(eml.utf8))
            let content = MailCoreIMAPSession.bodyContent(from: parser)

            let calendarPart = try #require(content.parts.first { $0.mimeType == "text" && $0.mimeSubtype == "calendar" })
            let primary = CalendarInviteAttachmentMatching.primaryInvitePart(
                among: content.parts, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
            )
            #expect(primary?.partId == calendarPart.partId)
        }
    }
}
