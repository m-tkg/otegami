import Foundation
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

@Suite("RelayStore")
struct RelayStoreTests {
    @Test("createDevice returns a usable id/secret pair, verifiable afterwards")
    func createAndVerifyDevice() async throws {
        try await TestSupport.withStore { store, _, _ in
            let response = try await store.createDevice(apnsToken: "abc123", environment: .sandbox)
            #expect(!response.deviceId.isEmpty)
            #expect(!response.deviceSecret.isEmpty)

            #expect(try await store.verifyDevice(id: response.deviceId, secret: response.deviceSecret))
            #expect(try await store.verifyDevice(id: response.deviceId, secret: "wrong-secret") == false)
            #expect(try await store.verifyDevice(id: "no-such-device", secret: response.deviceSecret) == false)
        }
    }

    @Test("deviceId(forSecret:) resolves the bearer secret back to its device")
    func resolveDeviceBySecret() async throws {
        try await TestSupport.withStore { store, _, _ in
            let a = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let b = try await store.createDevice(apnsToken: "", environment: .production)

            #expect(try await store.deviceId(forSecret: a.deviceSecret) == a.deviceId)
            #expect(try await store.deviceId(forSecret: b.deviceSecret) == b.deviceId)
            #expect(try await store.deviceId(forSecret: "garbage") == nil)
        }
    }

