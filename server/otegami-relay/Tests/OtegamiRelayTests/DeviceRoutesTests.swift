import Foundation
import Hummingbird
import HummingbirdTesting
import OtegamiRelayAPI
import Testing

@testable import OtegamiRelay

@Suite("POST /v1/devices, PUT /v1/devices/:id/token")
struct DeviceRoutesTests {
    @Test("register a device, then update its token with its own bearer secret")
    func registerAndUpdateToken() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let registerBody = try JSONEncoder().encode(
                    RegisterDeviceRequest(apnsToken: "initial-token", environment: .sandbox)
                )
                var deviceId = ""
                var deviceSecret = ""
                try await client.execute(
                    uri: "/v1/devices",
                    method: .post,
                    body: ByteBuffer(data: registerBody)
                ) { response in
                    #expect(response.status == .created)
                    let decoded = try JSONDecoder().decode(RegisterDeviceResponse.self, from: response.body)
                    #expect(!decoded.deviceId.isEmpty)
                    #expect(!decoded.deviceSecret.isEmpty)
                    deviceId = decoded.deviceId
                    deviceSecret = decoded.deviceSecret
                }

                let updateBody = try JSONEncoder().encode(
                    UpdateDeviceTokenRequest(apnsToken: "rotated-token", environment: .production)
                )
                try await client.execute(
                    uri: "/v1/devices/\(deviceId)/token",
                    method: .put,
                    headers: [.authorization: "Bearer \(deviceSecret)"],
                    body: ByteBuffer(data: updateBody)
                ) { response in
                    #expect(response.status == .noContent)
                }

                let target = try await store.pushTarget(forDeviceId: deviceId)
                #expect(target?.apnsToken == "rotated-token")
                #expect(target?.environment == .production)
            }
        }
    }

    @Test("updating a token with the wrong bearer secret is rejected")
    func updateTokenWrongSecretRejected() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let registerBody = try JSONEncoder().encode(
                    RegisterDeviceRequest(apnsToken: "t", environment: .sandbox)
                )
                var deviceId = ""
                try await client.execute(uri: "/v1/devices", method: .post, body: ByteBuffer(data: registerBody)) { response in
                    let decoded = try JSONDecoder().decode(RegisterDeviceResponse.self, from: response.body)
                    deviceId = decoded.deviceId
                }

                let updateBody = try JSONEncoder().encode(
                    UpdateDeviceTokenRequest(apnsToken: "new", environment: .sandbox)
                )
                try await client.execute(
                    uri: "/v1/devices/\(deviceId)/token",
                    method: .put,
                    headers: [.authorization: "Bearer totally-wrong-secret"],
                    body: ByteBuffer(data: updateBody)
                ) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }

    @Test("updating a token with no Authorization header is rejected")
    func updateTokenMissingAuthRejected() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let updateBody = try JSONEncoder().encode(
                    UpdateDeviceTokenRequest(apnsToken: "new", environment: .sandbox)
                )
                try await client.execute(
                    uri: "/v1/devices/some-id/token",
                    method: .put,
                    body: ByteBuffer(data: updateBody)
                ) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }

    // MARK: - CLAUDE-SECURITY F2: optional device-registration secret

    @Test("without RELAY_DEVICE_REGISTRATION_SECRET configured, registration stays open (historical behavior)")
    func registrationOpenWhenSecretNotConfigured() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            // `deviceRegistrationSecret: nil` is `buildRouter`'s default —
            // spelled out here anyway so this test documents the behavior
            // it's asserting, not just relying on the default.
            let router = buildRouter(store: store, watcherPool: watcherPool, deviceRegistrationSecret: nil)
            let app = Application(router: router)
            try await app.test(.router) { client in
                let registerBody = try JSONEncoder().encode(
                    RegisterDeviceRequest(apnsToken: "tok", environment: .sandbox)
                )
                try await client.execute(uri: "/v1/devices", method: .post, body: ByteBuffer(data: registerBody)) { response in
                    #expect(response.status == .created)
                }
            }
        }
    }

    @Test("with RELAY_DEVICE_REGISTRATION_SECRET configured, registration without it is rejected and nothing is persisted")
    func registrationRejectedWithoutSecretWhenConfigured() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool, deviceRegistrationSecret: "op-secret")
            let app = Application(router: router)
            try await app.test(.router) { client in
                let registerBody = try JSONEncoder().encode(
                    RegisterDeviceRequest(apnsToken: "tok", environment: .sandbox)
                )
                try await client.execute(uri: "/v1/devices", method: .post, body: ByteBuffer(data: registerBody)) { response in
                    #expect(response.status == .unauthorized)
                }
                try await client.execute(
                    uri: "/v1/devices",
                    method: .post,
                    headers: [.authorization: "Bearer wrong-secret"],
                    body: ByteBuffer(data: registerBody)
                ) { response in
                    #expect(response.status == .unauthorized)
                }
            }
        }
    }

    @Test("with RELAY_DEVICE_REGISTRATION_SECRET configured, registration with the correct secret succeeds")
    func registrationAcceptedWithCorrectSecret() async throws {
        try await TestSupport.withStore { store, watcherPool, _ in
            let router = buildRouter(store: store, watcherPool: watcherPool, deviceRegistrationSecret: "op-secret")
            let app = Application(router: router)
            try await app.test(.router) { client in
                let registerBody = try JSONEncoder().encode(
                    RegisterDeviceRequest(apnsToken: "tok", environment: .sandbox)
                )
                try await client.execute(
                    uri: "/v1/devices",
                    method: .post,
                    headers: [.authorization: "Bearer op-secret"],
                    body: ByteBuffer(data: registerBody)
                ) { response in
                    #expect(response.status == .created)
                }
            }
        }
    }
}
