import Foundation
import Testing
@testable import MailTransportMailCore
import MailTransport

/// Integration tests against a real IMAP server — the dev mailstack's
/// Dovecot (`dev/mailstack`) by default, seeded via `make mailstack-seed`
/// (see `dev/mailstack/seed/fixtures/*.eml`).
///
/// Opt-in: skipped (not failed) unless `OTEGAMI_TEST_IMAP_HOST` is set, so a
/// plain `swift test` never requires a running mail server. To run:
///
/// ```sh
/// make mailstack-up
/// make mailstack-seed
/// OTEGAMI_TEST_IMAP_HOST=localhost swift test --filter MailCoreIMAPSessionIntegrationTests
/// make mailstack-down
/// ```
///
/// All connection details are overridable via environment variables so the
/// same suite can point at IMAPS (port 1993, self-signed cert) or a
/// non-default host/port; see `TestIMAPEnvironment` for the full list.
@Suite(
    "MailCoreIMAPSession against dev mailstack",
    .enabled(if: TestIMAPEnvironment.primary != nil, "set OTEGAMI_TEST_IMAP_HOST to run")
)
struct MailCoreIMAPSessionIntegrationTests {
    @Test("lists INBOX, selects it, and fetches test1's seeded envelopes")
    func test1InboxEnvelopes() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        let mailboxes = try await session.listMailboxes()
        #expect(mailboxes.contains { $0.path.caseInsensitiveCompare("INBOX") == .orderedSame })

        let status = try await session.select("INBOX")
        // `>=` rather than `==`: `make mailstack-seed` is not idempotent
        // (each run re-`doveadm save`s the fixtures), so a mailstack that's
        // been seeded more than once legitimately has extra copies. The
        // fixed set of seed subjects/headers below is what this test
        // actually cares about.
        #expect(status.messageCount >= 4)

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        #expect(envelopes.count >= 4)

        let subjects = Set(envelopes.compactMap(\.subject))
        #expect(subjects.contains("ようこそ otegami へ"))
        #expect(subjects.contains("明日の打ち合わせについて"))
        #expect(subjects.contains("Re: 明日の打ち合わせについて"))
        #expect(subjects.contains("Ｆｗｄ：今月のリリースノート"))

        let reply = try #require(envelopes.first { $0.subject == "Re: 明日の打ち合わせについて" })
        #expect(reply.inReplyTo == "<seed-0002@otegami.test>")
        #expect(reply.references == ["<seed-0002@otegami.test>"])
        #expect(reply.messageId == "<seed-0003@otegami.test>")

