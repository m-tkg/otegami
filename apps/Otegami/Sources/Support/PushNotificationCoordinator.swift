import Foundation
import GRDB
import MailTransport
import OtegamiRelayAPI
import OtegamiStore
import PushRelayClient
import SyncEngine

@MainActor
extension AppEnvironment {
    // MARK: - Push notifications (M9)

    enum PushError: Error, Equatable {
        /// Task #173 follow-up: this *build* has no relay URL baked in
        /// (`RelayURLConfig.value == nil`) — there's nowhere left for the
        /// user to type one, so `enablePushNotifications()` refuses up
        /// front rather than the old "type a bad URL" failure mode.
        /// `PushNotificationSettingsView` disables its "有効にする" button
        /// whenever `RelayURLConfig.isConfigured == false`, so reaching
        /// this case in practice would mean the button's own guard had a
        /// bug — kept as a safety net, not an expected user-facing path.
        case relayNotConfigured
        /// `PushTokenCenter` never got a device token — always the case on
        /// the iOS Simulator (`PushTokenCenter`'s doc comment). No longer
        /// used for a denied notification-authorization prompt on a real
        /// device — that's `.notificationPermissionDenied` now, so the UI
        /// can tell the two apart and point at Settings only for the
        /// latter.
        case noDeviceToken
        /// The user declined (or had previously declined) the
        /// `UNUserNotificationCenter` alert/badge/sound authorization
        /// prompt — `PushTokenCenter.requestToken()` throws
        /// `.notificationPermissionDenied` *before* attempting APNs
        /// device-token registration at all (M9 bug fix: the app
        /// previously never requested this permission, so push
        /// notifications silently never displayed — see
        /// `docs/verify.md`'s "M9 追補" section). `PushNotificationSettingsView`
        /// surfaces this with a link to the Settings app
        /// (`UIApplication.openSettingsURLString`), since iOS never
        /// re-shows the system prompt once denied.
        case notificationPermissionDenied
        /// This build has no `UIApplication` to register with at all
        /// (macOS) — push isn't implemented there yet (M9 scope: iOS-only
        /// `NotificationService`).
        case unsupportedPlatform
        /// Task #171 (follow-up: build-time secret, see
        /// `RelayRegistrationSecretConfig`): `POST /v1/devices` came back
        /// 401 — the relay has `RELAY_DEVICE_REGISTRATION_SECRET`
        /// configured and either this build has no
        /// `OTEGAMI_RELAY_REGISTRATION_SECRET` baked in, or the one it has
        /// doesn't match what the relay expects.
        /// `PushNotificationSettingsView` surfaces this without repeating
        /// the relay's own error text (`DeviceRoutes
        /// .authorizeRegistration`'s message is an operator/debugging
        /// detail, not something to show the end user verbatim), and
        /// distinguishes the two cases via `isRelayRegistrationSecretConfigured`.
        case registrationSecretRejected
    }

    /// Requests notification authorization + an APNs device token,
    /// registers this device with the build's baked-in relay
    /// (`RelayURLConfig.value` — Task #173 follow-up), and creates a watch
    /// for every currently push-watch-eligible account
    /// (`isPushWatchCandidate(_:)` — every `.password` account, plus
    /// `.oauth2` Gmail/Microsoft accounts as of Task #175, which sends the
    /// account's refresh token to the relay instead of an IMAP password;
    /// see `watchAuth(for:)`'s doc comment for what that changes). Persists
    /// everything via `pushSettings` as it goes, so a failure partway
    /// through (e.g. the device registers fine but one account's watch
    /// creation fails) still leaves whatever succeeded in place rather than
    /// needing to be redone from scratch.
    func enablePushNotifications() async throws {
        guard let baseURL = RelayURLConfig.value else {
            throw PushError.relayNotConfigured
        }

        let apnsToken = try await requestAPNsToken()
        let apnsEnvironment = APNSEnvironmentDetector.detectedEnvironment()

        let deviceId: String
        let deviceSecret: String
        if let existingId = pushSettings.deviceId, let existingSecret = try pushSettings.deviceSecret() {
            // Already registered (re-enabling after a previous disable, or
            // recovering from a partial failure) — just refresh the token
            // rather than minting a brand new device registration.
            try await pushRelayClient.updateDeviceToken(
                baseURL: baseURL,
                deviceId: existingId,
                deviceSecret: existingSecret,
                apnsToken: apnsToken,
                environment: apnsEnvironment
            )
            deviceId = existingId
            deviceSecret = existingSecret
        } else {
            let response: RegisterDeviceResponse
            do {
                response = try await pushRelayClient.registerDevice(
                    baseURL: baseURL,
                    apnsToken: apnsToken,
                    environment: apnsEnvironment,
                    registrationSecret: RelayRegistrationSecretConfig.value
                )
            } catch let PushRelayClient.PushRelayClientError.http(status, _) where status == 401 {
                throw PushError.registrationSecretRejected
            }
            deviceId = response.deviceId
            deviceSecret = response.deviceSecret
            try pushSettings.setDeviceSecret(deviceSecret)
        }

        pushSettings.deviceId = deviceId

        for account in accounts where Self.isPushWatchCandidate(account) {
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }

        pushSettings.isEnabled = true
        setPushEnabledState(true)
    }

