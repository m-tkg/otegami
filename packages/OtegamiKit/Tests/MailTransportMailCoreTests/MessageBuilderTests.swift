import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// Unit tests for `MailCoreMessageBuilder` (M5). Unlike
/// `MailCoreIMAPSessionIntegrationTests`/`SyncEngineIntegrationTests` in
/// this same target, these need no dev mailstack — building an RFC 822
/// message and re-parsing it is entirely local — so they run unconditionally
/// as part of a plain `swift test` (and `make test`/CI), not gated behind
/// `OTEGAMI_TEST_IMAP_HOST`.
// `.serialized`: M8 added several attachment tests that construct
// `MCOAttachment`/`MCOMessageParser` instances alongside the pre-existing
// ones — running this suite's tests concurrently (Swift Testing's default)
// intermittently corrupted `MCOMessageParser.plainTextBodyRendering()`'s
// output on an unrelated test (confirmed empirically: reproducible with
// this suite's current test count under parallel execution, never under
// `swift test --no-parallel`, and never with the smaller pre-M8 test
// count) — a MailCore2-internal thread-safety limitation this suite has
// apparently been right at the edge of since M5, not a bug in any
// individual test. Forcing this one suite serial (not the whole `swift
// test` run) is the narrowest fix.
@Suite("MailCoreMessageBuilder", .serialized)
struct MessageBuilderTests {
    private let sender = EmailAddress(name: "Aiko", address: "aiko@otegami.test")
    private let recipient = EmailAddress(name: "Bob", address: "bob@otegami.test")

    @Test("a new (non-reply) draft has no In-Reply-To/References and a generated Message-ID")
    func newMessageHasNoReplyHeaders() throws {
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "Hello", plainTextBody: "Hi there."
        )
        let built = MailCoreMessageBuilder.build(draft)
        let header = MCOMessageHeader(data: built.data)

