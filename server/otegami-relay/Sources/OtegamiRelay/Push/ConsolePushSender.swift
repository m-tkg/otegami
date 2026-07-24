import Logging
import OtegamiRelayAPI

/// The fallback `PushSending` implementation used whenever `APNS_*` env
/// vars aren't configured (see `RelayConfiguration`) — logs what would have
/// been sent instead of actually contacting APNs. Lets a self-hoster run
/// the full watch → IDLE → "push fires" pipeline (and this repo's
/// `scripts/verify-relay.sh`) end to end without an Apple Developer
/// account or `.p8` key, per M9's constraint (`PENDING.md`).
struct ConsolePushSender: PushSending {
    let logger: Logger

    func send(
        deviceToken: String,
        environment: RegisterDeviceRequest.Environment,
        payload: PushNotificationPayload
    ) async throws {
        logger.info(
            "[console-push] would deliver push",
            metadata: [
                "deviceToken": .string(Self.redact(deviceToken)),
                "environment": .string(environment.rawValue),
                "accountId": .string(payload.accountId),
                "uidNext": .stringConvertible(payload.uidNext),
            ]
        )
    }

    /// Never logs a full device token — only enough to eyeball "yes, this
    /// looks like the token I registered" in `docker compose logs`.
    private static func redact(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "*", count: token.count) }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }
}