    /// Deletes every watch this device has registered (best-effort — a
    /// relay that's unreachable at the moment shouldn't leave the user
    /// stuck unable to turn push back off locally) and clears all local
    /// push state.
    ///
    /// Task #174 (実機バグ2 followup): "disable" is meant to fully undo
    /// this device's relay footprint, so it fetches this device's actual
    /// watch list from the relay (`GET /v1/watches`, ground truth —
    /// already device-scoped server-side) rather than trusting only the
    /// local `accountWatchMap`, which can drift (a previous register/
    /// reregister call may have created a watch on the relay but never
    /// got as far as persisting its id locally). See
    /// `WatchReconciler.watchIdsToDeleteForDisable`'s doc comment.
    func disablePushNotifications() async {
        if let baseURL = RelayURLConfig.value,
           let deviceSecret = try? pushSettings.deviceSecret() {
            let serverWatches = (try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)) ?? []
            let watchIdsToDelete = WatchReconciler.watchIdsToDeleteForDisable(
                serverWatches: serverWatches,
                localWatchMap: pushSettings.accountWatchMap
            )
            for watchId in watchIdsToDelete {
                try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
            }
        }
        pushSettings.reset()
        setPushEnabledState(false)
    }

    /// Whether this *build* has a relay registration secret baked in (see
    /// `RelayRegistrationSecretConfig`) — lets
    /// `PushNotificationSettingsView` tell apart "this relay requires a
    /// secret and this build doesn't have one configured" from "this
    /// build has one configured but the relay rejected it anyway" when it
    /// catches `PushError.registrationSecretRejected`.
    var isRelayRegistrationSecretConfigured: Bool {
        RelayRegistrationSecretConfig.isConfigured
    }

    /// Registers a watch for `account` if push is enabled and it doesn't
    /// already have one — called both from `enablePushNotifications` (for
    /// every existing account) and should be called again whenever a new
    /// push-watch-eligible account (`isPushWatchCandidate(_:)`) is added
    /// while push is already enabled.
    func registerWatchIfNeeded(for account: AccountRecord) async {
        guard isPushEnabled, Self.isPushWatchCandidate(account) else { return }
        guard pushSettings.accountWatchMap[account.id] == nil else { return }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
    }

    /// Task #175: every account whose credential the relay could
    /// meaningfully watch on this device's behalf — `.password` (an IMAP
    /// password) or `.oauth2` Gmail/Microsoft (an OAuth refresh token,
    /// `WatchAuth(type: .oauth, ...)`). A generic `.oauth2` account with
    /// neither `kind` (shouldn't exist in practice — every `.oauth2`
    /// account this app creates is `.gmail` or `.microsoft`) is excluded,
    /// same as before Task #175.
    nonisolated static func isPushWatchCandidate(_ account: AccountRecord) -> Bool {
        switch account.authType {
        case .password:
            return true
        case .oauth2:
            return account.kind == .gmail || account.kind == .microsoft
        }
    }

    @discardableResult
    private func registerWatch(for account: AccountRecord, baseURL: URL, deviceSecret: String) async -> Bool {
        guard let auth = await watchAuth(for: account) else { return false }
        let request = CreateWatchRequest(
            accountId: account.id,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapUseTLS: account.imapSecurity != .plain,
            imapUsername: account.imapUsername,
            auth: auth,
            mailbox: "INBOX"
        )
        guard let response = try? await pushRelayClient.createWatch(baseURL: baseURL, deviceSecret: deviceSecret, request: request) else {
            return false
        }
        pushSettings.setWatchId(response.watchId, forAccountId: account.id)
        return true
    }

    /// Task #175: the `WatchAuth` the relay needs for `account`'s watch —
    /// an IMAP password for `.password`, or an OAuth refresh token
    /// (`type: .oauth`) for a Gmail/Microsoft `.oauth2` account. `nil` if
    /// `account` isn't push-watch-eligible at all
    /// (`isPushWatchCandidate(_:)`), or if the credential it needs isn't
    /// actually available locally (Keychain password missing, or no
    /// refresh token stored/no token store configured for this build —
    /// e.g. `GOOGLE_OAUTH_CLIENT_ID` unset).
    ///
    /// **Sends the refresh token itself to the relay** — see
    /// `docs/relay-deployment.md`'s threat model on what that changes
    /// versus an IMAP password (both are credentials the relay operator
    /// could misuse, but a live refresh token keeps working until revoked,
    /// unlike a changed password).
    private func watchAuth(for account: AccountRecord) async -> WatchAuth? {
        switch account.authType {
        case .password:
            guard let password = try? credentialStore.password(forAccountId: account.id) else { return nil }
            return WatchAuth(secret: password)
        case .oauth2:
            switch account.kind {
            case .gmail:
                guard let tokenStore, let refreshToken = await tokenStore.rawRefreshToken(for: account.id) else { return nil }
                return WatchAuth(type: .oauth, secret: refreshToken, provider: .google)
            case .microsoft:
                guard let microsoftTokenStore,
                      let refreshToken = await microsoftTokenStore.rawRefreshToken(for: account.id)
                else { return nil }
                return WatchAuth(type: .oauth, secret: refreshToken, provider: .microsoft)
            case .generic, .icloud:
                return nil
            }
        }
    }

    func unregisterWatch(forAccountId accountId: String) async {
        guard let watchId = pushSettings.accountWatchMap[accountId] else { return }
        defer { pushSettings.setWatchId(nil, forAccountId: accountId) }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
    }

    /// Task #173: fetches this device's current watch list straight from
    /// the relay (`GET /v1/watches`) so `PushNotificationSettingsView` can
    /// show *which* `.password` account's watch is stopped — the
    /// motivating 実機 report was a relay-side log line ("3 watches, 1
    /// auth-failed") with no way to tell which account from the app.
    /// `nil` on any failure (relay unreachable, push not enabled, etc.) —
    /// the view treats that as "status unavailable" rather than an error
    /// dialog, matching this file's existing "best-effort, no user-facing
    /// failure" posture for everything else push-related.
    func fetchPushWatchSummaries() async -> [WatchSummary]? {
        // `scripts/verify-screen.sh`'s `push-settings-watches` scenario —
        // see `OTEGAMI_UITEST_FORCE_PUSH_ENABLED`'s doc comment in
        // `init()` for why this exists: screenshotting every status
        // `PushWatchDisplayRow` can render needs fixed data, not a live
        // relay round trip this dev machine can't make safely/
        // deterministically here.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES"] == "1" {
            return Self.uitestFixedPushWatchSummaries
        }
        guard isPushEnabled,
              let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return nil }
        return try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)
    }

    /// Paired with `OTEGAMI_UITEST_INSERT_FAKE_PUSH_WATCH_ACCOUNTS`'s
    /// fixture accounts in `init()` — one active, one stopped, and (by
    /// omission) one account with no watch at all, covering
    /// `.registered`/`.stopped`/`.notRegistered` between them.
    private static var uitestFixedPushWatchSummaries: [WatchSummary] {
        let now = Date()
        return [
            WatchSummary(
                watchId: "uitest-watch-registered",
                accountId: "uitest-fake-registered",
                imapHost: "imap.example.test",
                mailbox: "INBOX",
                createdAt: now.addingTimeInterval(-3600),
                status: .active,
                lastConnectedAt: now.addingTimeInterval(-180)
            ),
            WatchSummary(
                watchId: "uitest-watch-stopped",
                accountId: "uitest-fake-stopped",
                imapHost: "imap.example.test",
                mailbox: "INBOX",
                createdAt: now.addingTimeInterval(-3600),
                status: .stopped,
                lastErrorKind: .authFailure,
                lastErrorAt: now.addingTimeInterval(-180)
            ),
        ]
    }

    /// Task #173: "re-register" a single stopped watch — deletes whatever
    /// watch the relay currently has for this account (if any; best-effort,
    /// same as `unregisterWatch`) and creates a fresh one, resending the
    /// account's current IMAP credential. This is the one operation the
    /// motivating 実機 report actually needed: a relay-side "watch stopped
    /// after repeated auth failures" only recovers once the account's
    /// password is fixed *and* something re-creates the watch — the relay
    /// itself never retries a `.stopped` watch on its own.
    ///
    /// Throws rather than silently no-op'ing (unlike most of this file's
    /// push plumbing) because this is a direct user action from a "有効化
    /// されていません"/"認証情報が見つかりません" button tap —
    /// `PushNotificationSettingsView` surfaces the failure instead of
    /// leaving the row looking like nothing happened.
    ///
    /// Task #174 (実機バグ2: 再登録後もリレー側に古い watch が孤児として
    /// 残る): a 実機 test of the Task #173 re-register button reconnected
    /// successfully, but the relay ended up with 3 watches for 2 apps-known
    /// accounts — the old, now-stopped watch never got deleted. The bug
    /// was that this method only ever deleted `pushSettings
    /// .accountWatchMap[account.id]` — the *local* record — which can lose
    /// track of a watch the relay still has (see
    /// `WatchReconciler.watchIdsToDelete(forReregisteringAccountId:...)`'s
    /// doc comment for why). Fixed by asking the relay itself
    /// (`GET /v1/watches`) which watch(es) it has for this account before
    /// deleting, falling back to the local map too so a failed/unreachable
    /// list call still cleans up at least as much as before this fix.
    func reregisterWatch(for account: AccountRecord) async throws {
        guard isPushEnabled else { throw PushError.relayNotConfigured }
        guard Self.isPushWatchCandidate(account) else { throw PushError.relayNotConfigured }
        guard let baseURL = RelayURLConfig.value else { throw PushError.relayNotConfigured }
        guard let deviceSecret = try? pushSettings.deviceSecret() else { throw PushError.relayNotConfigured }
        // Task #175: `.credentialUnavailable` now also covers a Gmail/
        // Microsoft account with no refresh token available locally (no
        // token store configured for this build, or nothing stored) —
        // `watchAuth(for:)` is the single source of truth for whether a
        // usable credential exists, so this just previews its result
        // rather than duplicating the per-authType logic here.
        guard await watchAuth(for: account) != nil else {
            throw ReregisterWatchError.credentialUnavailable
        }

        let serverWatches = (try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)) ?? []
        let watchIdsToDelete = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: account.id,
            serverWatches: serverWatches,
            localWatchId: pushSettings.accountWatchMap[account.id]
        )
        for watchId in watchIdsToDelete {
            // Best-effort, same as `unregisterWatch` — a delete failure
            // here means (at worst) one more orphan for a future
            // `reconcilePushWatchesIfNeeded()` pass to clean up, not a
            // reason to block the user from getting a working watch back.
            try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
        }
        pushSettings.setWatchId(nil, forAccountId: account.id)

        guard await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret) else {
            throw ReregisterWatchError.relayRejectedWatch
        }
    }

    enum ReregisterWatchError: Error, Equatable {
        /// `KeychainCredentialStore` has no password for this account —
        /// shouldn't happen for a `.password`-auth account in normal use,
        /// but a Keychain item can vanish (e.g. an iCloud Keychain sync
        /// glitch, or the item was deleted outside the app).
        case credentialUnavailable
        /// The relay reachable-but-rejected the new watch (bad
        /// credentials, network error reaching the *IMAP* server isn't
        /// checked synchronously here — `POST /v1/watches` itself failed
        /// or the relay's SSRF/validation checks rejected the request).
        case relayRejectedWatch
    }

    /// Task #210 backoff after a *failed* `GET /v1/watches` attempt — see
    /// `reconcilePushWatchesIfNeeded()`'s doc comment. Deliberately much
    /// shorter than the old daily `watchReconcileInterval` this replaces:
    /// this only protects against hammering a relay that's *currently*
    /// unreachable across rapid foreground/background cycles, not against
    /// running the (cheap) fetch itself when everything is healthy.
    private static let watchReconcileFailureBackoffInterval: TimeInterval = 60 * 5

    /// M9 follow-up (実機バグ1: 削除済みアカウントの watch がリレーに残り
    /// 通知が届き続ける): `unregisterWatch`'s `DELETE` is (and stays)
    /// best-effort `try?` with no retry of its own — a relay that's
    /// unreachable for that one call previously meant the watch (and the
    /// IMAP credential it holds) lived on the relay forever, with nothing
    /// to ever notice or retry. This is the self-healing counterpart:
    /// called from every launch/foreground (`RootView
    /// .handleScenePhaseChange`'s `.active` case), it fetches this
    /// device's actual watch list from the relay (`GET /v1/watches`,
    /// ground truth) and reconciles it against local accounts via
    /// `WatchReconciler.plan` —
    ///   - a relay watch for an account no longer known locally gets
    ///     `DELETE`d (fixes the actual bug: a deleted account's watch
    ///     that a prior best-effort delete failed to clean up).
    ///   - a local push-watch-eligible account (`isPushWatchCandidate(_:)`)
    ///     with no live relay watch gets a fresh one registered (the
    ///     initial `createWatch` failed, or the local map fell out of sync
    ///     some other way).
    ///   - the local accountId→watchId map is repaired to match the
    ///     relay wherever it disagrees — no network call needed for that
    ///     part, just local bookkeeping.
    ///
    /// **Task #210** (実機バグ3: Task #208 のリレー・スキーマ入れ替えで
    /// リレー側の watch テーブルが空になった後、両デバイスとも通知が
    /// 最大24時間止まったまま): this used to throttle the `GET /v1/watches`
    /// fetch itself to roughly once a day (`PushSettingsStore
    /// .lastWatchReconcileDate`), reasoning that once healed this shouldn't
    /// need to run often. That reasoning missed the case where the *relay*
    /// silently loses its watches independent of anything the client did —
    /// the local `accountWatchMap` cache stayed populated (a server-side
    /// migration doesn't touch it), so there was no local signal that
    /// anything was wrong, and the daily gate meant nobody asked the relay
    /// again for up to 24h. See `docs/architecture.md`'s Task #210 note for
    /// the full incident and why a narrower "only bypass the throttle when
    /// the local map looks empty" fix wouldn't have caught this specific
    /// case either (the map wasn't empty, just stale).
    ///
    /// Fixed by no longer gating the fetch on staleness at all — `GET
    /// /v1/watches` now runs on every foreground unconditionally, same
    /// cadence as `syncAllAccountsOnce()` (which does far more real work
    /// per foreground already). `WatchReconciler.plan` is a pure in-memory
    /// diff, so an empty result (the common, healthy case) costs nothing
    /// beyond that one request. What still needs throttling is retrying a
    /// fetch that just *failed* — `WatchReconciler.shouldAttemptReconcile`
    /// backs that off via `PushSettingsStore.lastWatchReconcileFailureDate`
    /// so a relay outage doesn't get hit on every single foreground for as
    /// long as it lasts.
    func reconcilePushWatchesIfNeeded() async {
        guard isPushEnabled else { return }
        guard WatchReconciler.shouldAttemptReconcile(
            now: Date(),
            lastFailureDate: pushSettings.lastWatchReconcileFailureDate,
            failureBackoffInterval: Self.watchReconcileFailureBackoffInterval
        ) else { return }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        guard let serverWatches = try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret) else {
            // Records the failure so the next few foregrounds back off
            // rather than re-hitting an unreachable relay immediately —
            // same "best-effort, no user-visible failure" posture as the
            // rest of this file's push plumbing, just no longer silent
            // about *when* to retry.
            pushSettings.lastWatchReconcileFailureDate = Date()
            return
        }
        pushSettings.lastWatchReconcileFailureDate = nil
        // Diagnostic only now (Task #210) — see `lastWatchReconcileDateKey`'s
        // doc comment; nothing branches on this anymore.
        pushSettings.lastWatchReconcileDate = Date()

        // Task #175: despite the parameter's name (unchanged, to keep this
        // diff scoped to `AppEnvironment` — `WatchReconciler` itself has no
        // opinion on *why* an account is watch-eligible), this now also
        // includes `.oauth2` Gmail/Microsoft accounts —
        // `isPushWatchCandidate(_:)` is the single source of truth for
        // "should this account have a relay watch at all".
        let localPasswordAccountIds = Set(accounts.filter(Self.isPushWatchCandidate).map(\.id))
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: localPasswordAccountIds,
            localWatchMap: pushSettings.accountWatchMap,
            serverWatches: serverWatches
        )

        for watchId in plan.watchIdsToDelete {
            try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
        }
        for (accountId, watchId) in plan.watchIdsToAdoptLocally {
            pushSettings.setWatchId(watchId, forAccountId: accountId)
        }
        for accountId in plan.accountIdsToForgetLocally {
            pushSettings.setWatchId(nil, forAccountId: accountId)
        }
        for accountId in plan.accountIdsToRegister {
            guard let account = accounts.first(where: { $0.id == accountId }) else { continue }
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }
    }

    /// Task #31 (docs/roadmap.md): thin wiring for `SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded(accounts:now:authProvider:)` —
    /// all the actual logic (candidate selection, debounce, per-account
    /// sequencing, silent best-effort failure handling) lives there and is
    /// unit-tested there with `FakeIMAPSession`; this method exists only
    /// because `SyncEngine` has no dependency on `KeychainCredentialStore`/
    /// `GoogleOAuth`, so resolving each account's `MailAuth` has to be
    /// injected from here, the same way `auth(for:)` already is for
    /// `syncAllAccountsOnce()`/`startIdleLoops(for:)` in `OtegamiApp.swift`.
    /// Called from `RootView.handleScenePhaseChange`'s `.active` case as a
    /// low-priority, fire-and-forget `Task` — never awaited inline with
    /// user-visible sync/refresh, so a slow or offline prefetch pass can
    /// never delay them.
    /// 通知の本体タップが指すメール (`PushNotificationOpenRequest`) を
    /// ローカル DB 上の `threadId`/`messageId` へ解決する —
    /// `PushNotificationOpenView` の `.task`/再試行から呼ばれる。実体は
    /// `PushNotificationActionExecutor.fetchAndResolveOpenTarget` (ローカル
    /// 照合 → 未同期なら対象アカウントの INBOX だけを優先的に差分同期 →
    /// 再照合) で、ここは `prefetchRecentBodiesIfNeeded()` と同じ thin
    /// wiring — `auth(for:)` と接続プール (`imapSessionPool`) を注入する
    /// だけ。以前この解決は `AppDelegate` の裏 `Task` で行っていて、同期が
    /// 終わるまで画面遷移が起きず・失敗すると何も表示されなかった —
    /// ビュー側へ移したことでローディング表示と再試行が可能になった。
    /// 優先同期後も見つからない・資格情報が解決できない等はすべて `nil`。
    func resolvePushNotificationOpenTarget(accountId: String, uidNext: Int) async -> PushNotificationOpenTarget? {
        guard let target = await PushNotificationActionExecutor.fetchAndResolveOpenTarget(
            accountId: accountId,
            uidNext: uidNext,
            database: database,
            auth: { [weak self] account in
                guard let self else { return nil }
                return try? await self.auth(for: account)
            },
            sessionFactory: imapSessionPool.makeSessionFactory()
        ) else { return nil }
        return PushNotificationOpenTarget(threadId: target.threadId, messageId: target.messageId)
    }

    func prefetchRecentBodiesIfNeeded() async {
        _ = await syncCoordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: accounts) { [weak self] account in
            guard let self else { throw AuthResolutionError.missingCredential }
            return try await self.auth(for: account)
        }
    }

    /// Task #80 (「一覧が更新されたときにバックグラウンドで先読み」): same thin-
    /// wiring role as `prefetchRecentBodiesIfNeeded()` above, but for
    /// `SyncCoordinator.prefetchMessageBodies(messageIds:accounts:
    /// authProvider:)` — `MessageListView`/`SearchScreenView` call this with
    /// the leading `SyncCoordinator.listUpdatePrefetchLimit` not-yet-fetched
    /// message ids of whatever list/search-result content just came on
    /// screen (each view debounces its own trigger first; see those views'
    /// doc comments). All the actual logic lives in `SyncCoordinator` and is
    /// unit-tested there; this exists only to supply `auth(for:)`, same
    /// rationale as `prefetchRecentBodiesIfNeeded()`.
    @discardableResult
    func prefetchMessageBodiesIfNeeded(messageIds: [Int64]) async -> Int {
        await syncCoordinator.prefetchMessageBodies(messageIds: messageIds, accounts: accounts) { [weak self] account in
            guard let self else { throw AuthResolutionError.missingCredential }
            return try await self.auth(for: account)
        }
    }

    /// Task #192 (実機クラッシュ解析: `EXC_CRASH`/`SIGKILL`,
    /// `RUNNINGBOARD`/`0xDEAD10CC` — the shared App Group database's
    /// `DatabasePool` held a lock while this app was suspended in the
    /// background; see `AppDatabase.makeConfiguration
    /// (observesSuspensionNotifications:)`'s doc comment for the full
    /// analysis and `docs/architecture.md`'s matching Known pitfalls
    /// entry). Posts GRDB's
    /// `Database.suspendNotification`, which — because `makeShared`
    /// enables `observesSuspensionNotifications` exactly when the database
    /// actually lives in the App Group container — makes every
    /// `DatabasePool` sharing that file (this process's, and whichever
    /// `NotificationService` Extension instance happens to be alive right
    /// now) refuse to acquire any *new* SQLite lock from this point on,
    /// failing such an access with `SQLITE_INTERRUPT`/`SQLITE_ABORT`
    /// instead — see `DatabaseSuspensionSupport.isSuspensionError(_:)`'s
    /// doc comment for how `SyncEngine` treats that.
    ///
    /// Called from `RootView.handleScenePhaseChange`'s `.background`/
    /// `.inactive` case, `#if os(iOS)`-gated there — macOS has no shared
    /// App Group container to race a background suspend over in the first
    /// place (`OtegamiAppGroup.identifier` always returns `nil` there), so
    /// this method exists on both platforms (for `AppEnvironment`'s own
    /// simplicity) but is only ever actually *called* on iOS.
    /// `databaseSuspensionTracker` dedups so an ordinary `.active →
    /// .inactive → .background` sequence — both legs of which map to
    /// "suspend" in that same `handleScenePhaseChange` switch — doesn't
    /// post this notification twice for one real suspend.
    func suspendSharedDatabaseIfNeeded() async {
        guard await markDatabaseSuspended() else { return }
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// The `.active`-side counterpart to `suspendSharedDatabaseIfNeeded()`
    /// — posts `Database.resumeNotification`, letting every `DatabasePool`
    /// sharing the App Group database acquire new locks again. Called
    /// first thing in `RootView.handleScenePhaseChange`'s `.active` case
    /// (`#if os(iOS)`-gated there, same reasoning as
    /// `suspendSharedDatabaseIfNeeded()`), before any of that case's own
    /// database access (`startIdleLoops`/`syncAllAccountsOnce`/...) —
    /// otherwise a foreground return immediately after a real suspend would
    /// have those calls racing GRDB's still-active suspension and failing
    /// with `SQLITE_INTERRUPT`/`SQLITE_ABORT` for no reason.
    func resumeSharedDatabaseIfNeeded() async {
        guard await markDatabaseResumed() else { return }
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    private func requestAPNsToken() async throws -> String {
        #if os(iOS)
        do {
            return try await PushTokenCenter.shared.requestToken()
        } catch PushTokenCenter.PushTokenError.notificationPermissionDenied {
            throw PushError.notificationPermissionDenied
        } catch {
            throw PushError.noDeviceToken
        }
        #else
        throw PushError.unsupportedPlatform
        #endif
    }

    /// `https://` required; `http://localhost`/`http://127.0.0.1` (any
    /// port) exempted for local dev against a relay run with `go run`
    /// on the same machine (plan: "リレー URL 入力 (https 必須、ローカル開発時
    /// のみ http://localhost 許可)"). Returns `nil` for anything else,
    /// including a URL that fails to parse at all.
    /// `nonisolated`: pure string parsing, no `AppEnvironment` state —
    /// called both from `@MainActor` call sites in this file and from
    /// `CloudAccountDirectory` (M11), which isn't `@MainActor`.
    nonisolated static func validatedRelayURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), let url = components.url else { return nil }
        if components.scheme == "https" { return url }
        if components.scheme == "http", let host = components.host, host == "localhost" || host == "127.0.0.1" {
            return url
        }
        return nil
    }
}
