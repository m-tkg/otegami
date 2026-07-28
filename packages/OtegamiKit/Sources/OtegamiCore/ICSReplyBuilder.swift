import Foundation

/// Builds the iTIP `METHOD:REPLY` ICS body (RFC 5546 §3.2.3) and the
/// surrounding email text for responding to a `CalendarInvite` — the
/// inverse of `ICSCalendarParser.parse(_:)` (Task #66). The caller
/// (`MessageView`'s invite card) is responsible for actually sending this
/// as a `text/calendar; method=REPLY` attachment on an email addressed to
/// `invite.organizer` — see `MailTransport.ComposeAttachment
/// .contentTypeParameters` for how `method=REPLY` reaches the wire.
///
/// Google Calendar (and every other CalDAV-backed calendar this app is
/// likely to see an invite from) updates the sender's RSVP status on the
/// original event purely from this reply email: matching `UID` +
/// `ORGANIZER` + the replying `ATTENDEE`'s new `PARTSTAT` is all it needs,
/// no API call or OAuth calendar scope required.
public enum ICSReplyBuilder {
    /// The full `VCALENDAR` text (CRLF line endings, per RFC 5545) to send
    /// as the reply's `text/calendar` part. `invite.sequence` is echoed
    /// back unchanged — only the organizer's own edits ever bump
    /// `SEQUENCE`, never an attendee's reply.
    public static func buildReply(
        for invite: CalendarInvite,
        partStat: CalendarPartStat,
        selfAddress: EmailAddress,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("BEGIN:VCALENDAR")
        lines.append("PRODID:-//Otegami//Calendar Reply//EN")
        lines.append("VERSION:2.0")
        lines.append("METHOD:REPLY")
        lines.append("BEGIN:VEVENT")
        if let organizer = invite.organizer {
            lines.append("ORGANIZER\(cnParameter(organizer)):mailto:\(organizer.address)")
        }
        lines.append("UID:\(invite.uid)")
        lines.append("SEQUENCE:\(invite.sequence)")
        lines.append("DTSTAMP:\(formatUTCTimestamp(now))")
        lines.append("ATTENDEE;PARTSTAT=\(partStat.rawValue)\(cnParameter(selfAddress)):mailto:\(selfAddress.address)")
        if let summary = invite.summary {
            lines.append("SUMMARY:\(escapeText(summary))")
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The outgoing reply email's `Subject:` — mirrors the convention
    /// Google Calendar/Gmail itself uses for its own invite replies
    /// ("Accepted: <title>" / "Declined: <title>" / "Tentative: <title>"),
    /// so a reply this app sends looks exactly like one sent from any
    /// other calendar client in the organizer's inbox.
    public static func subject(for invite: CalendarInvite, partStat: CalendarPartStat) -> String {
        let title = invite.summary ?? ""
        let prefix: String
        switch partStat {
        case .accepted: prefix = "Accepted"
        case .declined: prefix = "Declined"
        case .tentative: prefix = "Tentative"
        case .needsAction, .delegated: prefix = "RSVP"
        }
        return title.isEmpty ? prefix : "\(prefix): \(title)"
    }

    /// A short human-readable plain-text body accompanying the
    /// `text/calendar` part — every iTIP `REPLY` in the wild carries one,
    /// since a mail client with no calendar integration at all should
    /// still show *something* readable instead of a bare attachment.
    public static func plainTextBody(for invite: CalendarInvite, partStat: CalendarPartStat, selfAddress: EmailAddress) -> String {
        let name = selfAddress.name ?? selfAddress.address
        let title = invite.summary ?? "this event"
        switch partStat {
        case .accepted: return "\(name) has accepted this invitation to \(title)."
        case .declined: return "\(name) has declined this invitation to \(title)."
        case .tentative: return "\(name) has tentatively accepted this invitation to \(title)."
        case .needsAction, .delegated: return "\(name)'s response to this invitation to \(title) has changed."
        }
    }

    private static func cnParameter(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return "" }
        return ";CN=\(escapeParameterValue(name))"
    }

    /// RFC 5545 §3.2's quoting rule for a param-value containing a `:`,
    /// `;`, or `,` — none of those are expected in a display name in
    /// practice, but quoting whenever any of them are present keeps this
    /// correct rather than silently producing a malformed line.
    private static func escapeParameterValue(_ value: String) -> String {
        guard value.contains(":") || value.contains(";") || value.contains(",") else { return value }
        return "\"\(value)\""
    }

    private static func formatUTCTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// RFC 5545 §3.3.11 TEXT escaping — the inverse of `ICSCalendarParser
    /// .unescapeText(_:)`.
    private static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
