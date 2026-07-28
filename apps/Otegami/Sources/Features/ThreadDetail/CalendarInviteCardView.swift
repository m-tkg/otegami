import SwiftUI
import OtegamiCore

/// Task #66 (カレンダー招待メール対応): the invite card shown at the top of a
/// calendar invite email's body — title/time/location/organizer plus the
/// 「承諾」「辞退」「未定」response buttons. Pure presentation, same split as
/// `AttachmentCardRow`/`MessageDetailFooterToolbar`'s `translateButton`
/// (formerly `TranslationFloatingButton`, moved by Task #88): every piece of state
/// (the parsed invite, which response is currently recorded, whether a send
/// is in flight) lives in the parent (`CalendarInviteSectionView`) and is
/// handed in as plain values, this view only renders them and forwards taps
/// via `onRespond`.
struct CalendarInviteCardView: View {
    let invite: CalendarInvite
    /// The RSVP this device has already recorded for this invite (either
    /// sent by this app previously, or read off the invite's own attendee
    /// list for "self" if this app never sent one) — `nil` means no
    /// response is known yet. `.needsAction` is treated the same as `nil`
    /// by the caller (see `CalendarInviteSectionView`'s doc comment) since
    /// "hasn't responded" isn't worth a "現在の回答" line of its own.
    let currentResponse: CalendarPartStat?
    let isSending: Bool
    /// Which button's tap triggered the in-flight send, so only *that*
    /// button shows a spinner rather than disabling/graying out all three
    /// indiscriminately.
    let sendingPartStat: CalendarPartStat?
    let errorMessage: String?
    let onRespond: (CalendarPartStat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            header
            if let summary = invite.summary, !summary.isEmpty {
                Text(summary)
                    .font(OtegamiFont.headline())
                    .foregroundStyle(OtegamiColor.ink)
                    .accessibilityIdentifier("messageDetail.calendarInvite.summary")
            }
            if let dateRangeText {
                detailRow(systemImage: "clock", text: dateRangeText, accessibilityId: "messageDetail.calendarInvite.dateRange")
            }
            if let location = invite.location, !location.isEmpty {
                detailRow(systemImage: "mappin.and.ellipse", text: location, accessibilityId: "messageDetail.calendarInvite.location")
            }
            if let organizer = invite.organizer {
                detailRow(systemImage: "person", text: organizer.description, accessibilityId: "messageDetail.calendarInvite.organizer")
            }
            if let currentResponse, currentResponse != .needsAction {
                Text("現在の回答: \(localizedLabel(for: currentResponse))")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("messageDetail.calendarInvite.currentResponse")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("messageDetail.calendarInvite.error")
            }
            buttonRow
        }
        .padding(OtegamiSpacing.md)
        .otegamiCardBackground(OtegamiColor.surface)
        .accessibilityIdentifier("messageDetail.calendarInvite")
    }

    private var header: some View {
        Label {
            Text("予定への招待")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
        } icon: {
            Image(systemName: "calendar")
                .foregroundStyle(OtegamiColor.accent)
        }
        .accessibilityIdentifier("messageDetail.calendarInvite.header")
    }

    private func detailRow(systemImage: String, text: String, accessibilityId: String) -> some View {
        Label {
            Text(text)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.ink)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier(accessibilityId)
    }

    private var buttonRow: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            responseButton(.accepted, title: String(localized: "承諾"))
            responseButton(.declined, title: String(localized: "辞退"))
            responseButton(.tentative, title: String(localized: "未定"))
        }
        .padding(.top, OtegamiSpacing.xs)
    }

    private func responseButton(_ partStat: CalendarPartStat, title: String) -> some View {
        let isSelected = currentResponse == partStat
        let isThisButtonSending = isSending && sendingPartStat == partStat
        return Button {
            onRespond(partStat)
        } label: {
            HStack(spacing: OtegamiSpacing.xs) {
                if isThisButtonSending {
                    ProgressView()
                        .tint(isSelected ? .white : OtegamiColor.ink)
                }
                Text(title)
                    .font(OtegamiFont.subheadline())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OtegamiSpacing.sm)
            .foregroundStyle(isSelected ? .white : OtegamiColor.ink)
            .background(isSelected ? tintColor(for: partStat) : OtegamiColor.paleBase)
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityIdentifier("messageDetail.calendarInvite.button.\(partStat.rawValue)")
    }

    /// `CalendarPartStat.label` (`OtegamiCore`) is a plain, non-localized
    /// constant — that package has no String Catalog of its own (it's pure
    /// business logic, not UI) — so the app-facing "現在の回答" line routes
    /// each case through its own `String(localized:)` call here instead,
    /// the same way `buttonRow`'s three titles already do, rather than
    /// displaying `OtegamiCore`'s untranslated Japanese constant verbatim
    /// in an English-localized build.
    private func localizedLabel(for partStat: CalendarPartStat) -> String {
        switch partStat {
        case .accepted: String(localized: "参加")
        case .declined: String(localized: "不参加")
        case .tentative: String(localized: "未定")
        case .needsAction: String(localized: "未回答")
        case .delegated: String(localized: "委任")
        }
    }

    /// No new colors added (CLAUDE.md's "新しい色をその場で追加しない") — reuses
    /// the existing `accent`/`destructive`/`inkSecondary` tokens, the same
    /// three-color mapping `AttachmentKind.tintColor` already established
    /// for "positive/negative/neutral" in this same screen.
    private func tintColor(for partStat: CalendarPartStat) -> Color {
        switch partStat {
        case .accepted: OtegamiColor.accent
        case .declined: OtegamiColor.destructive
        case .tentative, .needsAction, .delegated: OtegamiColor.inkSecondary
        }
    }

    /// A human-readable date/time line — always the device's local
    /// timezone (`invite.start`/`.end` are already resolved to absolute
    /// `Date`s by `ICSCalendarParser`, so `Text(date, format:)` below
    /// renders them in whatever zone the device is currently in, same as
    /// every other date the app shows). All-day events show just the
    /// date(s), no time-of-day.
    private var dateRangeText: String? {
        guard let start = invite.start else { return nil }
        if start.isAllDay {
            guard let end = invite.end, end.date > start.date else {
                return Self.dateOnlyFormatter.string(from: start.date)
            }
            return "\(Self.dateOnlyFormatter.string(from: start.date)) – \(Self.dateOnlyFormatter.string(from: end.date))"
        }
        guard let end = invite.end else {
            return Self.dateTimeFormatter.string(from: start.date)
        }
        if Calendar.current.isDate(start.date, inSameDayAs: end.date) {
            return "\(Self.dateTimeFormatter.string(from: start.date)) – \(Self.timeOnlyFormatter.string(from: end.date))"
        }
        return "\(Self.dateTimeFormatter.string(from: start.date)) – \(Self.dateTimeFormatter.string(from: end.date))"
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
