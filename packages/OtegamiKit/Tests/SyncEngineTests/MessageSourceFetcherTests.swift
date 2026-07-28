import Foundation
import Testing
import MailTransport
@testable import SyncEngine

@Suite("MessageSourceFetcher")
struct MessageSourceFetcherTests {
    /// Cleans up whatever `MessageSourceFetcher.storageURL` created for
    /// `accountId`, so a test run doesn't leave files behind on the host —
    /// same rationale as `AttachmentFetcherTests.cleanUp(accountId:)`
    /// (there's no in-memory filesystem equivalent to `AppDatabase
    /// .makeInMemory()` to isolate this the way DB state is isolated).
    private func cleanUp(accountId: String) {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let dir = base.appendingPathComponent("otegami/MessageSource/\(accountId)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// M8's `attachmentDataByPath` scripts `fetchMessageBody(mailboxPath:
    /// uid:partId:)` results, keyed `[mailboxPath: [uid: [partId ?? "": Data]]]`
    /// — `MessageSourceFetcher` always requests `partId: nil` (the whole
    /// raw message, per `IMAPSessionProtocol.fetchMessageBody`'s own doc
    /// comment), which `FakeIMAPSession.fetchMessageBody` looks up under
    /// the empty-string key.
    private func rawSourceScript(mailboxPath: String, uid: UInt32, data: Data) -> FakeIMAPSession.Script {
        FakeIMAPSession.Script(attachmentDataByPath: [mailboxPath: [uid: ["": data]]])
    }

    @Test("downloads and persists a message's raw RFC822 source")
    func fetchesAndPersists() async throws {
        let accountId = "account-\(UUID().uuidString)"
        defer { cleanUp(accountId: accountId) }

        let payload = Data("Subject: hello\r\n\r\nbody text".utf8)
        let script = rawSourceScript(mailboxPath: "INBOX", uid: 42, data: payload)
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = MessageSourceFetcher()
        let url = try await fetcher.fetchAndStore(
            messageId: 1, accountId: accountId, messageUID: 42, mailboxPath: "INBOX", session: session
        )

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == payload)
        #expect(url.lastPathComponent == "1.eml")
    }

    @Test("already-downloaded source (cached file exists on disk) is returned without touching the network")
    func skipsNetworkWhenAlreadyCached() async throws {
        let accountId = "account-\(UUID().uuidString)"
        defer { cleanUp(accountId: accountId) }

        let existingURL = try MessageSourceFetcher.storageURL(accountId: accountId, messageId: 7)
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingPayload = Data("already cached".utf8)
        try existingPayload.write(to: existingURL)

        // No scripted attachment data at all — a network fetch would throw.
        let script = FakeIMAPSession.Script()
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)

        let fetcher = MessageSourceFetcher()
        let url = try await fetcher.fetchAndStore(
            messageId: 7, accountId: accountId, messageUID: 99, mailboxPath: "INBOX", session: session
        )

        #expect(url == existingURL)
        #expect(try Data(contentsOf: url) == existingPayload)
    }

    @Test("cachedURL reports nil until fetchAndStore has run, then the cached path afterward")
    func cachedURLReflectsFetchState() async throws {
        let accountId = "account-\(UUID().uuidString)"
        defer { cleanUp(accountId: accountId) }

        #expect(MessageSourceFetcher.cachedURL(accountId: accountId, messageId: 3) == nil)

        let payload = Data("raw source bytes".utf8)
        let script = rawSourceScript(mailboxPath: "INBOX", uid: 3, data: payload)
        let session = FakeIMAPSession(config: IMAPConfig(host: "localhost", port: 1143, security: .plain), script: script)
        _ = try await MessageSourceFetcher().fetchAndStore(
            messageId: 3, accountId: accountId, messageUID: 3, mailboxPath: "INBOX", session: session
        )

        let cached = MessageSourceFetcher.cachedURL(accountId: accountId, messageId: 3)
        #expect(cached != nil)
        #expect(try cached.map { try Data(contentsOf: $0) } == payload)
    }
}
