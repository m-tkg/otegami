import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport

/// Task #193 (実機バグ「10年以上前に送った送信済みメールが、6時間前くらいの
/// 日付で受信箱に表示される」): confirms the mailcore2-side root cause
/// against the *real* dev mailstack Dovecot — not a constructed
/// `MCOIMAPMessage` (`EnvelopeSentinelDateMappingTests`) or an in-memory DB
/// scenario (`SentinelDateThreadRepairTests`), but an actual message with no
/// `Date:` header, actually `FETCH`ed over the wire, actually parsed by the
/// real pinned mailcore2 revision.
///
/// Opt-in like the rest of this target: skipped unless
/// `OTEGAMI_TEST_IMAP_HOST` is set. Run with:
///
/// ```sh
/// make mailstack-up
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter EnvelopeDateSentinelIntegrationTests
/// make mailstack-down
/// ```
@Suite(
    "EnvelopeDateSentinel against a real Date:-less message (dev mailstack)",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run"),
    .serialized
)
struct EnvelopeDateSentinelIntegrationTests {
    @Test("a real message with no Date: header fetches with date == nil, and a real INTERNALDATE years in the past intact")
    func dateLessMessageFallsBackToInternalDate() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"

        defer { try? DoveadmHelper.restoreStandardFixtures() }

        try DoveadmHelper.expungeAll(user: user)

        // No `Date:` line at all — the real-world shape the task's root
        // cause investigation describes (an old Sent message from a client/
        // era that either never wrote one, or the header got stripped/
        // corrupted somewhere along the way). `-r` pins Dovecot's own
        // server-assigned `INTERNALDATE` to a decade ago, standing in for
        // "really appended to this mailbox 10 years ago" — without it, a
        // message `doveadm save`d *right now* would legitimately get a
        // *current* `INTERNALDATE` too, which can't exercise
        // `EnvelopeDateSentinel`'s "date is close to fetch time, but
        // internalDate disagrees" check (both would agree it's "now",
        // correctly not flagging it — see `DoveadmHelper.save`'s doc
        // comment on `receivedDate`).
        let tenYearsAgo = Calendar(identifier: .gregorian).date(byAdding: .year, value: -10, to: Date())!
        try DoveadmHelper.save(
            user: user,
            content: "From: Aiko <aiko@otegami.test>\r\n"
                + "To: test1@otegami.test\r\n"
                + "Subject: sentinel repro: no Date header\r\n"
                + "Message-Id: <sentinel-repro-nodate@otegami.test>\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n"
                + "\r\n"
                + "Body.\r\n",
            receivedDate: tenYearsAgo
        )

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let repro = try #require(envelopes.first { $0.messageId == "<sentinel-repro-nodate@otegami.test>" })

        // The fix: MailCore2's own construction-time "now" stamp (what
        // `repro.date` would have been, verbatim, before Task #193) never
        // reaches this app's model — `EnvelopeDateSentinel` catches it and
        // this comes back `nil`, matching this codebase's existing "no
        // `Date:` header at all" convention (readers fall back to
        // `internalDate` via `date ?? internalDate`).
        #expect(repro.date == nil)

        // `internalDate` (real IMAP INTERNALDATE) survives untouched — the
        // decade-old value this test pinned via `doveadm save -r`, not
        // "just now".
        #expect(abs(repro.internalDate.timeIntervalSince(tenYearsAgo)) < 60)
    }

    @Test("a real message with a genuinely current Date: header keeps it, even though it's also close to fetch time")
    func genuinelyCurrentDateIsKept() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let user = "test1@otegami.test"

        defer { try? DoveadmHelper.restoreStandardFixtures() }

        try DoveadmHelper.expungeAll(user: user)

        // A real `Date:` header this time, genuinely close to "now" — the
        // case `EnvelopeDateSentinel` must *not* flag (its own doc comment:
        // a genuinely fresh message's `internalDate` agrees with `date`
        // too, so the two-condition check correctly leaves it alone).
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        try DoveadmHelper.save(
            user: user,
            content: "From: Aiko <aiko@otegami.test>\r\n"
                + "To: test1@otegami.test\r\n"
                + "Subject: sentinel repro: genuine current Date header\r\n"
                + "Message-Id: <sentinel-repro-currentdate@otegami.test>\r\n"
                + "Date: \(formatter.string(from: now))\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n"
                + "\r\n"
                + "Body.\r\n"
        )

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let repro = try #require(envelopes.first { $0.messageId == "<sentinel-repro-currentdate@otegami.test>" })

        let date = try #require(repro.date)
        #expect(abs(date.timeIntervalSince(now)) < 60)
    }
}
