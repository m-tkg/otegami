import Hummingbird
import OtegamiRelayAPI

/// `POST /v1/devices` + `PUT /v1/devices/:id/token`.
enum DeviceRoutes {
    static func register(on router: Router<some RequestContext>, store: RelayStore) {
        router.post("/v1/devices") { request, context -> EditedResponse<RegisterDeviceResponse> in
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
