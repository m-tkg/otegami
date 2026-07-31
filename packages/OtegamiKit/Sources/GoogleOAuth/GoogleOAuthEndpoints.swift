import Foundation
import OAuthKit

/// Fixed OAuth2 endpoints + per-build configuration (client id, scope) for
/// Gmail's Authorization Code + PKCE flow. Kept as its own value type
/// (rather than hardcoded inside `GoogleOAuthClient`) so `GoogleOAuthClientTests`
/// can point `tokenEndpoint`/`authorizationEndpoint` at a local stub without
/// touching real Google infrastructure — only `GoogleOAuthClientTests`
/// substitutes those two URLs; production always uses `.standard(clientId:)`.
public struct GoogleOAuthEndpoints: Sendable, Equatable {
    /// `https://accounts.google.com/o/oauth2/v2/auth` (plan-specified).
    public var authorizationEndpoint: URL
    /// `https://oauth2.googleapis.com/token` (plan-specified).
    public var tokenEndpoint: URL
    /// `https://www.googleapis.com/oauth2/v3/userinfo` — used once, right
    /// after the first token exchange, to learn the signed-in account's
    /// email address. See `GoogleOAuthClient.fetchUserEmail(accessToken:)`'s
    /// doc comment for why: the plan's scope alone (`https://mail.google.com/`)
    /// carries no identity claim an `id_token` could report, and XOAUTH2
    /// needs the email *before* the first IMAP connect can even be
    /// attempted, so there's no way to discover it via IMAP either. `email`
    /// is the minimal additional scope that unlocks this endpoint without
    /// requesting `profile`/`openid` we don't otherwise need.
    public var userInfoEndpoint: URL