        let original = try #require(envelopes.first { $0.subject == "明日の打ち合わせについて" })
        #expect(original.messageId == "<seed-0002@otegami.test>")
        #expect(original.from.first?.address == "aiko@otegami.test")
    }

    @Test("fetches test2's seeded envelope")
    func test2InboxEnvelopes() async throws {
        let env = try #require(TestIMAPEnvironment.secondary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)

        #expect(envelopes.count >= 1)
        let welcome = try #require(envelopes.first { $0.messageId == "<seed-0005@otegami.test>" })
        #expect(welcome.subject == "test2 アカウントへようこそ")
    }

    @Test("fetches and parses the HTML-only Japanese seed message's body")
    func fetchesHTMLOnlyJapaneseBody() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0007@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        #expect(body.html?.contains("こんにちは、otegami です。") == true)
        // 07-html-only-japanese.eml has no text/plain part at all — MailCore2
        // either synthesizes a plain-text rendering from the HTML itself, or
        // returns nil and leaves the HTML→text fallback to `SyncEngine
        // .BodyFetcher`; either way this integration test only needs to
        // confirm the HTML itself decoded correctly (asserted above).
    }

    @Test("fetches and parses the external-image HTML seed message's body")
    func fetchesExternalImageHTMLBody() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0006@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        #expect(body.plainText?.contains("otegami の新機能") == true)
        #expect(body.html?.contains("http://example.com/banner.png") == true)
    }

    // MARK: M8 — attachment data fetch

    private static let expectedPNGBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAH0lEQVR42mN4USVHFcQwatCoQaMGjRo0atCoQQNvEAD6qmAurCoQRgAAAABJRU5ErkJggg==")!

    @Test("fetches a PNG attachment's raw bytes by partId, matching the fixture byte-for-byte")
    func fetchesPNGAttachmentData() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0014@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        let attachmentPart = try #require(body.parts.first { $0.filename == "logo.png" })
        #expect(attachmentPart.isAttachment)
        #expect(attachmentPart.mimeType == "image")
        #expect(attachmentPart.mimeSubtype == "png")

        let data = try await session.fetchMessageBody(mailboxPath: "INBOX", uid: message.uid, partId: attachmentPart.partId)
        #expect(data == Self.expectedPNGBytes)
    }

    @Test("fetches a Japanese-filename PDF attachment's bytes, with the filename decoded correctly")
    func fetchesJapaneseFilenamePDFAttachmentData() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0015@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        let attachmentPart = try #require(body.parts.first { $0.filename == "請求書.pdf" })
        #expect(attachmentPart.mimeType == "application")
        #expect(attachmentPart.mimeSubtype == "pdf")

        let data = try await session.fetchMessageBody(mailboxPath: "INBOX", uid: message.uid, partId: attachmentPart.partId)
        #expect(data.starts(with: Data("%PDF-1.4".utf8)))
        #expect(!data.isEmpty)
    }

    @Test("fetches an RFC-2231-only-filename PDF attachment's bytes, with the filename decoded via the raw-scan fallback")
    func fetchesRFC2231OnlyFilenamePDFAttachmentData() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0019@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        // 19-attachment-rfc2231-japanese.eml's Content-Disposition uses only
        // RFC 2231's filename*0*=/filename*1*= continuation form (no RFC
        // 2047 encoded-word at all), which the pinned mailcore2 revision's
        // own parser leaves as `filename == nil` — this asserts
        // `MailCoreIMAPSession.fetchBody`'s raw-scan fallback
        // (`docs/roadmap.md`) recovers the correct decoded filename against
        // a real Dovecot round trip, not just the OtegamiCoreTests unit
        // coverage of the decoder itself.
        let attachmentPart = try #require(body.parts.first { $0.filename == "領収書.pdf" })
        #expect(attachmentPart.isAttachment)
        #expect(attachmentPart.mimeType == "application")
        #expect(attachmentPart.mimeSubtype == "pdf")

        let data = try await session.fetchMessageBody(mailboxPath: "INBOX", uid: message.uid, partId: attachmentPart.partId)
        #expect(data.starts(with: Data("%PDF-1.4".utf8)))
        #expect(!data.isEmpty)
    }

    @Test("the cid inline-image seed message's part is detected as inline with a matching contentId")
    func detectsCIDInlineImage() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        _ = try await session.select("INBOX")
        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .all, batchSize: 50)
        let message = try #require(envelopes.first { $0.messageId == "<seed-0016@otegami.test>" })

        let body = try await session.fetchBody(mailboxPath: "INBOX", uid: message.uid)
        #expect(body.html?.contains(#"src="cid:otegami-logo@otegami.test""#) == true)

        let inlinePart = try #require(body.parts.first { $0.contentId == "otegami-logo@otegami.test" })
        #expect(!inlinePart.isAttachment)

        let data = try await session.fetchMessageBody(mailboxPath: "INBOX", uid: message.uid, partId: inlinePart.partId)
        #expect(data == Self.expectedPNGBytes)
    }

    @Test("lists a Japanese-named mailbox with a correctly decoded displayPath")
    func listsJapaneseNamedMailboxDecoded() async throws {
        let env = try #require(TestIMAPEnvironment.primary)

        // `doveadm mailbox create` takes the mailbox name as plain UTF-8 on
        // the command line and is responsible for whatever on-disk/on-wire
        // encoding Dovecot uses internally — this test doesn't pre-encode
        // anything, so a correctly-decoded `displayPath` here demonstrates
        // the full round trip: Dovecot encodes "テスト用フォルダ" to
        // modified UTF-7 for the real `LIST` response, and
        // `MailCoreIMAPSession.listMailboxes()` (via `ModifiedUTF7.decode`
        // in `mailboxInfo(from:)`) decodes it back — not just that this
        // decoder agrees with itself on a hand-picked fixture (see
        // `OtegamiCoreTests.ModifiedUTF7Tests` for those).
        let mailboxName = "テスト用フォルダ"
        try DoveadmHelper.createMailbox(user: env.username, mailboxPath: mailboxName)
        defer { try? DoveadmHelper.deleteMailbox(user: env.username, mailboxPath: mailboxName) }

        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        let mailboxes = try await session.listMailboxes()
        let mailbox = try #require(mailboxes.first { $0.displayPath == mailboxName })
        // The raw `path` is whatever modified-UTF-7 Dovecot actually put on
        // the wire — asserting it's neither empty nor already equal to the
        // decoded name confirms this fixture is exercising the encode/
        // decode round trip rather than accidentally matching a mailbox
        // whose name happened to be pure ASCII.
        #expect(!mailbox.path.isEmpty)
        #expect(mailbox.path != mailboxName)
    }

    @Test("reports server capabilities without throwing")
    func capabilities() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        // Not asserting a specific capability set: Dovecot's advertised
        // capabilities are an implementation detail this test shouldn't be
        // coupled to. Successfully bridging MCOIndexSet → Set<IMAPCapability>
        // without throwing is what's under test.
        _ = try await session.capabilities()
    }

    /// Empirical confirmation, against a real Dovecot rather than
    /// `FakeIMAPSession`, of the two assumptions `BodyFetcher
    /// .attemptSelfHeal` (実機報告「MailCoreErrorDomain error 19」の自己修復) is
    /// built on: (1) `UID FETCH` for a UID the mailbox has never had throws
    /// — Dovecot answers `NO`, which `mapError` has no specific `MailCoreError`
    /// case for and so falls through to `.serverError`, exactly the shape
    /// the real-device error report's "error 19" surfaces as; (2) `UID FETCH`
    /// of *envelopes* (`fetchEnvelopes`, `BodyFetcher`'s existence-check
    /// substitute for a real `UID SEARCH`) for that same nonexistent UID does
    /// *not* throw at all — it simply returns no results, the same "came
    /// back successfully, just empty" shape `attemptSelfHeal` relies on to
    /// tell "confirmed gone" apart from "the check itself failed".
    @Test("fetching a UID the mailbox never had fails the body fetch but not the envelope existence check")
    func fetchingANonexistentUIDFailsBodyButNotEnvelopeExistenceCheck() async throws {
        let env = try #require(TestIMAPEnvironment.primary)
        let session = MailCoreIMAPSession(config: env.imapConfig)
        try await session.connect(auth: env.auth)
        defer { Task { await session.disconnect() } }

        let status = try await session.select("INBOX")
        // One past the mailbox's `uidNext` is guaranteed to have never been
        // assigned to any message this mailbox has ever held.
        let neverAssignedUID = UInt32(status.uidNext) + 10_000

        let envelopes = try await session.fetchEnvelopes(mailboxPath: "INBOX", uids: .uid(neverAssignedUID), batchSize: 1)
        #expect(envelopes.isEmpty)

        do {
            _ = try await session.fetchBody(mailboxPath: "INBOX", uid: neverAssignedUID)
            Issue.record("expected fetchBody to throw for a UID this mailbox never had")
        } catch let error as MailTransportError {
            guard case .serverError = error else {
                Issue.record("expected .serverError (the MailCoreErrorDomain error 19 shape), got \(error)")
                return
            }
        }
    }
}

