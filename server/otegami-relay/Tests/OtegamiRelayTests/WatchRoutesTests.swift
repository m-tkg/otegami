import Foundation
import Hummingbird
import HummingbirdTesting
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

@Suite("POST /v1/watches, DELETE /v1/watches/:id")
struct WatchRoutesTests {
    private func registerDevice(client: some TestClientProtocol) async throws -> RegisterDeviceResponse {
        let body = try JSONEncoder().encode(RegisterDeviceRequest(apnsToken: "tok", environment: .sandbox))
        var result: RegisterDeviceResponse!
        try await client.execute(uri: "/v1/devices", method: .post, body: ByteBuffer(data: body)) { response in
            result = try JSONDecoder().decode(RegisterDeviceResponse.self, from: response.body)
        }
        return result
    }

    @Test("create a watch, then delete it — the record is gone from the store")
    func createThenDelete() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)

                let watchRequest = CreateWatchRequest(
                    accountId: "account-1",
                    // TEST-NET-3 (RFC 5737) — a literal, documentation-only public IP so
                    // `RelayNetworkPolicy.strict`'s host check passes without a real DNS
                    // lookup (avoids CI network flakiness) while still exercising the
                    // "allowed" path.
                    imapHost: "203.0.113.10",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "app-password"),
                    mailbox: "INBOX"
                )
                let watchBody = try JSONEncoder().encode(watchRequest)

                var watchId = ""
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .created)
                    let decoded = try TestSupport.jsonDecoder.decode(WatchResponse.self, from: response.body)
                    #expect(decoded.accountId == "account-1")
                    #expect(decoded.mailbox == "INBOX")
                    watchId = decoded.watchId
                }

                #expect(try await store.listWatches().count == 1)

                try await client.execute(
                    uri: "/v1/watches/\(watchId)",
                    method: .delete,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"]
                ) { response in
                    #expect(response.status == .noContent)
                }

                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("creating a watch without a valid bearer secret is rejected, and nothing is persisted")
    func createWatchRequiresAuth() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        // TEST-NET-3 (RFC 5737) — see `createThenDelete`'s comment.
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer not-a-real-secret"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .unauthorized)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("one device can't delete another device's watch")
    func deleteIsScopedToOwningDevice() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let owner = try await registerDevice(client: client)
                let intruder = try await registerDevice(client: client)

                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        // TEST-NET-3 (RFC 5737) — see `createThenDelete`'s comment.
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                var watchId = ""
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(owner.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    let decoded = try TestSupport.jsonDecoder.decode(WatchResponse.self, from: response.body)
                    watchId = decoded.watchId
                }

                try await client.execute(
                    uri: "/v1/watches/\(watchId)",
                    method: .delete,
                    headers: [.authorization: "Bearer \(intruder.deviceSecret)"]
                ) { response in
                    #expect(response.status == .notFound)
                }

                #expect(try await store.listWatches().count == 1)
                // Cleanup: `owner`'s watch is still live in `watcherPool`
                // (only its own owner could delete it, which this test
                // deliberately never does) — stop its background IMAP
                // reconnect loop rather than leaving it running for the
                // rest of the test process's lifetime.
                await watcherPool.removeWatch(id: watchId)
            }
        }
    }

    @Test("GET /v1/watches returns only this device's watches, credential-free")
    func listWatchesIsScopedAndCredentialFree() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let owner = try await registerDevice(client: client)
                let other = try await registerDevice(client: client)

                let ownerWatchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "owner-account",
                        // TEST-NET-3 (RFC 5737) — see `createThenDelete`'s comment.
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(owner.deviceSecret)"],
                    body: ByteBuffer(data: ownerWatchBody)
                ) { response in
                    #expect(response.status == .created)
                }

                let otherWatchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "other-account",
                        // TEST-NET-3 (RFC 5737) — see `createThenDelete`'s comment.
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user2@example.com",
                        auth: WatchAuth(secret: "app-password-2")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(other.deviceSecret)"],
                    body: ByteBuffer(data: otherWatchBody)
                ) { response in
                    #expect(response.status == .created)
                }

                try await client.execute(
                    uri: "/v1/watches",
                    method: .get,
                    headers: [.authorization: "Bearer \(owner.deviceSecret)"]
                ) { response in
                    #expect(response.status == .ok)
                    let decoded = try TestSupport.jsonDecoder.decode(ListWatchesResponse.self, from: response.body)
                    #expect(decoded.watches.count == 1)
                    #expect(decoded.watches[0].accountId == "owner-account")
                    #expect(decoded.watches[0].imapHost == "203.0.113.10")
                    // Never echoes the credential back.
                    #expect(String(buffer: response.body).contains("app-password") == false)
                }
            }
        }
    }

    @Test("GET /v1/watches reflects a stopped watch's status/lastErrorKind (Task #173)")
    func listWatchesReflectsStoppedStatus() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        // TEST-NET-3 (RFC 5737) — see `createThenDelete`'s comment.
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                var watchId = ""
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    let decoded = try TestSupport.jsonDecoder.decode(WatchResponse.self, from: response.body)
                    watchId = decoded.watchId
                }
                // `WatcherPool` normally drives this transition (Task #173's
                // `WatcherPoolTests.repeatedLoginFailuresStopTheWatchAndPersistStatus`
                // covers that end-to-end) — here it's driven directly so
                // this test only exercises the route/serialization, not
                // real IMAP timing.
                try await store.recordWatchError(id: watchId, kind: .authFailure, stopping: true)
                await watcherPool.removeWatch(id: watchId)

                try await client.execute(
                    uri: "/v1/watches",
                    method: .get,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"]
                ) { response in
                    let decoded = try TestSupport.jsonDecoder.decode(ListWatchesResponse.self, from: response.body)
                    #expect(decoded.watches.count == 1)
                    #expect(decoded.watches[0].status == .stopped)
                    #expect(decoded.watches[0].lastErrorKind == .authFailure)
                    #expect(decoded.watches[0].lastErrorAt != nil)
                }
            }
        }
    }

    @Test("GET /v1/watches without a valid bearer secret is rejected")
    func listWatchesRequiresAuth() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                try await client.execute(
                    uri: "/v1/watches",
                    method: .get,
                    headers: [.authorization: "Bearer not-a-real-secret"]
                ) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }

    @Test("creating a watch with an empty IMAP host is a 400, not persisted")
    func createWatchValidatesRequiredFields() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    // MARK: - CLAUDE-SECURITY F2: SSRF defense

    /// Loopback, RFC1918/link-local IPv4, and IPv6 equivalents — every
    /// range `RelayNetworkPolicy.strict` (the production default, used by
    /// `buildRouter`'s default `networkPolicy` here) is documented to
    /// reject.
    @Test(
        "a private/loopback/link-local imapHost is rejected with 400, nothing persisted",
        arguments: [
            "127.0.0.1", // loopback
            "10.0.0.5", // RFC1918
            "172.16.0.1", // RFC1918
            "192.168.1.1", // RFC1918
            "169.254.1.1", // link-local
            "0.0.0.0", // unspecified
            "::1", // IPv6 loopback
            "fe80::1", // IPv6 link-local
            "fc00::1", // IPv6 unique local
            "::ffff:127.0.0.1", // IPv4-mapped IPv6 loopback (must not bypass the IPv4 check)
        ]
    )
    func createWatchRejectsPrivateHost(host: String) async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: host,
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("a public imapHost on the standard IMAPS port (993) is accepted")
    func createWatchAcceptsPublicHostOnAllowedPort() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "203.0.113.10", // TEST-NET-3, RFC 5737 — literal public-looking IP
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .created)
                }
                #expect(try await store.listWatches().count == 1)
            }
        }
    }

    @Test("an imapPort outside the allowed list is rejected with 400, nothing persisted")
    func createWatchRejectsDisallowedPort() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "203.0.113.10",
                        imapPort: 6379, // e.g. Redis — not an IMAP port
                        imapUseTLS: false,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    // MARK: - CLAUDE-SECURITY F3: CRLF injection defense

    @Test(
        "a CR/LF/NUL in imapUsername, auth.secret, or mailbox is rejected with 400, nothing persisted",
        arguments: [
            "a\r\nRCPT TO:<attacker@evil.test>",
            "a\nCONFIG SET dir /var/lib/redis",
            "a\r\n",
            "a\u{0000}b",
        ]
    )
    func createWatchRejectsControlCharactersInUsername(poisoned: String) async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: poisoned,
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("a CR/LF in auth.secret is rejected with 400, nothing persisted")
    func createWatchRejectsControlCharactersInSecret() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "pw\r\nHELO relay\r\nMAIL FROM:<a@b>")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("a CR/LF in mailbox is rejected with 400, nothing persisted")
    func createWatchRejectsControlCharactersInMailbox() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: "account-1",
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password"),
                        mailbox: "INBOX\r\nA2 LOGOUT"
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    // MARK: - CLAUDE-SECURITY F16: accountId log-forgery defense

    @Test(
        "an accountId with control characters or outside the allowed charset is rejected with 400",
        arguments: [
            "a\r\n2026-07-29T00:00:00 info otegami-relay : forged log line",
            "a\nb",
            "has spaces",
            "",
            String(repeating: "a", count: 129),
        ]
    )
    func createWatchRejectsInvalidAccountId(accountId: String) async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: accountId,
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .badRequest)
                }
                #expect(try await store.listWatches().isEmpty)
            }
        }
    }

    @Test("a UUID-shaped accountId (the app's real AccountRecord.id format) is accepted")
    func createWatchAcceptsUUIDAccountId() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let device = try await registerDevice(client: client)
                let watchBody = try JSONEncoder().encode(
                    CreateWatchRequest(
                        accountId: UUID().uuidString,
                        imapHost: "203.0.113.10",
                        imapPort: 993,
                        imapUseTLS: true,
                        imapUsername: "user@example.com",
                        auth: WatchAuth(secret: "app-password")
                    )
                )
                try await client.execute(
                    uri: "/v1/watches",
                    method: .post,
                    headers: [.authorization: "Bearer \(device.deviceSecret)"],
                    body: ByteBuffer(data: watchBody)
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }
    }
}