    @Test("updateDeviceToken updates the token used for push, and rejects an unknown device")
    func updateDeviceToken() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "old-token", environment: .sandbox)
            try await store.updateDeviceToken(id: device.deviceId, apnsToken: "new-token", environment: .production)

            let target = try await store.pushTarget(forDeviceId: device.deviceId)
            #expect(target?.apnsToken == "new-token")
            #expect(target?.environment == .production)

            await #expect(throws: RelayStore.RelayStoreError.deviceNotFound) {
                try await store.updateDeviceToken(id: "nope", apnsToken: "x", environment: .sandbox)
            }
        }
    }

    @Test("pushTarget is nil until a non-empty APNs token is registered")
    func pushTargetNilUntilTokenSet() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            #expect(try await store.pushTarget(forDeviceId: device.deviceId) == nil)
        }
    }

    @Test("createWatch persists and roundtrips through listWatches with the credential decrypted")
    func createWatchRoundTrips() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "tok", environment: .sandbox)
            let request = CreateWatchRequest(
                accountId: "account-1",
                imapHost: "imap.watch-test.invalid",
                imapPort: 993,
                imapUseTLS: true,
                imapUsername: "user@example.com",
                auth: WatchAuth(secret: "app-password"),
                mailbox: "INBOX"
            )
            let response = try await store.createWatch(deviceId: device.deviceId, request: request)
            #expect(response.accountId == "account-1")
            #expect(response.mailbox == "INBOX")

            let watches = try await store.listWatches()
            #expect(watches.count == 1)
            #expect(watches[0].id == response.watchId)
            #expect(watches[0].secret == "app-password")
            #expect(watches[0].imapHost == "imap.watch-test.invalid")

            let single = try await store.watch(id: response.watchId)
            #expect(single?.secret == "app-password")
        }
    }

    @Test("deleteWatch wipes the row, and is scoped to the owning device")
    func deleteWatchIsScopedAndWipes() async throws {
        try await TestSupport.withStore { store, _, _ in
            let owner = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let other = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let watch = try await store.createWatch(
                deviceId: owner.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "password")
                )
            )

            // A different device can't delete this watch...
            await #expect(throws: RelayStore.RelayStoreError.watchNotFound) {
                try await store.deleteWatch(id: watch.watchId, deviceId: other.deviceId)
            }
            #expect(try await store.listWatches().count == 1)

            // ...but the owning device can, and the row is gone afterwards.
            try await store.deleteWatch(id: watch.watchId, deviceId: owner.deviceId)
            #expect(try await store.listWatches().isEmpty)
            #expect(try await store.watch(id: watch.watchId) == nil)
        }
    }

    @Test("listWatchSummaries returns only the requesting device's watches, without the credential")
    func listWatchSummariesIsScopedAndCredentialFree() async throws {
        try await TestSupport.withStore { store, _, _ in
            let owner = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let other = try await store.createDevice(apnsToken: "", environment: .sandbox)

            let ownerWatch = try await store.createWatch(
                deviceId: owner.deviceId,
                request: CreateWatchRequest(
                    accountId: "owner-account",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "owner-password")
                )
            )
            _ = try await store.createWatch(
                deviceId: other.deviceId,
                request: CreateWatchRequest(
                    accountId: "other-account",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user2@example.com",
                    auth: WatchAuth(secret: "other-password")
                )
            )

            let summaries = try await store.listWatchSummaries(deviceId: owner.deviceId)
            #expect(summaries.count == 1)
            #expect(summaries[0].watchId == ownerWatch.watchId)
            #expect(summaries[0].accountId == "owner-account")
            #expect(summaries[0].imapHost == "imap.watch-test.invalid")

            #expect(try await store.listWatchSummaries(deviceId: other.deviceId).count == 1)
        }
    }

    // MARK: - Watch status (Task #173)

    @Test("a freshly created watch defaults to active status with no error and no connection yet")
    func newWatchDefaultsToActiveStatus() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let watch = try await store.createWatch(
                deviceId: device.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "password")
                )
            )
            let summaries = try await store.listWatchSummaries(deviceId: device.deviceId)
            #expect(summaries.count == 1)
            #expect(summaries[0].watchId == watch.watchId)
            #expect(summaries[0].status == .active)
            #expect(summaries[0].lastConnectedAt == nil)
            #expect(summaries[0].lastErrorKind == nil)
            #expect(summaries[0].lastErrorAt == nil)
        }
    }

    @Test("markWatchConnected records the connection time and clears any prior error")
    func markWatchConnectedRecordsSuccess() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let watch = try await store.createWatch(
                deviceId: device.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "password")
                )
            )
            // A connection error first, so this test also proves a later
            // success clears it rather than just never setting it.
            try await store.recordWatchError(id: watch.watchId, kind: .connectionError, stopping: false)
            try await store.markWatchConnected(id: watch.watchId)

            let summary = try await store.listWatchSummaries(deviceId: device.deviceId)[0]
            #expect(summary.status == .active)
            #expect(summary.lastConnectedAt != nil)
            #expect(summary.lastErrorKind == nil)
            #expect(summary.lastErrorAt == nil)
        }
    }

    @Test("recordWatchError(stopping: false) records the error but leaves status active")
    func recordWatchErrorNonStoppingStaysActive() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let watch = try await store.createWatch(
                deviceId: device.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "password")
                )
            )
            try await store.recordWatchError(id: watch.watchId, kind: .connectionError, stopping: false)

            let summary = try await store.listWatchSummaries(deviceId: device.deviceId)[0]
            #expect(summary.status == .active)
            #expect(summary.lastErrorKind == .connectionError)
            #expect(summary.lastErrorAt != nil)
        }
    }

    @Test("recordWatchError(stopping: true) flips status to stopped with the given reason")
    func recordWatchErrorStoppingMarksStopped() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            let watch = try await store.createWatch(
                deviceId: device.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "password")
                )
            )
            try await store.recordWatchError(id: watch.watchId, kind: .authFailure, stopping: true)

            let summary = try await store.listWatchSummaries(deviceId: device.deviceId)[0]
            #expect(summary.status == .stopped)
            #expect(summary.lastErrorKind == .authFailure)
            #expect(summary.lastErrorAt != nil)
        }
    }

    @Test("watch credentials are never stored as plaintext")
    func credentialsAreEncryptedAtRest() async throws {
        try await TestSupport.withStore { store, _, _ in
            let device = try await store.createDevice(apnsToken: "", environment: .sandbox)
            _ = try await store.createWatch(
                deviceId: device.deviceId,
                request: CreateWatchRequest(
                    accountId: "acct",
                    imapHost: "imap.watch-test.invalid",
                    imapPort: 993,
                    imapUseTLS: true,
                    imapUsername: "user@example.com",
                    auth: WatchAuth(secret: "super-secret-password")
                )
            )
            let raw = try await store.rawEncryptedSecretForTesting()
            #expect(raw != nil)
            #expect(!(raw?.contains("super-secret-password") ?? true))
        }
    }
}
