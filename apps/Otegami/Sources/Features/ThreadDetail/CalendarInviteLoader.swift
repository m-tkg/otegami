import Foundation
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import os

/// Task #94 (実機で招待カードが出ない): owns every piece of state
/// `CalendarInviteSectionView`/`CalendarInviteCardView` show — the ICS
/// download/parse result, this device's recorded RSVP, an in-flight
/// response send — as a plain reference type held in `MessageView`'s own
/// `@State` (the same "reference-type state holder outlives child-view
/// remounts" pattern `MessageDetailAIFeaturesState`/`aiState` already
/// established for the AI features toolbar), rather than as `@State` inside
/// `CalendarInviteSectionView` itself with a `.task(id:)` doing the loading.
///
/// That used to be this feature's design (Task #66), and `docs/verify.md`'s
/// known-issue #5 records the unresolved suspicion that `MessageView.load()`'s
/// own several `@State` writes (each triggering a `body` re-evaluation) were
/// causing `CalendarInviteSectionView` — gated behind `if let
/// calendarInviteAttachment, let mailboxPath { ... }` — to unmount/remount
/// mid-flight, cancelling its `.task` before `load()` ever got past its
/// first `isLoading = true` line: exactly "no card at all", indistinguishable
/// from the attachment never having been recognized in the first place (the
/// real-device report this task investigates). Moving the load into a plain
/// `Task { }` kicked off from `MessageView.load()` itself (not a SwiftUI
/// `.task` modifier) sidesteps the question of *which* exact remount was
/// happening: an ordinary `Task` isn't cancelled by any `View`'s lifecycle at
/// all, and re-invoking `load(attachment:...)` for an attachment already
/// loaded/loading is a deliberate no-op (`loadedAttachmentId` below), so a
/// child view remounting mid-flight (for whatever reason) now only means
/// "re-read this same already-in-progress-or-already-loaded state", never
/// "lose progress and go silent."
@MainActor
@Observable
final class CalendarInviteLoader {
    enum LoadState {
        case idle
        case loading
        case loaded(CalendarInvite)
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    /// This device's own last-sent RSVP, falling back to the invite's own
    /// attendee list for the account's address if this app never sent one —
    /// see `loadCurrentResponse`'s doc comment. `nil`/`.needsAction` both
    /// mean "nothing to show a 現在の回答 line for".
    private(set) var currentResponse: CalendarPartStat?
    var isSending = false
    var sendingPartStat: CalendarPartStat?
    var sendErrorMessage: String?

    @ObservationIgnored private var loadedAttachmentId: Int64?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "CalendarInvite")

