import Foundation

/// Parses raw iCalendar (RFC 5545) text — as extracted from a `text/calendar`
/// MIME part by the caller (Task #66; see `docs/calendar-invites.md`) —
/// into a `CalendarInvite`. Pure, dependency-free, and stateless: no MIME
/// knowledge here at all, only the ICS text format itself, so it can run
/// against any string regardless of where it came from (a real IMAP fetch,
/// a fixture `.eml`, a test literal).
///
/// Deliberately minimal: only the first `VEVENT` in the file is parsed (a
/// calendar invite email always carries exactly one — recurring-event
/// override series, multi-event `.ics` bundles, etc. are out of scope for
/// this app's "招待メールに承諾/辞退/未定ボタン" feature). Unknown properties
/// are silently ignored rather than rejected — an invite this app doesn't
/// fully understand should still show whatever it *does* understand
/// (title/time/organizer) rather than refuse to render at all.
public enum ICSCalendarParser {
    /// One unfolded, parsed `NAME;PARAM=VALUE;...:VALUE` content line
    /// (RFC 5545 §3.1).
    struct Property {
        var name: String
        var params: [String: String]
        var value: String
    }

    /// Parses `icsText` into a `CalendarInvite`, or `nil` if it has no
    /// `VEVENT` at all (not a calendar invite, or too malformed to salvage
    /// even a UID) or no `UID` — `CalendarInvite.uid` is load-bearing for
    /// `ICSReplyBuilder.buildReply`, so an event without one isn't
    /// repliable and isn't worth showing a card for.
    public static func parse(_ icsText: String) -> CalendarInvite? {
        let lines = unfoldedLines(icsText)

        let method = lines
            .compactMap(parseProperty)
            .first { $0.name == "METHOD" }?
            .value.uppercased()

        guard
            let beginIndex = lines.firstIndex(where: { $0.uppercased() == "BEGIN:VEVENT" }),
            let endIndex = lines.firstIndex(where: { $0.uppercased() == "END:VEVENT" }),
            endIndex > beginIndex
        else { return nil }

        let eventProperties = lines[(beginIndex + 1)..<endIndex].compactMap(parseProperty)

        var uid: String?
        var sequence = 0
        var summary: String?
        var location: String?
        var organizer: EmailAddress?
        var attendees: [CalendarAttendee] = []
        var start: CalendarInviteDate?
        var end: CalendarInviteDate?

        for property in eventProperties {
            switch property.name {
            case "UID":
                uid = property.value
            case "SEQUENCE":
                sequence = Int(property.value) ?? 0
            case "SUMMARY":
                summary = unescapeText(property.value)
            case "LOCATION":
                location = unescapeText(property.value)
            case "ORGANIZER":
                organizer = emailAddress(from: property)
            case "ATTENDEE":
                guard let address = emailAddress(from: property) else { continue }
                let rawPartStat = property.params["PARTSTAT"]?.uppercased() ?? ""
                let partStat = CalendarPartStat(rawValue: rawPartStat) ?? .needsAction
                attendees.append(CalendarAttendee(email: address, partStat: partStat))
            case "DTSTART":
                start = parseDate(property)
            case "DTEND":
                end = parseDate(property)
            default:
                break
            }
        }

        guard let uid, !uid.isEmpty else { return nil }
        return CalendarInvite(
            uid: uid,
            sequence: sequence,
            method: method,
            summary: summary,
            location: location,
            organizer: organizer,
            attendees: attendees,
            start: start,
            end: end
        )
    }

    // MARK: - Line unfolding (RFC 5545 §3.1)

