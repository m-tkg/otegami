import Foundation
import OtegamiRelayAPI
import Testing

@Suite("OtegamiRelayAPI Go wire compatibility")
struct OtegamiRelayAPIWireCompatibilityTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("RegisterDeviceRequest keys and enum values match Go")
    func registerDeviceRequest() throws {
        try assertWireCompatibility(
            RegisterDeviceRequest(apnsToken: "apns-token", environment: .sandbox),
            json: #"{"apnsToken":"apns-token","environment":"sandbox"}"#
        )
    }

    @Test("RegisterDeviceResponse keys match Go")
    func registerDeviceResponse() throws {
        try assertWireCompatibility(
            RegisterDeviceResponse(deviceId: "device-1", deviceSecret: "device-secret"),
            json: #"{"deviceId":"device-1","deviceSecret":"device-secret"}"#
        )
    }

    @Test("UpdateDeviceTokenRequest keys and enum values match Go")
    func updateDeviceTokenRequest() throws {
        try assertWireCompatibility(
            UpdateDeviceTokenRequest(apnsToken: "new-token", environment: .production),
            json: #"{"apnsToken":"new-token","environment":"production"}"#
        )
    }

    @Test("WatchAuth omits a nil provider like Go omitempty")
    func passwordWatchAuth() throws {
        try assertWireCompatibility(
            WatchAuth(type: .password, secret: "app-password"),
            json: #"{"type":"password","secret":"app-password"}"#
        )
    }

    @Test("WatchAuth OAuth keys and enum values match Go")
    func oauthWatchAuth() throws {
        try assertWireCompatibility(
            WatchAuth(type: .oauth, secret: "refresh-token", provider: .google),
            json: #"{"type":"oauth","secret":"refresh-token","provider":"google"}"#
        )
    }

    @Test("CreateWatchRequest keys and nested auth match Go")
    func createWatchRequest() throws {
        try assertWireCompatibility(
            CreateWatchRequest(
                accountId: "account-1",
                imapHost: "imap.example.com",
                imapPort: 993,
                imapUseTLS: true,
                imapUsername: "user@example.com",
                auth: WatchAuth(type: .oauth, secret: "refresh-token", provider: .microsoft),
                mailbox: "Archive"
            ),
            json: #"{"accountId":"account-1","imapHost":"imap.example.com","imapPort":993,"imapUseTLS":true,"imapUsername":"user@example.com","auth":{"type":"oauth","secret":"refresh-token","provider":"microsoft"},"mailbox":"Archive"}"#
        )
    }

    @Test("WatchResponse keys and ISO 8601 date match Go")
    func watchResponse() throws {
        try assertWireCompatibility(
            WatchResponse(
                watchId: "watch-1",
                accountId: "account-1",
                mailbox: "INBOX",
                createdAt: timestamp
            ),
            json: #"{"watchId":"watch-1","accountId":"account-1","mailbox":"INBOX","createdAt":"2023-11-14T22:13:20Z"}"#
        )
    }

    @Test("PushNotificationPayload keys match Go")
    func pushNotificationPayload() throws {
        try assertWireCompatibility(
            PushNotificationPayload(accountId: "account-1", uidNext: 42),
            json: #"{"accountId":"account-1","uidNext":42}"#
        )
    }

    @Test("PushNotificationPayload omits every Phase 2/3 field like Go omitempty when unset")
    func pushNotificationPayloadOmitsOptionalFieldsWhenNil() throws {
        // A pre-Phase-2 relay (RELAY_CONTENT_PREVIEW off, or simply an
        // older build) never sends these keys at all — decoding that exact
        // shape must still succeed and leave every new field nil.
        let decoded = try decoder().decode(
            PushNotificationPayload.self,
            from: Data(#"{"accountId":"account-1","uidNext":42}"#.utf8)
        )
        #expect(decoded == PushNotificationPayload(accountId: "account-1", uidNext: 42))
        #expect(decoded.latestUid == nil)
        #expect(decoded.latestFromName == nil)
        #expect(decoded.latestFromAddress == nil)
        #expect(decoded.latestSubject == nil)
        #expect(decoded.previewCount == nil)
    }

    @Test("PushNotificationPayload keys match Go when every Phase 2/3 field is populated")
    func pushNotificationPayloadWithEnvelope() throws {
        try assertWireCompatibility(
            PushNotificationPayload(
                accountId: "account-1",
                uidNext: 42,
                latestUid: 41,
                latestFromName: "Alice",
                latestFromAddress: "alice@example.test",
                latestSubject: "Hello",
                previewCount: 3
            ),
            json: #"""
            {"accountId":"account-1","uidNext":42,"latestUid":41,"latestFromName":"Alice","latestFromAddress":"alice@example.test","latestSubject":"Hello","previewCount":3}
            """#
        )
    }

    @Test("MessagePreview keys and ISO 8601 date match Go")
    func messagePreview() throws {
        try assertWireCompatibility(
            MessagePreview(
                uid: 11,
                from: MessagePreview.From(name: "Bob", address: "bob@example.test"),
                subject: "Yo",
                date: timestamp,
                messageId: "m11",
                bodyPreview: "body 11"
            ),
            json: #"""
            {"uid":11,"from":{"name":"Bob","address":"bob@example.test"},"subject":"Yo","date":"2023-11-14T22:13:20Z","messageId":"m11","bodyPreview":"body 11"}
            """#
        )
    }

    @Test("GET /v1/messages's plain-array response shape decodes into [MessagePreview], uid descending")
    func messagePreviewArrayResponse() throws {
        let json = #"""
        [{"uid":11,"from":{"name":"Bob","address":"bob@example.test"},"subject":"Yo","date":"2023-11-14T22:13:20Z","messageId":"m11","bodyPreview":"body 11"},
         {"uid":10,"from":{"name":"","address":"carol@example.test"},"subject":"","date":"2023-11-14T22:13:20Z","messageId":"m10","bodyPreview":""}]
        """#.data(using: .utf8)!

        let decoded = try decoder().decode([MessagePreview].self, from: json)
        #expect(decoded.count == 2)
        #expect(decoded[0].uid == 11)
        #expect(decoded[1].uid == 10)
        #expect(decoded[1].from.name == "")
    }

    @Test("WatchSummary keys, enum values, and ISO 8601 dates match Go")
    func watchSummary() throws {
        try assertWireCompatibility(
            WatchSummary(
                watchId: "watch-1",
                accountId: "account-1",
                imapHost: "imap.example.com",
                mailbox: "INBOX",
                createdAt: timestamp,
                status: .stopped,
                lastConnectedAt: timestamp,
                lastErrorKind: .oauthTokenExpired,
                lastErrorAt: timestamp
            ),
            json: #"{"watchId":"watch-1","accountId":"account-1","imapHost":"imap.example.com","mailbox":"INBOX","createdAt":"2023-11-14T22:13:20Z","status":"stopped","lastConnectedAt":"2023-11-14T22:13:20Z","lastErrorKind":"oauthTokenExpired","lastErrorAt":"2023-11-14T22:13:20Z"}"#
        )
    }

    @Test("WatchSummary omits nil optional fields like Go omitempty")
    func watchSummaryWithoutDiagnostics() throws {
        try assertWireCompatibility(
            WatchSummary(
                watchId: "watch-1",
                accountId: "account-1",
                imapHost: "imap.example.com",
                mailbox: "INBOX",
                createdAt: timestamp,
                status: .active
            ),
            json: #"{"watchId":"watch-1","accountId":"account-1","imapHost":"imap.example.com","mailbox":"INBOX","createdAt":"2023-11-14T22:13:20Z","status":"active"}"#
        )
    }

    @Test("WatchSummary decodes responses from Go relays predating diagnostics")
    func watchSummaryLegacyDecodeDefaultsToActive() throws {
        let value = try decoder().decode(
            WatchSummary.self,
            from: Data(
                #"{"watchId":"watch-1","accountId":"account-1","imapHost":"imap.example.com","mailbox":"INBOX","createdAt":"2023-11-14T22:13:20Z"}"#.utf8
            )
        )

        #expect(value.status == .active)
        #expect(value.lastConnectedAt == nil)
        #expect(value.lastErrorKind == nil)
        #expect(value.lastErrorAt == nil)
    }

    @Test("ListWatchesResponse key and nested DTO match Go")
    func listWatchesResponse() throws {
        try assertWireCompatibility(
            ListWatchesResponse(watches: [
                WatchSummary(
                    watchId: "watch-1",
                    accountId: "account-1",
                    imapHost: "imap.example.com",
                    mailbox: "INBOX",
                    createdAt: timestamp,
                    status: .active
                ),
            ]),
            json: #"{"watches":[{"watchId":"watch-1","accountId":"account-1","imapHost":"imap.example.com","mailbox":"INBOX","createdAt":"2023-11-14T22:13:20Z","status":"active"}]}"#
        )
    }

    @Test("RelayErrorResponse keys match Go")
    func relayErrorResponse() throws {
        try assertWireCompatibility(
            RelayErrorResponse(error: "bad_request", message: "invalid payload"),
            json: #"{"error":"bad_request","message":"invalid payload"}"#
        )
    }

    @Test("Every string enum raw value matches Go constants")
    func enumRawValues() {
        #expect(RegisterDeviceRequest.Environment.sandbox.rawValue == "sandbox")
        #expect(RegisterDeviceRequest.Environment.production.rawValue == "production")
        #expect(WatchAuth.Kind.password.rawValue == "password")
        #expect(WatchAuth.Kind.oauth.rawValue == "oauth")
        #expect(WatchAuth.Provider.google.rawValue == "google")
        #expect(WatchAuth.Provider.microsoft.rawValue == "microsoft")
        #expect(WatchSummary.Status.active.rawValue == "active")
        #expect(WatchSummary.Status.stopped.rawValue == "stopped")
        #expect(WatchSummary.ErrorKind.authFailure.rawValue == "authFailure")
        #expect(WatchSummary.ErrorKind.connectionError.rawValue == "connectionError")
        #expect(WatchSummary.ErrorKind.oauthTokenExpired.rawValue == "oauthTokenExpired")
    }

    private func assertWireCompatibility<Value: Codable & Equatable>(
        _ value: Value,
        json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let expectedData = Data(json.utf8)
        let actualObject = try jsonObject(from: encoder().encode(value))
        let expectedObject = try jsonObject(from: expectedData)

        #expect(
            NSDictionary(dictionary: actualObject).isEqual(to: expectedObject),
            "Encoded JSON differs from the Go DTO wire shape",
            sourceLocation: sourceLocation
        )

        let decoded = try decoder().decode(Value.self, from: expectedData)
        #expect(
            decoded == value,
            "Swift failed to decode the Go DTO wire shape",
            sourceLocation: sourceLocation
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