    /// Called from `MessageView.load()`'s own reset block — this loader is
    /// reused across message navigations (it lives in `MessageView`'s
    /// `@State`, not a per-message child view's), so a genuinely new
    /// `messageId` must never show a previous message's invite/response
    /// state while the new one loads.
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        loadedAttachmentId = nil
        state = .idle
        currentResponse = nil
        isSending = false
        sendingPartStat = nil
        sendErrorMessage = nil
    }

    /// Logs which attachment (if any) `CalendarInviteAttachmentMatching`
    /// picked as the primary invite carrier among `attachments`, and every
    /// candidate's own MIME type/filename when none matched — the
    /// recognition half of Task #94's OSLog instrumentation, so a real-
    /// device "no card" report is diagnosable from one `log stream` capture:
    ///
    /// ```
    /// log stream --predicate 'subsystem == "com.mtkg.otegami" && category == "CalendarInvite"'
    /// ```
    static func logRecognition(messageId: Int64, attachments: [AttachmentRecord], primary: AttachmentRecord?) {
        if let primary {
            logger.info(
                "recognize: messageId=\(messageId, privacy: .public) matched contentType=\(primary.mimeType, privacy: .public)/\(primary.mimeSubtype, privacy: .public) filename=\(primary.filename ?? "(none)", privacy: .public) partId=\(primary.partId, privacy: .public)"
            )
        } else {
            let summary = attachments
                .map { "\($0.mimeType)/\($0.mimeSubtype)\($0.filename.map { " (\($0))" } ?? "")" }
                .joined(separator: ", ")
            logger.info(
                "recognize: messageId=\(messageId, privacy: .public) no invite candidate among \(attachments.count, privacy: .public) attachment(s): [\(summary, privacy: .public)]"
            )
        }
    }

    /// Downloads (if not already cached locally — auto-download, no user
    /// action needed) and parses the invite driving `attachment`. A no-op if
    /// this `attachment.id` is already loaded or currently loading — see
    /// this type's own doc comment for why that's exactly what makes this
    /// resilient to a caller (`CalendarInviteSectionView`) remounting.
    func load(
        attachment: AttachmentRecord,
        messageId: Int64,
        messageUID: Int64,
        mailboxPath: String,
        accountId: String,
        environment: AppEnvironment
    ) {
        guard loadedAttachmentId != attachment.id else { return }
        loadedAttachmentId = attachment.id
        loadTask?.cancel()
        state = .loading
        sendErrorMessage = nil
        Self.logger.info("download: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) start")
        loadTask = Task { [weak self] in
            await self?.performLoad(
                attachment: attachment, messageId: messageId, messageUID: messageUID,
                mailboxPath: mailboxPath, accountId: accountId, environment: environment
            )
        }
    }

    /// The invite card's error state's "再試行" button: forgets that this
    /// attachment was already attempted, then calls `load` again.
    func retry(
        attachment: AttachmentRecord,
        messageId: Int64,
        messageUID: Int64,
        mailboxPath: String,
        accountId: String,
        environment: AppEnvironment
    ) {
        loadedAttachmentId = nil
        load(
            attachment: attachment, messageId: messageId, messageUID: messageUID,
            mailboxPath: mailboxPath, accountId: accountId, environment: environment
        )
    }

    private func performLoad(
        attachment: AttachmentRecord,
        messageId: Int64,
        messageUID: Int64,
        mailboxPath: String,
        accountId: String,
        environment: AppEnvironment
    ) async {
        guard let icsText = await loadICSText(
            attachment: attachment, messageId: messageId, messageUID: messageUID,
            mailboxPath: mailboxPath, accountId: accountId, environment: environment
        ) else {
            Self.logger.error("download: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) failed")
            state = .failed(String(localized: "招待の内容を読み込めませんでした。"))
            return
        }
        guard let parsed = ICSCalendarParser.parse(icsText) else {
            Self.logger.error(
                "parse: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) failed (unparseable ICS text, length=\(icsText.count, privacy: .public))"
            )
            state = .failed(String(localized: "この招待の内容を解析できませんでした。"))
            return
        }
        Self.logger.info(
            "parse: messageId=\(messageId, privacy: .public) uid=\(parsed.uid, privacy: .public) method=\(parsed.method ?? "(none)", privacy: .public) succeeded"
        )
        state = .loaded(parsed)
        await loadCurrentResponse(for: parsed, messageId: messageId, accountId: accountId, environment: environment)
    }

    /// Reuses `SyncCoordinator.fetchAttachment` — the same on-demand fetch-
    /// and-store path `MessageView.openAttachment(_:)` uses for every other
    /// attachment — so a second open of the same message re-reads the
    /// already-downloaded file instead of re-fetching over the network.
    private func loadICSText(
        attachment: AttachmentRecord,
        messageId: Int64,
        messageUID: Int64,
        mailboxPath: String,
        accountId: String,
        environment: AppEnvironment
    ) async -> String? {
        if let localPath = attachment.localPath, let data = FileManager.default.contents(atPath: localPath) {
            Self.logger.info("download: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) already cached locally (\(data.count, privacy: .public) bytes)")
            return String(decoding: data, as: UTF8.self)
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            Self.logger.error("download: messageId=\(messageId, privacy: .public) account not found for accountId")
            return nil
        }
        do {
            let auth = try await environment.auth(for: account)
            let updated = try await environment.syncCoordinator.fetchAttachment(
                attachment, messageUID: messageUID, mailboxPath: mailboxPath, account: account, auth: auth
            )
            guard let localPath = updated.localPath, let data = FileManager.default.contents(atPath: localPath) else {
                return nil
            }
            Self.logger.info("download: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) completed (\(data.count, privacy: .public) bytes)")
            return String(decoding: data, as: UTF8.self)
        } catch {
            Self.logger.error("download: messageId=\(messageId, privacy: .public) partId=\(attachment.partId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// This device's own last-sent response takes precedence over the
    /// invite's own attendee list (see `CalendarInviteResponseRecord`'s doc
    /// comment); only falls back to the invite's own `ATTENDEE` `PARTSTAT`
    /// for the account's address — i.e. a response recorded by some *other*
    /// mail client (the organizer's Google Calendar web UI, a different
    /// device) — for a message this app has never itself responded to.
    private func loadCurrentResponse(for invite: CalendarInvite, messageId: Int64, accountId: String, environment: AppEnvironment) async {
        let recorded = try? await environment.database.dbWriter.read { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).fetchOne(db)
        }
        if let recorded {
            currentResponse = recorded.partStat
            Self.logger.info("card: messageId=\(messageId, privacy: .public) currentResponse from this device's own record: \(recorded.partStat.rawValue, privacy: .public)")
            return
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        let attendeePartStat = invite.attendee(matching: account.email)?.partStat
        currentResponse = attendeePartStat == .needsAction ? nil : attendeePartStat
        if let currentResponse {
            Self.logger.info("card: messageId=\(messageId, privacy: .public) currentResponse from invite's own ATTENDEE PARTSTAT (other client): \(currentResponse.rawValue, privacy: .public)")
        } else {
            Self.logger.info("card: messageId=\(messageId, privacy: .public) no prior response (own record or ATTENDEE PARTSTAT)")
        }
    }

    func respond(
        _ partStat: CalendarPartStat,
        messageId: Int64,
        accountId: String,
        environment: AppEnvironment
    ) async {
        guard case .loaded(let invite) = state, let organizer = invite.organizer else {
            sendErrorMessage = String(localized: "この招待には主催者の情報がありません。")
            return
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            sendErrorMessage = String(localized: "アカウントが見つかりません。")
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
            try await saveResponse(partStat, messageId: messageId, environment: environment)
            currentResponse = partStat
            Self.logger.info("respond: messageId=\(messageId, privacy: .public) partStat=\(partStat.rawValue, privacy: .public) sent")
        } catch {
            Self.logger.error("respond: messageId=\(messageId, privacy: .public) partStat=\(partStat.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            sendErrorMessage = "返信の送信に失敗しました: \(error)"
        }
    }

    /// One row per message, replacing whatever was there before — see
    /// `CalendarInviteResponseRecord`'s doc comment for why re-responding
    /// doesn't accumulate history.
    private func saveResponse(_ partStat: CalendarPartStat, messageId: Int64, environment: AppEnvironment) async throws {
        try await environment.database.dbWriter.write { db in
            try CalendarInviteResponseRecord.filter(Column("messageId") == messageId).deleteAll(db)
            var record = CalendarInviteResponseRecord(messageId: messageId, partStat: partStat)
            try record.insert(db)
        }
    }
}
