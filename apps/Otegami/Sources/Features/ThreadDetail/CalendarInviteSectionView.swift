import SwiftUI
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport

/// Task #66 (カレンダー招待メール対応): owns every piece of state
/// `CalendarInviteCardView` needs — loading/parsing the `text/calendar`
/// part, this device's previously-recorded response (`CalendarInviteResponseRecord`),
/// and sending a new one — so `MessageView` itself only needs to decide
/// *whether* to show this at all (`MessageView.calendarInviteAttachment`)
/// and pass through the handful of ids/paths this needs. Kept as its own
/// file/type rather than folded into `MessageView`'s already-large `body`,
/// per CLAUDE.md's "SwiftUI ビューは小さく保つこと" rule.
struct CalendarInviteSectionView: View {
    @Environment(AppEnvironment.self) private var environment

    let accountId: String
    let messageId: Int64
    let messageUID: Int64
    let mailboxPath: String?
    let calendarAttachment: AttachmentRecord

    @State private var invite: CalendarInvite?
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    /// This device's own last-sent RSVP (`CalendarInviteResponseRecord`),
    /// falling back to the invite's own attendee list for the account's
    /// address if this app never sent one — see `loadCurrentResponse()`'s
    /// doc comment.
    @State private var currentResponse: CalendarPartStat?
    @State private var isSending = false
    @State private var sendingPartStat: CalendarPartStat?
    @State private var sendErrorMessage: String?

    var body: some View {
        Group {
            if let invite {
                CalendarInviteCardView(
                    invite: invite,
                    currentResponse: currentResponse,
                    isSending: isSending,
                    sendingPartStat: sendingPartStat,
                    errorMessage: sendErrorMessage,
                    onRespond: { partStat in Task { await respond(partStat) } }
                )
            } else if isLoading {
                HStack {
                    ProgressView()
                    Text("招待の内容を読み込んでいます…")
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                }
                .padding(OtegamiSpacing.md)
                .otegamiCardBackground(OtegamiColor.surface)
                .accessibilityIdentifier("messageDetail.calendarInvite.loading")
            } else if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.destructive)
                    .padding(OtegamiSpacing.md)
                    .otegamiCardBackground(OtegamiColor.surface)
                    .accessibilityIdentifier("messageDetail.calendarInvite.loadError")
            }
        }
        .task(id: calendarAttachment.id) { await load() }
    }

    // MARK: - Loading

    private func load() async {
        invite = nil
        loadErrorMessage = nil
        currentResponse = nil
        isLoading = true
        defer { isLoading = false }

        guard let icsText = await loadICSText() else {
            loadErrorMessage = "招待の内容を読み込めませんでした。"
            return
        }
        guard let parsed = ICSCalendarParser.parse(icsText) else {
            loadErrorMessage = "この招待の内容を解析できませんでした。"
            return
        }
        invite = parsed
        await loadCurrentResponse(for: parsed)
    }

    /// Downloads (if not already cached locally) and reads the `text/
    /// calendar` part's raw text. Reuses `SyncCoordinator.fetchAttachment`
    /// — the exact same on-demand fetch-and-store path `MessageView
    /// .openAttachment(_:)` already uses for every other attachment — so
    /// this invite card benefits from the same local caching (a second
    /// open of the same message re-reads the already-downloaded file
    /// instead of re-fetching over the network).
    private func loadICSText() async -> String? {
        if let localPath = calendarAttachment.localPath,
           let data = FileManager.default.contents(atPath: localPath) {
            return String(decoding: data, as: UTF8.self)
        }
        guard let mailboxPath else { return nil }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return nil }
        do {
            let auth = try await environment.auth(for: account)
            let updated = try await environment.syncCoordinator.fetchAttachment(
                calendarAttachment, messageUID: messageUID, mailboxPath: mailboxPath, account: account, auth: auth
            )
            guard let localPath = updated.localPath, let data = FileManager.default.contents(atPath: localPath) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// This device's own last-sent response takes precedence over the
    /// invite's own attendee list — the ICS text this app fetched is a
    /// snapshot from whenever the body/attachment was downloaded, so it
    /// can't know about a reply *this* device sent after that (the
    /// organizer's copy updates, but this attendee's own inbound copy of
    /// the invite doesn't re-fetch itself). Only falls back to the
    /// invite's own attendee list — matched against the account's email,
    /// same as `ICSCalendarParser.CalendarInvite.attendee(matching:)` — for
    /// a message this app has genuinely never responded to itself (e.g.
    /// responded via Google Calendar's web UI, or a fresh invite).
    /// `.needsAction` (no response at all) is treated as `nil` — nothing to
    /// show a "現在の回答" line for.
    private func loadCurrentResponse(for invite: CalendarInvite) async {
        let recorded = try? await environment.database.dbWriter.read { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).fetchOne(db)
        }
        if let recorded {
            currentResponse = recorded.partStat
            return
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        let attendeePartStat = invite.attendee(matching: account.email)?.partStat
        currentResponse = attendeePartStat == .needsAction ? nil : attendeePartStat
    }

    // MARK: - Responding

    private func respond(_ partStat: CalendarPartStat) async {
        guard let invite, let organizer = invite.organizer else {
            sendErrorMessage = "この招待には主催者の情報がありません。"
            return
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            sendErrorMessage = "アカウントが見つかりません。"
            return
        }

        sendErrorMessage = nil
        isSending = true
        sendingPartStat = partStat
        defer {
            isSending = false
            sendingPartStat = nil
        }

        do {
            let auth = try await environment.auth(for: account)
            let selfAddress = EmailAddress(name: account.displayName, address: account.email)
            let icsReply = ICSReplyBuilder.buildReply(for: invite, partStat: partStat, selfAddress: selfAddress)
            let draft = ComposeDraft(
                from: selfAddress,
                to: [organizer],
                subject: ICSReplyBuilder.subject(for: invite, partStat: partStat),
                plainTextBody: ICSReplyBuilder.plainTextBody(for: invite, partStat: partStat, selfAddress: selfAddress),
                attachments: [
                    ComposeAttachment(
                        filename: "invite.ics",
                        mimeType: "text/calendar",
                        data: Data(icsReply.utf8),
                        contentTypeParameters: ["method": "REPLY", "charset": "UTF-8"]
                    )
                ]
            )
            try await environment.syncCoordinator.sendCalendarReply(draft, account: account, auth: auth)
            try await saveResponse(partStat)
            currentResponse = partStat
        } catch {
            sendErrorMessage = "返信の送信に失敗しました: \(error)"
        }
    }

    /// One row per message, replacing whatever was there before — see
    /// `CalendarInviteResponseRecord`'s doc comment for why re-responding
    /// doesn't accumulate history.
    private func saveResponse(_ partStat: CalendarPartStat) async throws {
        let messageId = messageId
        try await environment.database.dbWriter.write { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).deleteAll(db)
            var record = CalendarInviteResponseRecord(messageId: messageId, partStat: partStat)
            try record.insert(db)
        }
    }
}
