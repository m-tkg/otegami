import Foundation
import Hummingbird
import OtegamiRelayAPI

/// `POST /v1/watches` + `DELETE /v1/watches/:id` + `GET /v1/watches`. All
/// three are Bearer-authenticated as the owning device
/// (`authenticatedDeviceId`, `DeviceRoutes.swift`) — a watch is always
/// scoped to the device that created it.
enum WatchRoutes {
    static func register(
        on router: Router<some RequestContext>,
        store: RelayStore,
        watcherPool: WatcherPool,
        networkPolicy: RelayNetworkPolicy = .strict
    ) {
        router.post("/v1/watches") { request, context -> EditedResponse<WatchResponse> in
            let deviceId = try await authenticatedDeviceId(request: request, store: store)
            let body = try await request.decode(as: CreateWatchRequest.self, context: context)
            guard !body.imapHost.isEmpty, !body.imapUsername.isEmpty, !body.auth.secret.isEmpty else {
                throw RelayHTTPError.badRequest("imapHost, imapUsername, and auth.secret are required")
            }

            // CLAUDE-SECURITY F3: reject (not escape) CR/LF/NUL/other
            // control characters before anything is persisted — the same
            // check `MinimalIMAPClient.quoted` runs again immediately
            // before writing these values onto the wire, as a backstop.
            do {
                try MinimalIMAPClient.validateNoControlCharacters(body.imapUsername, field: "imapUsername")
                try MinimalIMAPClient.validateNoControlCharacters(body.auth.secret, field: "auth.secret")
                try MinimalIMAPClient.validateNoControlCharacters(body.mailbox, field: "mailbox")
            } catch let error as MinimalIMAPClient.IMAPClientError {
                throw RelayHTTPError.badRequest(error.description)
            }

            // CLAUDE-SECURITY F16: bound accountId to a safe charset
            // before it's ever persisted or logged — it's echoed verbatim
            // into push-send log metadata (`ConsolePushSender`/
            // `APNsSender`), where an unvalidated value could forge log
            // records.
            try Self.validateAccountId(body.accountId)

            // CLAUDE-SECURITY F2: resolve + validate host/port *before*
            // persisting or opening any connection. `WatcherPool` also
            // re-validates on every connect attempt (DNS-rebinding
            // defense) — this check additionally gives the caller an
            // immediate 400 instead of a watch that's created but can
            // never actually connect.
            do {
                try networkPolicy.validatePort(body.imapPort)
                _ = try networkPolicy.resolveAndValidate(host: body.imapHost, port: body.imapPort)
            } catch let error as RelayNetworkPolicy.ValidationError {
                throw RelayHTTPError.badRequest(error.description)
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

    /// CLAUDE-SECURITY F16: `accountId` is a client-chosen opaque string,
    /// never interpreted by the server (`CreateWatchRequest.accountId`'s
    /// doc comment) — but it *is* echoed verbatim into push-send log
    /// metadata (`ConsolePushSender.send`/`APNsSender.send`) and into the
    /// APNs payload. Bounding it to the same charset the relay's own
    /// generated ids use (`RelayStore.randomToken`'s base64url alphabet)
    /// plus real-world UUID-shaped ids (the app's `AccountRecord.id`) is
    /// enough to rule out CR/LF log-record forgery while accepting every
    /// legitimate value.
    private static let accountIdAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    private static func validateAccountId(_ accountId: String) throws {
        guard !accountId.isEmpty, accountId.count <= 128,
              accountId.unicodeScalars.allSatisfy({ Self.accountIdAllowedCharacters.contains($0) })
        else {
            throw RelayHTTPError.badRequest("accountId must be 1-128 characters from [A-Za-z0-9_-]")
        }
    }
}
