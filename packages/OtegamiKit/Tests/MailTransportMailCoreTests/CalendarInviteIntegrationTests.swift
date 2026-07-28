import Foundation
import GRDB
import Testing
@testable import MailTransportMailCore
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Task #66 (カレンダー招待メール対応) integration coverage: confirms the
/// real MIME pipeline (`MailCoreIMAPSession.fetchBody` → `SyncEngine
/// .BodyFetcher` → `AttachmentFetcher`) discovers and downloads a real
/// Google Calendar-style invite email's `text/calendar` part correctly, and
/// that `OtegamiCore.ICSCalendarParser` parses the downloaded bytes into
/// the exact event `dev/mailstack/seed/fixtures/
/// 36-calendar-invite-google.eml` encodes — end-to-end from "message
/// arrives" to "app has a `CalendarInvite` to show a card for", the same
/// shape `AttachmentFetcherIntegrationTests` already established for a
/// plain file attachment.
///
/// Opt-in like the rest of this target. Run with:
///
/// ```sh
/// make mailstack-up
/// make mailstack-seed
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter CalendarInviteIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "Calendar invite against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct CalendarInviteIntegrationTests {
    /// Same cleanup rationale as `AttachmentFetcherIntegrationTests
    /// .cleanUp(accountId:)` — `AttachmentFetcher` writes to the real (not
    /// in-memory) Application Support directory.
    private func cleanUp(accountId: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("otegami/Attachments/\(accountId)", isDirectory: true))
    }

    @Test("BodyFetcher discovers the text/calendar part, AttachmentFetcher downloads it, and ICSCalendarParser parses the real invite")
    func endToEndCalendarInviteDiscoveryDownloadAndParse() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let database = try AppDatabase.makeInMemory()

        let account = AccountRecord(
            displayName: "Integration", email: "test1@otegami.test", authType: .password,
            imapHost: env.host, imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }
        defer { cleanUp(accountId: account.id) }

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }
        _ = try await session.select("INBOX")

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let envelope = try #require(envelopes.first { $0.messageId == "<seed-0036@otegami.test>" })

        let messageId = try await database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!, uid: Int64(envelope.uid), subject: envelope.subject,
                internalDate: envelope.internalDate
            )
            try message.insert(db)
            return message.id!
        }
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId)! }

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        // The fixture's text/calendar part has no filename (Google's own
        // invites don't set one on this specific part — only the sibling
        // application/ics attachment does), so this discovers it the same
        // way `MessageView.calendarInviteAttachment` does: by MIME type/
        // subtype, not filename.
        let calendarPart = try #require(try await database.dbWriter.read { db in
            try AttachmentRecord
                .filter(Column("messageId") == messageId)
                .filter(Column("mimeType") == "text")
                .filter(Column("mimeSubtype") == "calendar")
                .fetchOne(db)
        })

        let downloaded = try await AttachmentFetcher(database: database).fetchAndStore(
            attachment: calendarPart, accountId: account.id, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )
        let localPath = try #require(downloaded.localPath)
        let icsData = try Data(contentsOf: URL(fileURLWithPath: localPath))
        let icsText = String(decoding: icsData, as: UTF8.self)

        let invite = try #require(ICSCalendarParser.parse(icsText))
        #expect(invite.uid == "seed-0036-event@otegami.test")
        #expect(invite.method == "REQUEST")
        #expect(invite.sequence == 0)
        #expect(invite.summary == "四半期計画会議 (Quarterly Planning Sync)")
        #expect(invite.location == "会議室A / Conference Room A")
        #expect(invite.organizer?.address == "organizer@otegami.test")
        #expect(invite.organizer?.name == "Otegami Organizer")

        let selfAttendee = try #require(invite.attendee(matching: "test1@otegami.test"))
        #expect(selfAttendee.partStat == .needsAction)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 3
        components.hour = 6; components.minute = 0; components.second = 0
        #expect(invite.start?.date == calendar.date(from: components))
        #expect(invite.start?.isAllDay == false)
    }

    /// Task #84: the real-device report was that a genuine Google Calendar
    /// invite showed *no* invite card at all — only two generic attachment
    /// rows ("添付ファイル (名前なし)" and "invite.ics"). Fixture 36 (above)
    /// models `text/calendar` as a `multipart/mixed`-level sibling of
    /// `multipart/alternative`; the real structure nests it *inside* that
    /// `multipart/alternative`, as a third representation alongside
    /// `text/plain`/`text/html` (`37-calendar-invite-nested-alternative.eml`).
    /// This test's whole point is confirming `MailCoreIMAPSession
    /// .fetchBody`/`BodyFetcher` still discover that nested part with the
    /// same `mimeType == "text"`/`mimeSubtype == "calendar"` regardless of
    /// nesting depth (mailcore2's `MCOMessageParser.attachments()` doesn't
    /// distinguish by container, only by the part's own MIME type — see
    /// `docs/calendar-invites.md`) — i.e. that the MIME-parsing layer was
    /// never actually the bug; `CalendarInviteAttachmentMatching`'s
    /// `OtegamiCoreTests` coverage is what actually needed fixing.
    @Test("BodyFetcher discovers a text/calendar part nested inside multipart/alternative, alongside a separate invite.ics attachment")
    func discoversTextCalendarNestedInsideAlternative() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let database = try AppDatabase.makeInMemory()

        let account = AccountRecord(
            displayName: "Integration", email: "test1@otegami.test", authType: .password,
            imapHost: env.host, imapPort: env.port,
            imapSecurity: ConnectionSecurityRecord(env.imapConfig.security),
            imapAllowsInsecureTLS: env.imapConfig.allowsInsecureTLS,
            imapUsername: "test1@otegami.test"
        )
        try await database.dbWriter.write { db in try account.insert(db) }
        defer { cleanUp(accountId: account.id) }

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }
        _ = try await session.select("INBOX")

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let envelope = try #require(envelopes.first { $0.messageId == "<seed-0037@otegami.test>" })

        let messageId = try await database.dbWriter.write { db -> Int64 in
            var mailbox = MailboxRecord(accountId: account.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
            mailbox = try mailbox.upsertAndFetch(db, onConflict: ["accountId", "path"])
            var message = MessageRecord(
                mailboxId: mailbox.id!, uid: Int64(envelope.uid), subject: envelope.subject,
                internalDate: envelope.internalDate
            )
            try message.insert(db)
            return message.id!
        }
        let message = try await database.dbWriter.read { db in try MessageRecord.fetchOne(db, key: messageId)! }

        try await BodyFetcher(database: database).fetchBody(message: message, mailboxPath: "INBOX", session: session)

        let attachments = try await database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).fetchAll(db)
        }

        // Exactly two non-inline parts: the nested, unnamed text/calendar
        // representation and the separately named invite.ics — matching the
        // real-device report's "添付ファイル (名前なし)" + "invite.ics" pair.
        let calendarPart = try #require(attachments.first { $0.mimeType == "text" && $0.mimeSubtype == "calendar" })
        #expect(calendarPart.filename == nil)
        let icsAttachment = try #require(attachments.first { ($0.filename ?? "").lowercased() == "invite.ics" })
        #expect(icsAttachment.mimeType == "application")

        // `CalendarInviteAttachmentMatching` (the actual fix, Task #84):
        // both parts are recognized as invite parts, and the text/calendar
        // one is picked to drive the card.
        for attachment in attachments {
            #expect(CalendarInviteAttachmentMatching.isInvitePart(
                mimeType: attachment.mimeType, mimeSubtype: attachment.mimeSubtype, filename: attachment.filename
            ))
        }
        let primary = CalendarInviteAttachmentMatching.primaryInvitePart(
            among: attachments, mimeType: { $0.mimeType }, mimeSubtype: { $0.mimeSubtype }, filename: { $0.filename }
        )
        #expect(primary?.id == calendarPart.id)

        let downloaded = try await AttachmentFetcher(database: database).fetchAndStore(
            attachment: calendarPart, accountId: account.id, messageUID: message.uid,
            mailboxPath: "INBOX", session: session
        )
        let localPath = try #require(downloaded.localPath)
        let icsData = try Data(contentsOf: URL(fileURLWithPath: localPath))
        let icsText = String(decoding: icsData, as: UTF8.self)

        let invite = try #require(ICSCalendarParser.parse(icsText))
        #expect(invite.uid == "seed-0037-event@otegami.test")
        #expect(invite.method == "REQUEST")
        #expect(invite.summary == "週次同期 (Weekly Sync)")
        #expect(invite.organizer?.address == "organizer2@otegami.test")
    }
}