/// Connection details for the dev mailstack (or another IMAP server),
/// sourced from environment variables so CI/local runs can opt in without
/// code changes. Defaults match `dev/mailstack`'s seeded accounts
/// (`docs/dev-mailstack.md`).
struct TestIMAPEnvironment {
    var host: String
    var port: Int
    var security: MailConnectionSecurity
    var allowsInsecureTLS: Bool
    var username: String
    var password: String

    var imapConfig: IMAPConfig {
        IMAPConfig(host: host, port: port, security: security, allowsInsecureTLS: allowsInsecureTLS)
    }

    var auth: MailAuth {
        .password(username: username, password: password)
    }

    private static let environment = ProcessInfo.processInfo.environment

    /// `nil` (suite skipped) unless `OTEGAMI_TEST_IMAP_HOST` is set.
    static var primary: TestIMAPEnvironment? {
        make(userKey: "OTEGAMI_TEST_IMAP_USER", userDefault: "test1@otegami.test",
             passwordKey: "OTEGAMI_TEST_IMAP_PASSWORD", passwordDefault: "test1234")
    }

    /// The dev mailstack's second seeded account, for multi-account
    /// coverage. Also `nil` unless `OTEGAMI_TEST_IMAP_HOST` is set.
    static var secondary: TestIMAPEnvironment? {
        make(userKey: "OTEGAMI_TEST_IMAP_USER2", userDefault: "test2@otegami.test",
             passwordKey: "OTEGAMI_TEST_IMAP_PASSWORD2", passwordDefault: "test1234")
    }

    private static func make(
        userKey: String, userDefault: String,
        passwordKey: String, passwordDefault: String
    ) -> TestIMAPEnvironment? {
        guard let host = environment["OTEGAMI_TEST_IMAP_HOST"] else { return nil }

        let useTLS = environment["OTEGAMI_TEST_IMAP_TLS"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
        let defaultPort = useTLS ? 1993 : 1143
        let port = environment["OTEGAMI_TEST_IMAP_PORT"].flatMap(Int.init) ?? defaultPort

        return TestIMAPEnvironment(
            host: host,
            port: port,
            // The dev mailstack's IMAPS listener uses a self-signed
            // certificate; only relax certificate checking for it, never
            // silently for a real account.
            security: useTLS ? .tls : .plain,
            allowsInsecureTLS: useTLS,
            username: environment[userKey] ?? userDefault,
            password: environment[passwordKey] ?? passwordDefault
        )
    }
}
