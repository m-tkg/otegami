import Hummingbird
import OtegamiRelayAPI

/// `POST /v1/watches` + `DELETE /v1/watches/:id` + `GET /v1/watches`. All
/// three are Bearer-authenticated as the owning device
/// (`authenticatedDeviceId`, `DeviceRoutes.swift`) — a watch is always
/// scoped to the device that created it.
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

        // M9 follow-up (実機バグ1: 削除済みアカウントの watch がリレーに残り
        // 通知が届き続ける): lets the app reconcile its local
        // account/watch state against the relay's ground truth on
        // launch/foreground, instead of relying solely on `DELETE
        // /v1/watches/:id` at delete time succeeding (which used to be a
        // best-effort `try?` with no retry — see `AppEnvironment
        // .reconcilePushWatchesIfNeeded()`'s doc comment). Never returns a
        // credential, only what `WatchSummary` exposes.
        router.get("/v1/watches") { request, context -> ListWatchesResponse in
            let deviceId = try await authenticatedDeviceId(request: request, store: store)
            let summaries = try await store.listWatchSummaries(deviceId: deviceId)
            return ListWatchesResponse(watches: summaries)
        }
    }
}
