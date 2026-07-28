import Foundation

/// Task #84 (実物の Google カレンダー招待でカードが出ない):
/// `MessageView.calendarInviteAttachment`/`.listableAttachments` both need to
/// recognize "is this MIME part the technical carrier of a calendar invite"
/// — the former to find the part to hand `CalendarInviteSectionView`, the
/// latter to hide that same part (and any sibling invite part) from the
/// plain attachment list, the way Gmail/Spark don't show a raw "invite.ics"
/// row next to their own invite card. Pulled out as pure, dependency-free
/// logic (rather than a private computed property on the SwiftUI view) so
/// it's unit-testable without going through a view/database at all — see
/// `ICSCalendarParser`'s own doc comment for why `OtegamiCore` is where this
/// kind of parsing/classification logic lives.
///
/// A real Google Calendar invite carries the same event as *two* separate
/// MIME parts, not one:
///
/// - An unnamed `text/calendar; method=REQUEST` part, nested as a third
///   sibling of `multipart/alternative`'s `text/plain`/`text/html` (i.e. it
///   reads, to a MIME parser, as "just another representation of the body" —
///   Google emits it there per RFC 6047 §2.1's advice, for mail clients that
///   render `text/calendar` inline). mailcore2 doesn't treat it as a body
///   candidate (`MCHTMLRenderer.cpp`'s `isTextPart` excludes `text/calendar`
///   — see `docs/calendar-invites.md`), so it still surfaces through
///   `MCOMessageParser.attachments()` alongside genuine attachments, just
///   with no filename.
/// - A separate, named `application/ics; name="invite.ics"` (or sometimes
///   bare `application/octet-stream`) attachment under the top-level
///   `multipart/mixed`, for clients that only understand a downloadable
///   `.ics` file.
///
/// The original implementation (Task #66) only recognized `text/calendar`
/// by MIME type and otherwise fell back to matching a `.ics` filename —
/// which happens to still find the named `invite.ics` part, but silently
/// misses an *unnamed* `application/ics`-typed part some other calendar
/// senders emit (no `text/calendar` part at all, no `.ics`-suffixed
/// filename either).
public enum CalendarInviteAttachmentMatching {
    /// Whether a MIME part is a technical carrier of a calendar invite —
    /// either an inline `text/calendar` representation, an `application/ics`
    /// (or `application/x-ics`) part regardless of filename, or any part
    /// merely named `*.ics` regardless of its declared MIME type (some
    /// senders attach these as generic `application/octet-stream`).
    public static func isInvitePart(mimeType: String, mimeSubtype: String, filename: String?) -> Bool {
        let type = mimeType.lowercased()
        let subtype = mimeSubtype.lowercased()
        if type == "text" && subtype == "calendar" { return true }
        if type == "application" && (subtype == "ics" || subtype == "x-ics") { return true }
        return (filename ?? "").lowercased().hasSuffix(".ics")
    }

    /// Which single part among several invite-recognized candidates should
    /// actually drive the invite card's content — preferring a genuine
    /// `text/calendar` part (guaranteed plain ICS text) over an
    /// `application/ics`-typed part over a merely `.ics`-named one, in that
    /// order. `candidates` need not be pre-filtered to invite parts only;
    /// this only ever returns an element `isInvitePart` would also accept
    /// (or `nil` if none does).
    public static func primaryInvitePart<Candidate>(
        among candidates: [Candidate],
        mimeType: (Candidate) -> String,
        mimeSubtype: (Candidate) -> String,
        filename: (Candidate) -> String?
    ) -> Candidate? {
        if let match = candidates.first(where: { mimeType($0).lowercased() == "text" && mimeSubtype($0).lowercased() == "calendar" }) {
            return match
        }
        if let match = candidates.first(where: {
            let type = mimeType($0).lowercased()
            let subtype = mimeSubtype($0).lowercased()
            return type == "application" && (subtype == "ics" || subtype == "x-ics")
        }) {
            return match
        }
        return candidates.first { (filename($0) ?? "").lowercased().hasSuffix(".ics") }
    }
}
