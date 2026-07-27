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
                    imapHost: "imap.watch-test.invalid",
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
                        imapHost: "imap.watch-test.invalid",
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
                        imapHost: "imap.watch-test.invalid",
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
                        imapHost: "imap.watch-test.invalid",
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
                        imapHost: "imap.watch-test.invalid",
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
                    #expect(decoded.watches[0].imapHost == "imap.watch-test.invalid")
                    // Never echoes the credential back.
                    #expect(String(buffer: response.body).contains("app-password") == false)
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
}
