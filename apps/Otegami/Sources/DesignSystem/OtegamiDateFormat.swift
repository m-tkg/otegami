import SwiftUI

/// Shared "list-style" date/time formatting: common mail-app convention of
/// showing just the time for today's messages (the date is implied) and the
/// full date + time otherwise, so a glance at the trailing column always
/// tells you "was this today, and if not, when" without spelling out
/// today's date redundantly. Used by `ThreadRowTrailing` (1d list rows,
/// shared by the unified inbox/mailbox list and search results) and
/// `ThreadMessageSummaryRow` (collapsed rows inside a thread's detail
/// screen) so every date column in the app reads the same way.
enum OtegamiDateFormat {
    static func listRowText(for date: Date) -> Text {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Text(date, format: .dateTime.hour().minute())
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Text(date, format: .dateTime.month().day().hour().minute())
        }
        return Text(date, format: .dateTime.year().month().day().hour().minute())
    }
}
