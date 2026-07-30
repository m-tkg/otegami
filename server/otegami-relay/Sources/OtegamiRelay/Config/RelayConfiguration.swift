import Foundation

/// Everything the relay reads from the environment at startup. Kept as one
/// place so `docs/relay-deployment.md`'s env-var table and this type never
/// drift apart, and so `App.swift` stays a thin "read config, wire it up"
/// entry point.
struct RelayConfiguration: Sendable {
    var masterKeyBase64: String
    var databasePath: String
    var apns: APNsConfig?
    var port: Int
    /// CLAUDE-SECURITY F2 — SSRF defense for `POST /v1/watches` and every
    /// IMAP (re)connect. See `RelayNetworkPolicy`'s doc comment.
    var networkPolicy: RelayNetworkPolicy
    /// CLAUDE-SECURITY F2 — optional gate on `POST /v1/devices`. `nil`
    /// (unset `RELAY_DEVICE_REGISTRATION_SECRET`) keeps registration open;
    /// see `DeviceRoutes.authorizeRegistration`'s doc comment for why.
    var deviceRegistrationSecret: String?

    struct APNsConfig: Sendable {
        var keyPath: String
        var keyId: String
        var teamId: String
        var bundleId: String
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case missingMasterKey

        var description: String {
            switch self {
            case .missingMasterKey:
                "RELAY_MASTER_KEY is not set. Generate a 32-byte base64 key " +
                    "with `openssl rand -base64 32` and set it in the " +
                    "environment before starting the relay — see " +
                    "docs/relay-deployment.md."
            }
        }
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RelayConfiguration {
        guard let masterKey = environment["RELAY_MASTER_KEY"], !masterKey.isEmpty else {
            throw ConfigurationError.missingMasterKey
        }

        let databasePath = environment["RELAY_DATABASE_PATH"] ?? "otegami-relay.sqlite"
        let port = environment["RELAY_PORT"].flatMap(Int.init) ?? 8080

        // APNs is fully optional (M9 constraint: no `.p8` key exists yet —
        // PENDING.md). Every field must be present for real APNs delivery
        // to be enabled; otherwise the relay falls back to
        // `ConsolePushSender` (see `App.swift`).
        var apns: APNsConfig?
        if let keyPath = environment["APNS_KEY_PATH"],
           let keyId = environment["APNS_KEY_ID"],
           let teamId = environment["APNS_TEAM_ID"],
           let bundleId = environment["APNS_BUNDLE_ID"],
           !keyPath.isEmpty, !keyId.isEmpty, !teamId.isEmpty, !bundleId.isEmpty {
            apns = APNsConfig(keyPath: keyPath, keyId: keyId, teamId: teamId, bundleId: bundleId)
        }

        let deviceRegistrationSecret = environment["RELAY_DEVICE_REGISTRATION_SECRET"].flatMap { $0.isEmpty ? nil : $0 }

        return RelayConfiguration(
            masterKeyBase64: masterKey,
            databasePath: databasePath,
            apns: apns,
            port: port,
            networkPolicy: .fromEnvironment(environment),
            deviceRegistrationSecret: deviceRegistrationSecret
        )
    }
}