    public var clientId: String
    /// Space-separated OAuth2 scope string. `https://mail.google.com/` is
    /// the plan-mandated IMAP/SMTP scope; `.../auth/userinfo.email` is the
    /// deliberate addition above. Two more were added later still, both for
    /// アバター強化バッチ「Google プロフィール写真」:
    ///
    /// - `.../auth/contacts.other.readonly` — read-only access to "other
    ///   contacts" (people the user has emailed but never explicitly
    ///   saved), used by `GooglePeopleAvatarClient
    ///   .fetchOtherContactsPhotoIndex(accessToken:)`.
    /// - `.../auth/contacts.readonly` — read-only access to the user's
    ///   explicitly-saved Contacts, used by `GooglePeopleAvatarClient
    ///   .fetchConnectionsPhotoIndex(accessToken:)`. A sender who *is* a
    ///   saved Contact never appears in `otherContacts`, so this second
    ///   scope covers the population the first one structurally can't.
    ///
    /// Both are Google **sensitive scopes** (unlike the two above, which are
    /// non-sensitive/restricted-adjacent) — see `docs/oauth-setup.md`'s
    /// scope section for what that means for a publicly-distributed build's
    /// OAuth consent screen verification. An account authorized before
    /// these scopes existed doesn't have them until the user reconnects
    /// (`AccountEditView`'s "再認証" button reruns this same `scope` string,
    /// so one re-consent is enough) — `GoogleProfilePhotoAvatarResolver`
    /// treats a 401/403 from either People API endpoint as "this account's
    /// token doesn't have that particular scope yet" and quietly skips just
    /// that source (falling back to the next avatar source entirely only if
    /// both are unavailable) rather than forcing reauth.
    ///
    /// A fifth was added later still: `.../auth/userinfo.profile` — on-device
    /// diagnosis (Task #54) confirmed `people/me` (used by
    /// `GooglePeopleAvatarClient.fetchSelfPhotoIndexOutcome(accessToken:)`
    /// to resolve the signed-in user's own avatar) was 403ing with
    /// `Request requires one of the following scopes: [profile]`, even
    /// though `otherContacts`/`connections` worked fine — the doc comment
    /// on `fetchSelfPhotoIndexOutcome` had assumed `contacts.other.readonly`
    /// alone would satisfy `people.get`, which turned out to not hold for
    /// the caller's own profile specifically. `profile` is a Google
    /// **non-sensitive/basic scope** (same tier as `userinfo.email`, not
    /// the sensitive tier `contacts.other.readonly`/`contacts.readonly`
    /// are in), so it adds no extra consent-screen review burden. Same
    /// `isSatisfied(byGrantedScope:)`-driven one-time re-consent story as
    /// the two scopes above applies to existing accounts.
    public var scope: String
    /// `com.googleusercontent.apps.<reversed client id>:/oauth2redirect`
    /// (plan-specified) — Google's documented redirect URI convention for
    /// "iOS" OAuth client types (no client secret), which don't require
    /// pre-registering the exact redirect URI the way a web client would.
    public var redirectURI: String

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        userInfoEndpoint: URL,
        clientId: String,
        scope: String,
        redirectURI: String
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.userInfoEndpoint = userInfoEndpoint
        self.clientId = clientId
        self.scope = scope
        self.redirectURI = redirectURI
    }

    /// The real Google endpoints, for `clientId` (e.g. read from
    /// `Info.plist`'s `GOOGLE_OAUTH_CLIENT_ID`, itself sourced from
    /// `Config/Local.xcconfig` — see `docs/oauth-setup.md`).
    public static func standard(clientId: String) -> GoogleOAuthEndpoints {
        GoogleOAuthEndpoints(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            userInfoEndpoint: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!,
            clientId: clientId,
            scope: "https://mail.google.com/ https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/contacts.other.readonly https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/userinfo.profile",
            redirectURI: "\(Self.redirectScheme(forClientId: clientId)):/oauth2redirect"
        )
    }

    /// `com.googleusercontent.apps.<reversed client id>` — Google's fixed
    /// convention for the custom URL scheme an "iOS" OAuth client type's
    /// redirect URI uses. A client id looks like
    /// `1234567890-abc123.apps.googleusercontent.com`; this reverses the
    /// dot-separated components (`com.googleusercontent.apps.1234567890-abc123`).
    /// `ASWebAuthenticationSession` intercepts navigation to this scheme
    /// itself (see `ASWebAuthenticationSessionRunner`'s doc comment), so —
    /// unlike a universal-link redirect — nothing needs to be registered in
    /// `Info.plist`'s `CFBundleURLTypes` for this to work.
    public static func redirectScheme(forClientId clientId: String) -> String {
        clientId.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Builds the full authorization-request URL: `authorizationEndpoint`
    /// plus every query parameter the Authorization Code + PKCE flow needs
    /// (`response_type=code`, `code_challenge`/`code_challenge_method=S256`,
    /// `state` for CSRF protection, `access_type=offline` so Google issues a
    /// `refresh_token`, and `include_granted_scopes=true` — Google's
    /// documented incremental-authorization flag, harmless here since
    /// `scope` is always the full set rather than an incremental subset, but
    /// the recommended default for any request that might run against an
    /// account with a pre-existing grant).
    ///
    /// `promptConsent` controls whether `prompt=consent` is added:
    ///
    /// - `true` (the default, and always what a brand-new account uses,
    ///   `AppEnvironment.requestGmailAuthorization`/`createGmailAccount`)
    ///   forces the consent screen every time — required for a first-time
    ///   grant (by default a repeat consent for the same client/scope
    ///   combination silently omits the `refresh_token`, so the very first
    ///   exchange must force it) and for `reauthenticateGmailAccount`'s
    ///   "the stored grant doesn't cover everything `scope` asks for"
    ///   branch, where forcing the screen is also what lets the user
    ///   actually grant the new scope.
    /// - `false` omits `prompt` entirely — Google then reuses whatever
    ///   consent the user already gave (silently returning a fresh code
    ///   with no screen at all, no "アプリは Google で確認されていません"
    ///   warning either) when it can. `reauthenticateGmailAccount` passes
    ///   this once it has confirmed (`isSatisfied(byGrantedScope:)`) the
    ///   account's last-known granted scope already covers `scope` — this
    ///   is the whole point of the "毎回警告が出るのがつらい" fix: a token
    ///   refresh from an already-fully-scoped account doesn't need the
    ///   user to click through anything again. A token response obtained
    ///   this way may omit `refresh_token` (Google's documented behavior
    ///   for a prompt-less repeat grant) — `TokenStore.storeInitialTokens`
    ///   already leaves the previously-stored refresh token untouched in
    ///   that case, so this doesn't lose the account's ability to sync.
    func authorizationURL(pkce: PKCE, state: String, promptConsent: Bool = true) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        if promptConsent {
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = queryItems
        return components.url!
    }

    /// Whether `grantedScope` — the scope string Google actually granted a
    /// previous token, as returned by `TokenStore.diagnosticScope(for:)` —
    /// already covers everything `self.scope` currently requests. `nil`
    /// (no cached/queryable grant, or the diagnostic lookup itself failed)
    /// is always "not satisfied" — the safe default is to fall back to
    /// forcing the consent screen rather than silently skipping it when
    /// this can't actually be confirmed.
    ///
    /// Compared as sets of whitespace-separated scope tokens rather than
    /// string equality: Google isn't guaranteed to echo requested scopes
    /// back in the same order, and a grant that happens to be a superset of
    /// `scope` (e.g. one that predates a scope later being *removed* from
    /// this build) still counts as satisfied.
    public func isSatisfied(byGrantedScope grantedScope: String?) -> Bool {
        guard let grantedScope else { return false }
        let required = Set(scope.split(separator: " "))
        let granted = Set(grantedScope.split(separator: " "))
        return required.isSubset(of: granted)
    }

    /// The scheme `ASWebAuthenticationSession`/`AuthorizationSessionRunning`
    /// watch for — just `redirectURI`'s scheme component, extracted once
    /// here so callers don't each re-parse it.
    var callbackURLScheme: String {
        URL(string: redirectURI)?.scheme ?? Self.redirectScheme(forClientId: clientId)
    }
}