        #expect(header.subject == "Hello")
        // `MCOMessageHeader` strips the RFC 5322 angle brackets on read,
        // same as `MailCoreIMAPSession+Mapping`'s envelope parsing does for
        // received messages — `built.messageId` (what was actually written
        // to the `Message-ID:` header on the wire) keeps them.
        #expect(built.messageId == "<\(header.messageID ?? "")>")
        #expect((header.inReplyTo ?? []).isEmpty)
        #expect((header.references ?? []).isEmpty)
        #expect(header.from?.mailbox == "aiko@otegami.test")
        #expect(mailboxes(header.to).first == "bob@otegami.test")
    }

    @Test("a reply appends the original Message-ID to its own References, preserving the original's own References")
    func replyReferencesChainAppendsOriginalMessageId() throws {
        let originalMessageId = "<seed-0002@otegami.test>"
        let priorReferences = ["<seed-0001@otegami.test>"]
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "Re: 明日の打ち合わせについて",
            plainTextBody: "> quoted\n\nOK, see you then.",
            inReplyTo: originalMessageId,
            references: priorReferences + [originalMessageId]
        )
        let built = MailCoreMessageBuilder.build(draft)
        let header = MCOMessageHeader(data: built.data)

        // Angle brackets stripped on read — see the doc comment above.
        #expect(header.inReplyTo == ["seed-0002@otegami.test"])
        #expect(header.references == ["seed-0001@otegami.test", "seed-0002@otegami.test"])
    }

    @Test("building the same subject text twice with a leading Re: doesn't get a second Re: prepended by the builder itself")
    func subjectIsWrittenVerbatimNoDoublePrefixing() throws {
        // MailCoreMessageBuilder itself never touches the subject text —
        // "no Re: Re:" is the Composer's job (SubjectNormalizer, exercised
        // separately in OtegamiCoreTests) before a ComposeDraft is even
        // built. This test only pins down that the builder passes the
        // subject through unmodified, so that upstream guarantee actually
        // survives all the way into the rendered RFC 822 bytes.
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "Re: 明日の打ち合わせについて",
            plainTextBody: "OK"
        )
        let built = MailCoreMessageBuilder.build(draft)
        let header = MCOMessageHeader(data: built.data)
        #expect(header.subject == "Re: 明日の打ち合わせについて")
    }

    @Test("Japanese subject and body round-trip through the RFC 822 encoding")
    func japaneseSubjectAndBodyRoundTrip() throws {
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "日本語の件名テスト",
            plainTextBody: "こんにちは、これは日本語の本文です。\n改行も含みます。"
        )
        let built = MailCoreMessageBuilder.build(draft)

        let header = MCOMessageHeader(data: built.data)
        #expect(header.subject == "日本語の件名テスト")

        let parser = MCOMessageParser(data: built.data)
        let renderedBody = try #require(parser.plainTextBodyRendering())
        #expect(renderedBody.contains("こんにちは、これは日本語の本文です。"))
    }

    @Test("cc and bcc addresses are included in the built headers when present")
    func ccAndBccAreIncludedWhenPresent() throws {
        let cc = EmailAddress(address: "cc@otegami.test")
        let bcc = EmailAddress(address: "bcc@otegami.test")
        let draft = ComposeDraft(
            from: sender, to: [recipient], cc: [cc], bcc: [bcc],
            subject: "With cc/bcc", plainTextBody: "body"
        )
        let built = MailCoreMessageBuilder.build(draft)
        let header = MCOMessageHeader(data: built.data)

        #expect(mailboxes(header.cc) == ["cc@otegami.test"])
        #expect(mailboxes(header.bcc) == ["bcc@otegami.test"])
    }

    @Test("each build generates a distinct Message-ID")
    func eachBuildGeneratesADistinctMessageId() {
        let draft = ComposeDraft(from: sender, to: [recipient], subject: "A", plainTextBody: "A")
        let first = MailCoreMessageBuilder.build(draft)
        let second = MailCoreMessageBuilder.build(draft)
        #expect(first.messageId != second.messageId)
    }

    // MARK: - M8: attachments

    @Test("an attachment round-trips filename, MIME type, and bytes through RFC 822 encoding")
    func attachmentRoundTrips() throws {
        let payload = Data("%PDF-1.4 fake pdf content".utf8)
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "Invoice attached", plainTextBody: "See attached.",
            attachments: [ComposeAttachment(filename: "invoice.pdf", mimeType: "application/pdf", data: payload)]
        )
        let built = MailCoreMessageBuilder.build(draft)

        let parser = MCOMessageParser(data: built.data)
        let attachments = try #require(parser.attachments())
        #expect(attachments.count == 1)
        let attachment = try #require(attachments.first as? MCOAttachment)
        #expect(attachment.filename == "invoice.pdf")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.data == payload)
    }

    @Test("a Japanese filename round-trips through RFC 2231/2047 encoding")
    func japaneseFilenameRoundTrips() throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes, arbitrary content
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "写真です", plainTextBody: "添付をご確認ください。",
            attachments: [ComposeAttachment(filename: "請求書.pdf", mimeType: "application/pdf", data: payload)]
        )
        let built = MailCoreMessageBuilder.build(draft)

        let parser = MCOMessageParser(data: built.data)
        let attachments = try #require(parser.attachments())
        let attachment = try #require(attachments.first as? MCOAttachment)
        #expect(attachment.filename == "請求書.pdf")
        #expect(attachment.data == payload)
    }

    @Test("multiple attachments all round-trip independently")
    func multipleAttachmentsRoundTrip() throws {
        let draft = ComposeDraft(
            from: sender, to: [recipient],
            subject: "Two files", plainTextBody: "body",
            attachments: [
                ComposeAttachment(filename: "one.txt", mimeType: "text/plain", data: Data("one".utf8)),
                ComposeAttachment(filename: "two.png", mimeType: "image/png", data: Data([0x01, 0x02])),
            ]
        )
        let built = MailCoreMessageBuilder.build(draft)

        let parser = MCOMessageParser(data: built.data)
        let attachments = try #require(parser.attachments())
        #expect(attachments.count == 2)
        let filenames = Set(attachments.compactMap { ($0 as? MCOAttachment)?.filename })
        #expect(filenames == ["one.txt", "two.png"])
    }

    @Test("no attachments produces a message with none, not an empty list that still confuses a client")
    func noAttachmentsMeansNoAttachmentParts() throws {
        let draft = ComposeDraft(from: sender, to: [recipient], subject: "Plain", plainTextBody: "body")
        let built = MailCoreMessageBuilder.build(draft)
        let parser = MCOMessageParser(data: built.data)
        #expect((parser.attachments() ?? []).isEmpty)
    }

    /// `MCOMessageHeader.to`/`.cc`/`.bcc` are declared as bare `NSArray *`
    /// (the `MCOAddress` element type is only documented in a comment, not
    /// expressed via Objective-C lightweight generics), so the Swift
    /// importer bridges them as `[Any]!` rather than `[MCOAddress]` —
    /// this downcasts and extracts `mailbox` defensively rather than
    /// assuming a typed array.
    private func mailboxes(_ addresses: [Any]?) -> [String] {
        (addresses ?? []).compactMap { ($0 as? MCOAddress)?.mailbox }
    }
}
