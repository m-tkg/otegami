import AsyncHTTPClient
import Crypto
import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import OtegamiRelayAPI

/// Real APNs delivery over HTTP/2, token-based (`.p8`) authentication.
/// **Never exercised against real APNs in this repo's test suite** — no
/// `.p8` key has been issued yet (`PENDING.md`, M9). What *is* tested
/// (`APNsSenderTests`) is everything that doesn't require a live server:
/// JWT header/claims shape, ES256 signature format, and the request/body
/// construction, using a throwaway `P256` key generated in the test itself
/// (APNs' JWT format doesn't care whose key it is to check the shape).
///
/// Chose to hand-roll this (JWT + a single `AsyncHTTPClient` POST) rather
/// than pull in APNSwift: the whole surface needed is "one HTTP/2 POST with
/// a bearer JWT", APNSwift's own JWT/HTTP2 machinery is a thin wrapper
/// around the same two libraries this project already depends on
/// (swift-crypto, AsyncHTTPClient), and not depending on it avoids a third
/// package whose Swift 6 concurrency posture would otherwise need
/// independent vetting for a code path that can't be integration-tested
/// here anyway.
struct APNsSender: PushSending {
    struct Configuration: Sendable {
        /// Contents of the `.p8` file (PEM, `-----BEGIN PRIVATE KEY-----…`).
        var privateKeyPEM: String
        /// The Key ID shown next to the key in App Store Connect.
        var keyId: String
        /// The Apple Developer Team ID.
        var teamId: String
        /// `apns-topic` — the app's bundle id (Notification Service
        /// Extension pushes use the main app's bundle id, not the
        /// extension's).
        var bundleId: String
    }

    private let configuration: Configuration
    private let httpClient: HTTPClient
    private let logger: Logger
    private let tokenCache: JWTCache

    init(configuration: Configuration, httpClient: HTTPClient, logger: Logger) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.logger = logger
        self.tokenCache = JWTCache(configuration: configuration)
    }

    func send(
        deviceToken: String,
        environment: RegisterDeviceRequest.Environment,
        payload: PushNotificationPayload
    ) async throws {
        let host = Self.host(for: environment)
        let jwt = try await tokenCache.currentToken()

        let body = APNsBody(
            aps: APNsBody.APS(
                alert: APNsBody.APS.Alert(locKey: "NEW_MAIL"),
                mutableContent: 1
            ),
            accountId: payload.accountId,
            uidNext: payload.uidNext
        )
        let bodyData = try JSONEncoder().encode(body)

        var request = HTTPClientRequest(url: "https://\(host)/3/device/\(deviceToken)")
        request.method = .POST
        request.headers.add(name: "authorization", value: "bearer \(jwt)")
        request.headers.add(name: "apns-topic", value: configuration.bundleId)
        request.headers.add(name: "apns-push-type", value: "alert")
        request.headers.add(name: "apns-priority", value: "10")
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: bodyData))

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status == .ok else {
            // Collect the JSON error body APNs sends on failure (e.g.
            // `{"reason":"BadDeviceToken"}`) — the status code alone doesn't
            // distinguish "token is stale, re-register" from "our JWT/topic
            // is misconfigured", and this send-attempt otherwise wouldn't be
            // logged at all (previously it wasn't, on any outcome).
            let bodyText = (try? await response.body.collect(upTo: 1024)).flatMap { String(buffer: $0) } ?? "<no body>"
            logger.warning(
                "APNs push rejected",
                metadata: [
                    "status": .stringConvertible(response.status.code),
                    "accountId": .string(payload.accountId),
                    "deviceToken": .string(Self.redact(deviceToken)),
                    "body": .string(bodyText),
                ]
            )
            return
        }
        logger.info(
            "APNs push accepted",
            metadata: [
                "accountId": .string(payload.accountId),
                "uidNext": .stringConvertible(payload.uidNext),
                "deviceToken": .string(Self.redact(deviceToken)),
                "environment": .string(environment.rawValue),
            ]
        )
    }

    /// Which APNs endpoint a device's registered environment routes to.
    /// Pulled out of `send(deviceToken:environment:payload:)` as its own
    /// (non-`private`, so `@testable import OtegamiRelay` can reach it)
    /// function purely so `APNsSenderTests` can assert the sandbox/
    /// production split directly, without needing a live HTTP round trip —
    /// `send` itself is never exercised against real APNs in this repo's
    /// test suite (see this type's doc comment).
    static func host(for environment: RegisterDeviceRequest.Environment) -> String {
        switch environment {
        case .sandbox: "api.sandbox.push.apple.com"
        case .production: "api.push.apple.com"
        }
    }

    /// Never logs a full device token — only enough to eyeball "yes, this
    /// looks like the token I registered" in `docker compose logs`, same
    /// redaction `ConsolePushSender` uses.
    private static func redact(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "*", count: token.count) }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    /// Minimal payload shape (plan §7: "ペイロードは最小(mutable-content, loc-key
    /// NEW_MAIL, accountId, uidNext — 本文/件名を含めない)"). `accountId`/
    /// `uidNext` live outside `aps` at the top level, same as any other
    /// custom push data — `NotificationService` reads them from there.
    private struct APNsBody: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let locKey: String
                enum CodingKeys: String, CodingKey { case locKey = "loc-key" }
            }
            let alert: Alert
            let mutableContent: Int
            enum CodingKeys: String, CodingKey {
                case alert
                case mutableContent = "mutable-content"
            }
        }
        let aps: APS
        let accountId: String
        let uidNext: Int
    }

    /// Caches the signed JWT for up to 50 minutes (Apple allows up to 60;
    /// leaving headroom avoids a request landing right at expiry) rather
    /// than signing on every push — cheap either way, but avoids
    /// unnecessary P256 signing under load.
    private actor JWTCache {
        private let configuration: Configuration
        private var cached: (token: String, issuedAt: Date)?

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        func currentToken() throws -> String {
            let now = Date()
            if let cached, now.timeIntervalSince(cached.issuedAt) < 50 * 60 {
                return cached.token
            }
            let token = try APNsJWT.makeToken(configuration: configuration, issuedAt: now)
            cached = (token, now)
            return token
        }
    }
}

/// Builds the ES256 JWT APNs' token-based auth expects
/// (`Authorization: bearer <jwt>`). Free function (rather than nested in
/// `APNsSender`) so `APNsSenderTests` can call it directly with a
/// throwaway `P256` key, without going through any HTTP client.
enum APNsJWT {
    static func makeToken(configuration: APNsSender.Configuration, issuedAt: Date) throws -> String {
        let header = ["alg": "ES256", "kid": configuration.keyId]
        let claims: [String: Any] = [
            "iss": configuration.teamId,
            "iat": Int(issuedAt.timeIntervalSince1970),
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let claimsData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = "\(base64url(headerData)).\(base64url(claimsData))"

        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: configuration.privateKeyPEM)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        // JWT ES256 wants the raw (r || s), 64-byte concatenation, not
        // ASN.1 DER — `P256.Signing.ECDSASignature.rawRepresentation` is
        // exactly that.
        return "\(signingInput).\(base64url(signature.rawRepresentation))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