    /// Joins folded continuation lines (a line beginning with a single
    /// space or tab is a continuation of the previous line, with that one
    /// leading whitespace character removed) back into one logical content
    /// line per property — servers/clients wrap long lines at 75 octets
    /// this way, so a `SUMMARY`/`DESCRIPTION` line split mid-word needs
    /// this pass before property parsing can find `:` in the right place.
    static func unfoldedLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else {
                result.append(line)
            }
        }
        return result
    }

    // MARK: - Property parsing

    /// Splits one unfolded content line into name/params/value. The
    /// property name and its parameters are separated from the value by
    /// the first `:` that isn't inside a `"..."`-quoted parameter value
    /// (RFC 5545 §3.2's `param-value` allows `:`/`;`/`,` only when
    /// quoted) — e.g. an `ATTENDEE`'s `mailto:` value must not be mistaken
    /// for that separator.
    static func parseProperty(_ line: String) -> Property? {
        guard !line.isEmpty else { return nil }

        var insideQuotes = false
        var colonIndex: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == ":", !insideQuotes {
                colonIndex = index
                break
            }
            index = line.index(after: index)
        }
        guard let colonIndex else { return nil }

        let head = line[line.startIndex..<colonIndex]
        let value = String(line[line.index(after: colonIndex)...])

        var headParts = head.components(separatedBy: ";")
        guard !headParts.isEmpty else { return nil }
        let name = headParts.removeFirst().uppercased()
        guard !name.isEmpty else { return nil }

        var params: [String: String] = [:]
        for part in headParts {
            let keyValue = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard keyValue.count == 2 else { continue }
            var paramValue = keyValue[1]
            if paramValue.hasPrefix("\""), paramValue.hasSuffix("\""), paramValue.count >= 2 {
                paramValue = String(paramValue.dropFirst().dropLast())
            }
            params[keyValue[0].uppercased()] = paramValue
        }

        return Property(name: name, params: params, value: value)
    }

    /// RFC 5545 §3.3.11 TEXT escaping: `\\` → `\`, `\;` → `;`, `\,` → `,`,
    /// `\n`/`\N` → a real newline. Anything else after a backslash is
    /// passed through as-is (lenient — a stray/unknown escape shouldn't
    /// corrupt the rest of the string).
    static func unescapeText(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append(character)
                break
            }
            switch escaped {
            case "n", "N": result.append("\n")
            case "\\": result.append("\\")
            case ";": result.append(";")
            case ",": result.append(",")
            default: result.append(escaped)
            }
        }
        return result
    }

    /// `ORGANIZER`/`ATTENDEE` values are `mailto:address` with an optional
    /// `CN` (common name) parameter.
    static func emailAddress(from property: Property) -> EmailAddress? {
        var value = property.value
        if value.lowercased().hasPrefix("mailto:") {
            value = String(value.dropFirst("mailto:".count))
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return EmailAddress(name: property.params["CN"], address: trimmed)
    }

    // MARK: - Date parsing

    /// `DTSTART`/`DTEND` come in three shapes (RFC 5545 §3.3.5):
    /// `VALUE=DATE` (all-day, `YYYYMMDD`, no time-of-day at all — resolved
    /// against the *current device* calendar/timezone purely for display,
    /// since an all-day event has no real timezone to begin with),
    /// a bare `YYYYMMDDTHHMMSS` ("floating" local time — resolved against
    /// the device's current timezone, the closest approximation without a
    /// `VTIMEZONE` component to consult), a `Z`-suffixed UTC form, or a
    /// `TZID`-parameterized form (resolved via `TimeZone(identifier:)`;
    /// falls back to the device's current timezone if `TZID` names a zone
    /// Foundation doesn't recognize, rather than failing the whole parse).
    static func parseDate(_ property: Property) -> CalendarInviteDate? {
        let value = property.value
        let isAllDay = property.params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T"))

        guard value.count >= 8 else { return nil }
        let digits = Array(value)
        guard
            let year = Int(String(digits[0..<4])),
            let month = Int(String(digits[4..<6])),
            let day = Int(String(digits[6..<8]))
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        var calendar = Calendar(identifier: .gregorian)

        if isAllDay {
            calendar.timeZone = .current
            guard let date = calendar.date(from: components) else { return nil }
            return CalendarInviteDate(date: date, isAllDay: true)
        }

        guard value.count >= 15, digits[8] == "T" else { return nil }
        guard
            let hour = Int(String(digits[9..<11])),
            let minute = Int(String(digits[11..<13])),
            let second = Int(String(digits[13..<15]))
        else { return nil }
        components.hour = hour
        components.minute = minute
        components.second = second

        if value.hasSuffix("Z") {
            // swiftlint:disable:next force_unwrapping
            calendar.timeZone = TimeZone(identifier: "UTC")!
        } else if let tzid = property.params["TZID"], let zone = TimeZone(identifier: tzid) {
            calendar.timeZone = zone
        } else {
            calendar.timeZone = .current
        }

        guard let date = calendar.date(from: components) else { return nil }
        return CalendarInviteDate(date: date, isAllDay: false)
    }
}
