import SwiftUI
import OtegamiCore
import OtegamiStore

/// Task #66 (カレンダー招待メール対応)/#94 (実機で招待カードが出ない根治):
/// purely presentational — every piece of load/response state lives in
/// `loader` (`CalendarInviteLoader`, owned by `MessageView`'s own `@State`,
/// injected here) rather than this view's own `@State`. `MessageView` itself
/// already kicked off `loader.load(...)` as part of its own linear `load()`
/// flow by the time this view is ever asked to render, so this has no
/// `.task` of its own — see `CalendarInviteLoader`'s doc comment for why
/// that's exactly the point: this view can be torn down and remounted any
/// number of times (whatever SwiftUI identity churn `MessageView`'s many
/// `@State` updates cause its parent's `if let calendarInviteAttachment,
/// let mailboxPath { ... }` conditional to trigger) without ever losing
/// progress or silently rendering nothing — `body` below always shows
/// exactly one of "loading"/"content"/"error+retry" for a recognized
/// invite, never an empty `Group`.
struct CalendarInviteSectionView: View {
    @Environment(AppEnvironment.self) private var environment

    let accountId: String
    let messageId: Int64
    let messageUID: Int64
    let mailboxPath: String
    let calendarAttachment: AttachmentRecord
    let loader: CalendarInviteLoader

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                loadingRow
            case .loaded(let invite):
                CalendarInviteCardView(
                    invite: invite,
                    currentResponse: loader.currentResponse,
                    isSending: loader.isSending,
                    sendingPartStat: loader.sendingPartStat,
                    errorMessage: loader.sendErrorMessage,
                    onRespond: { partStat in Task { await respond(partStat) } }
                )
            case .failed(let message):
                errorRow(message)
            }
        }
    }

    private var loadingRow: some View {
        HStack {
            ProgressView()
            Text("招待の内容を読み込んでいます…")
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .padding(OtegamiSpacing.md)
        .otegamiCardBackground(.quaternary)
        .accessibilityIdentifier("messageDetail.calendarInvite.loading")
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Text(message)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.destructive)
                .accessibilityIdentifier("messageDetail.calendarInvite.loadError")
            Button(String(localized: "再試行")) { retry() }
                .buttonStyle(.plain)
                .foregroundStyle(OtegamiColor.accent)
                .accessibilityIdentifier("messageDetail.calendarInvite.retry")
        }
        .padding(OtegamiSpacing.md)
        .otegamiCardBackground(.quaternary)
    }

    private func retry() {
        loader.retry(
            attachment: calendarAttachment, messageId: messageId, messageUID: messageUID,
            mailboxPath: mailboxPath, accountId: accountId, environment: environment
        )
    }

    private func respond(_ partStat: CalendarPartStat) async {
        await loader.respond(partStat, messageId: messageId, accountId: accountId, environment: environment)
    }
}
