import Hummingbird
import Logging
import OtegamiRelayAPI

/// `POST /v1/devices` + `PUT /v1/devices/:id/token`.
enum DeviceRoutes {
    /// - Parameters:
    ///   - registrationSecret: CLAUDE-SECURITY F2 — when set (operator env
    ///     var `RELAY_DEVICE_REGISTRATION_SECRET`), `POST /v1/devices`
    ///     requires it as a bearer token. `nil` (the default, and the
    ///     historical behavior) keeps registration open — see
    ///     `authorizeRegistration`'s doc comment for why that's the
    ///     default rather than a hard break, and `docs/relay-deployment.md`
    ///     for the operator-facing writeup.
    static func register(
        on router: Router<some RequestContext>,
        store: RelayStore,
        registrationSecret: String? = nil,
        logger: Logger = Logger(label: "otegami-relay.device-routes")
    ) {
        router.post("/v1/devices") { request, context -> EditedResponse<RegisterDeviceResponse> in
            try Self.authorizeRegistration(request: request, registrationSecret: registrationSecret, logger: logger)
            let body = try await request.decode(as: RegisterDeviceRequest.self, context: context)
            let response = try await store.createDevice(apnsToken: body.apnsToken, environment: body.environment)
            return EditedResponse(status: .created, response: response)
        }

        router.put("/v1/devices/:id/token") { request, context -> HTTPResponse.Status in
            let pathId = try context.parameters.require("id")
            let deviceId = try await authenticatedDeviceId(request: request, store: store)
            guard deviceId == pathId else {
                throw RelayHTTPError.unauthorized()
            }
            let body = try await request.decode(as: UpdateDeviceTokenRequest.self, context: context)
            do {
                try await store.updateDeviceToken(id: deviceId, apnsToken: body.apnsToken, environment: body.environment)
            } catch RelayStore.RelayStoreError.deviceNotFound {
                throw RelayHTTPError.notFound("device not found")
            }
            return .noContent
        }
    }

    /// CLAUDE-SECURITY F2 (HIGH) — `POST /v1/devices` is the one route
    /// with no prior credential to check (it's how a device *gets* its
    /// credential in the first place), which is what let the finding
    /// self-serve a `deviceSecret` bearer token for the SSRF sink at
    /// `POST /v1/watches` with zero prior authorization.
    ///
    /// If the operator configured `RELAY_DEVICE_REGISTRATION_SECRET`,
    /// this requires it as a bearer token — a *shared operator secret*,
    /// deliberately distinct from any individual `deviceSecret` a
    /// registration returns.
    ///
    /// If they haven't, this keeps the historical open-registration
    /// behavior rather than breaking it outright: this relay is already
    /// running in production for real deployments (see this repo's
    /// CLAUDE.md), the app doesn't send this header yet (no client-side
    /// support has shipped), and
    /// flipping the default to closed would silently brick every already-
    /// deployed install's "enable push notifications" flow with no
    /// migration path. Instead: log a warning on every unauthenticated
    /// registration, loud enough to show up in `docker compose logs`,
    /// so the exposure is visible rather than silent — and
    /// `docs/relay-deployment.md` documents the opt-in for operators who
    /// want it now (e.g. by fronting `POST /v1/devices` at the reverse
    /// proxy layer, or setting the env var once app support lands).
    private static func authorizeRegistration(
        request: Request,
        registrationSecret: String?,
        logger: Logger
    ) throws {
        guard let registrationSecret, !registrationSecret.isEmpty else {
            logger.warning(
                """
                POST /v1/devices accepted an unauthenticated device registration \
                (RELAY_DEVICE_REGISTRATION_SECRET is not set) — anyone who can reach \
                this relay's HTTP port can self-register a device and create watches. \
                See docs/relay-deployment.md's threat model section.
                """
            )
            return
        }
        let prefix = "Bearer "
        guard let header = request.headers[.authorization], header.hasPrefix(prefix),
              RelayStore.constantTimeEquals(String(header.dropFirst(prefix.count)), registrationSecret)
        else {
            throw RelayHTTPError.unauthorized("device registration requires a valid registration secret")
        }
    }
}

/// Shared bearer-auth resolution: reads `Authorization: Bearer <secret>`,
/// looks up the owning device. Throws `.unauthorized` for a missing or
/// unrecognized header/secret rather than returning `nil`, so every call
/// site gets consistent 401 behavior for free.
func authenticatedDeviceId(request: Request, store: RelayStore) async throws -> String {
    guard let header = request.headers[.authorization] else {
        throw RelayHTTPError.unauthorized("missing Authorization header")
    }
    let prefix = "Bearer "
    guard header.hasPrefix(prefix) else {
        throw RelayHTTPError.unauthorized("Authorization header must be a Bearer token")
    }
    let secret = String(header.dropFirst(prefix.count))
    guard let deviceId = try await store.deviceId(forSecret: secret) else {
        throw RelayHTTPError.unauthorized()
    }
    return deviceId
}
