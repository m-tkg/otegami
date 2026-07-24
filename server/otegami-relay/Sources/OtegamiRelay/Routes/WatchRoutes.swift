import Hummingbird
import OtegamiRelayAPI

/// `POST /v1/watches` + `DELETE /v1/watches/:id`. Both are Bearer-
/// authenticated as the owning device (`authenticatedDeviceId`,
/// `DeviceRoutes.swift`) — a watch is always scoped to the device that
/// created it.
enum WatchRoutes {
    static func register(on router: Router<some RequestContext>, store: RelayStore, watcherPool: WatcherPool) {
        router.post("/v1/watches") { request, context -> EditedResponse<WatchResponse> in
            let deviceId = try await authenticatedDeviceId(request: request, store: store)
            let body = try await request.decode(as: CreateWatchRequest.self, context: context)
            guard !body.imapHost.isEmpty, !body.imapUsername.isEmpty, !body.auth.secret.isEmpty else {
                throw RelayHTTPError.badRequest("imapHost, imapUsername, and auth.secret are required")
            }
            let response = try await store.createWatch(deviceId: deviceId, request: body)
            await watcherPool.addWatch(id: response.watchId)
            return EditedResponse(status: .created, response: response)
        }

        router.delete("/v1/watches/:id") { request, context -> HTTPResponse.Status in
            let deviceId = try await authenticatedDeviceId(request: request, store: store)
            let watchId = try context.parameters.require("id")
            do {
                try await store.deleteWatch(id: watchId, deviceId: deviceId)
            } catch RelayStore.RelayStoreError.watchNotFound {
                throw RelayHTTPError.notFound("watch not found")
            }
            await watcherPool.removeWatch(id: watchId)
            return .noContent
        }
    }
}
