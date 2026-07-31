import GoogleOAuth

/// Bridges `GoogleProfilePhotoAvatarResolver` (an actor with no reachable
/// path to `AppEnvironment` at construction time — it's built inside
/// `AppEnvironment.init()` alongside the other `AvatarImageResolving`
/// sources, before `database`/`tokenStore`/`accounts` exist at all) to the
/// live Gmail account list and `TokenStore` it needs at *call* time, once
/// avatar resolution actually starts happening (well after `init()` has
/// returned). Mirrors `PendingSendCoordinator`'s `weak var environment`/
/// `configure(environment:)` two-phase wiring (see that type's doc comment
/// for the identical reasoning): created with a `nil` `environment` by
/// `AppEnvironment`'s `gmailAccessTokenBridge` property (a default-valued
/// stored property, so it already exists before `init()`'s body runs), then
/// wired to `self` as the very last step of `init()`.
///
/// `@MainActor` (not an `actor`) specifically so `configure(environment:)`
/// can be called synchronously from `AppEnvironment.init()` itself, the same
/// constraint `PendingSendCoordinator.configure(environment:)` is under.
/// `@unchecked Sendable`: every stored property (`environment`) is only ever
/// read/written while isolated to the main actor — the compiler can't verify
/// that automatically for a plain (non-`actor`) class, but the isolation
/// itself makes it safe, matching this codebase's other `@unchecked
/// Sendable` main-actor-isolated types (e.g. `ASWebAuthenticationSessionRunner`'s
/// doc comment).
@MainActor
final class GmailAccessTokenBridge: GmailAccessTokenProviding, @unchecked Sendable {
    private weak var environment: AppEnvironment?

    func configure(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Before `configure(environment:)` has run (a narrow window: only
    /// between `avatarImageResolver`'s construction and the
    /// `configure(environment:)` call a few dozen lines later in the same
    /// `init()`) this returns `[]`, same as "no Gmail accounts yet" — never
    /// a crash, just a resolver that quietly has nothing to offer yet.
    func gmailAccountIds() async -> [String] {
        guard let environment else { return [] }
        return environment.accounts.filter { $0.kind == .gmail }.map(\.id)
    }

    func accessToken(for accountId: String) async throws -> String {
        guard let environment, let tokenStore = environment.tokenStore else {
            throw GoogleOAuth.TokenStoreError.missingRefreshToken
        }
        return try await tokenStore.accessToken(for: accountId)
    }
}
