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
}
