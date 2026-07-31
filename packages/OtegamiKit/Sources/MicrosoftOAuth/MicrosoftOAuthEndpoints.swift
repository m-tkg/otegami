import Foundation
import OAuthKit

/// Fixed OAuth2 endpoints + per-build configuration (client id, scope) for
/// Outlook.com/Office 365's Authorization Code + PKCE flow — mirrors
/// `GoogleOAuth.GoogleOAuthEndpoints` (Task #116 第2段: "GoogleOAuth 実装を
/// ひな形に MicrosoftOAuth を実装"). Microsoft deprecated IMAP Basic auth
/// entirely (plan: "Microsoft は IMAP Basic 認証を廃止済み → XOAUTH2 必須"),
/// so this is the only way otegami can support Outlook.com/Office 365 IMAP.
public struct MicrosoftOAuthEndpoints: Sendable, Equatable {
    /// `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` —
    /// the `common` tenant covers both personal Microsoft accounts
    /// (Outlook.com/Hotmail) and Microsoft 365 work/school accounts with a
    /// single endpoint, which is why "Outlook" and "Office365" on
    /// `AccountTypeSelectionView` both resolve to this exact same
    /// `MicrosoftOAuthEndpoints` value — the two buttons exist because the
    /// plan calls for them as separate, recognizable entry points, but
    /// there is no server-side difference between the two flows.
    public var authorizationEndpoint: URL
    /// `https://login.microsoftonline.com/common/oauth2/v2.0/token`.
    public var tokenEndpoint: URL

    public var clientId: String
    /// `https://outlook.office.com/IMAP.AccessAsUser.All
    /// https://outlook.office.com/SMTP.Send offline_access openid email`
    /// (plan-specified). `offline_access` is what makes Azure AD issue a
    /// `refresh_token` (Microsoft's equivalent of Google's
    /// `access_type=offline`); `openid email` is what makes the token
    /// response's `id_token` carry an `email` (or at least
    /// `preferred_username`) claim — see `MicrosoftOAuthClient
    /// .fetchUserEmail(idToken:)`'s doc comment for why that claim is
    /// enough and no separate Microsoft Graph `User.Read` scope/call is
    /// needed (unlike Google, which needs a userinfo endpoint round trip).
    public var scope: String
    /// A fixed custom URL scheme, **not** derived from `clientId` the way
    /// `GoogleOAuthEndpoints.redirectURI` is — Microsoft app registrations
    /// (unlike Google's "iOS" client type) have no such built-in, registration-
    /// free convention. This exact URI must be registered by hand in Azure
    /// Portal, under the app registration's "Mobile and desktop applications"
    /// platform → "Redirect URIs" (see `docs/oauth-setup.md`'s Microsoft
    /// section). `ASWebAuthenticationSession` still intercepts navigation to
    /// this scheme itself before any system URL-scheme routing, so no
    /// `Info.plist` `CFBundleURLTypes` entry is needed app-side either
    /// (`ASWebAuthenticationSessionRunner`'s doc comment) — only the Azure
    /// Portal-side registration is required, which is the one genuinely
    /// extra manual step Microsoft's flow needs that Google's doesn't.
    public var redirectURI: String

    public init(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientId: String,
        scope: String,
        redirectURI: String
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientId = clientId
        self.scope = scope
        self.redirectURI = redirectURI
    }

    /// The fixed redirect URI every otegami build uses — see `redirectURI`'s
    /// doc comment for why this is a static literal rather than derived
    /// from `clientId`. Exposed as a `static let` (not buried inline in
    /// `standard(clientId:)`) so `docs/oauth-setup.md`'s Azure Portal
    /// instructions and `MicrosoftOAuthConfig` can both reference the exact
    /// same value without risking the two drifting apart.
    public static let standardRedirectURI = "com.mtkg.otegami.msauth://oauth2redirect"

    /// The real Microsoft endpoints, for `clientId` (read from
    /// `Info.plist`'s `OTEGAMI_MICROSOFT_CLIENT_ID`, itself sourced from
    /// `Config/Local.xcconfig` — see `docs/oauth-setup.md`).
    public static func standard(clientId: String) -> MicrosoftOAuthEndpoints {
        MicrosoftOAuthEndpoints(
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            clientId: clientId,
            scope: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid email",
            redirectURI: standardRedirectURI
        )
    }

    /// Mirrors `GoogleOAuthEndpoints.authorizationURL(pkce:state:promptConsent:)`.
    /// Always includes `prompt=select_account` — Microsoft's closest
    /// equivalent to always showing an account chooser (there is no direct
    /// Microsoft analog to Google's `prompt=consent`; `offline_access` above
    /// already guarantees a `refresh_token` on first consent without needing
    /// a forced-reconsent flag the way Google does), so a user with multiple
    /// Microsoft accounts signed into the browser isn't silently signed in
    /// as whichever one Safari remembers.
    func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    var callbackURLScheme: String {
        URL(string: redirectURI)?.scheme ?? "com.mtkg.otegami.msauth"
    }
}
