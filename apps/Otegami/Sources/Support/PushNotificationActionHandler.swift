#if os(iOS)
import Foundation
import GoogleOAuth
import MailTransport
import MailTransportMailCore
import MicrosoftOAuth
import OtegamiStore
import SyncEngine

/// Glue between a push notification action button (`AppDelegate.
/// userNotificationCenter(_:didReceive:withCompletionHandler:)`) and
/// `SyncEngine.PushNotificationActionExecutor.execute(...)`: resolves the
/// `auth`/`sessionFactory` closures that executor needs using this app's own
/// credential stores, entirely independent of `AppEnvironment` (which
/// `AppDelegate` has no access to — see `AppEnvironment`'s doc comment on
/// being a `SwiftUI` `App`'s `@State`, not reachable from a
/// `UIApplicationDelegate` callback).
///
/// `resolveAuth(for:)` mirrors `AppEnvironment+Auth.swift`'s `auth(for:)` —
/// same `.password`/`.oauth2` → `.gmail`/`.microsoft` branching — but drops
/// every UI-facing side effect that method has (`needsReauth` persistence,
/// avatar cache invalidation): there's no UI in scope here to update, and a
/// failed resolution already degrades correctly by simply returning `nil`
/// (`PushNotificationActionExecutor.execute`'s own doc comment: every
/// credential-resolution failure just skips the best-effort IMAP replay,
/// leaving the local DB write — already durable by that point — for the
/// next normal sync to reconcile with the server).
enum PushNotificationActionHandler {
    /// Opens the shared `AppDatabase` (App Group container — same one
    /// `NotificationService`/the main app both use) and runs `action`
    /// against it via `PushNotificationActionExecutor.execute`. A silent
    /// no-op if this build has no App Group configured or the shared
    /// database can't be opened — mirrors every other failure mode in this
    /// flow (no UI in scope to report to, see this type's doc comment).
    static func handle(action: PushNotificationAction, accountId: String, uidNext: Int) async {
        guard let appGroupIdentifier = OtegamiAppGroup.identifier,
              let database = try? AppDatabase.makeShared(appGroupIdentifier: appGroupIdentifier)
        else { return }
        await PushNotificationActionExecutor.execute(
            action: action,
            accountId: accountId,
            uidNext: uidNext,
            database: database,
            auth: { account in await resolveAuth(for: account) },
            sessionFactory: { config in MailCoreIMAPSession(config: config) }
        )
    }

    /// Mirrors `AppEnvironment.auth(for:)`'s branching (`AppEnvironment+
    /// Auth.swift`) minus its UI-facing side effects — see this type's doc
    /// comment. Returns `nil` (rather than throwing) on any failure: no
    /// caller here can do anything with a thrown error either way.
    private static func resolveAuth(for account: AccountRecord) async -> MailAuth? {
        switch account.authType {
        case .password:
            let credentialStore = KeychainCredentialStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)
            guard let password = try? credentialStore.password(forAccountId: account.id) else { return nil }
            return .password(username: account.imapUsername, password: password)

        case .oauth2:
            switch account.kind {
            case .gmail:
                guard let endpoints = GoogleOAuthConfig.endpoints else { return nil }
                let client = GoogleOAuthClient(
                    endpoints: endpoints,
                    sessionRunner: UnreachableAuthorizationSessionRunner(),
                    urlSession: URLSession(configuration: .ephemeral)
                )
                let tokenStore = GoogleOAuth.TokenStore(refresher: client)
                guard let accessToken = try? await tokenStore.accessToken(for: account.id) else { return nil }
                return .xoauth2(username: account.imapUsername, accessToken: accessToken)

            case .microsoft:
                guard let endpoints = MicrosoftOAuthConfig.endpoints else { return nil }
                let client = MicrosoftOAuthClient(
                    endpoints: endpoints,
                    sessionRunner: UnreachableAuthorizationSessionRunner(),
                    urlSession: URLSession(configuration: .ephemeral)
                )
                let tokenStore = MicrosoftOAuth.TokenStore(refresher: client)
                guard let accessToken = try? await tokenStore.accessToken(for: account.id) else { return nil }
                return .xoauth2(username: account.imapUsername, accessToken: accessToken)

            case .generic, .icloud:
                // Shouldn't be reachable — only `.gmail`/`.microsoft`-kind
                // accounts are ever created with `authType: .oauth2` (mirrors
                // `AppEnvironment.auth(for:)`'s identical case here).
                return nil
            }
        }
    }
}

/// `GoogleOAuthClient`/`MicrosoftOAuthClient` both require a concrete
/// `AuthorizationSessionRunning` conformer at `init`, but `resolveAuth(for:)`
/// only ever calls `TokenStore.accessToken(for:)` — a plain silent refresh,
/// never the interactive `requestAuthorization()` flow that's the only
/// caller of `sessionRunner.run(authorizationURL:callbackURLScheme:)`.
/// Mirrors `NotificationService.swift`'s identically-purposed type: a
/// background push action has no UI to present a web authentication session
/// from, so a latent bug that somehow did reach this path degrades to "no
/// credential resolved" (this file's usual failure mode) rather than
/// crashing.
private struct UnreachableAuthorizationSessionRunner: GoogleOAuth.AuthorizationSessionRunning, MicrosoftOAuth.AuthorizationSessionRunning {
    struct UnexpectedCallError: Error {}

    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        throw UnexpectedCallError()
    }
}
#endif
