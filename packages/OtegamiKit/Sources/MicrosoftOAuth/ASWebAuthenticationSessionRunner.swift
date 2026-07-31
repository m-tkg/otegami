import AuthenticationServices
import Foundation
import OAuthKit

/// The real `AuthorizationSessionRunning` backend for Microsoft — mirrors
/// `GoogleOAuth.ASWebAuthenticationSessionRunner`'s own doc comment exactly:
/// a specialization of the shared `OAuthKit.ASWebAuthenticationSessionRunner`
/// generic implementation, fixed to throw `MicrosoftOAuthError`. Existing
/// call sites (`MicrosoftOAuth.ASWebAuthenticationSessionRunner(presentationContextProvider:...)`)
/// need no changes.
///
/// `ASWebAuthenticationSession` intercepts navigation to `callbackURLScheme`
/// itself, so no `CFBundleURLTypes` entry is needed in `Info.plist` for
/// this to work — **but** unlike Google's client-type convention (which
/// needs no redirect URI registered in Google Cloud Console at all),
/// Microsoft/Azure AD *does* require the exact redirect URI to be
/// registered ahead of time for the app registration (see
/// `MicrosoftOAuthEndpoints`'s doc comment and `docs/oauth-setup.md`).
public typealias ASWebAuthenticationSessionRunner = OAuthKit.ASWebAuthenticationSessionRunner<MicrosoftOAuthError>

/// `MicrosoftOAuthClient.init(sessionRunner: any AuthorizationSessionRunning, ...)`
/// expects `MicrosoftOAuth`'s own local `AuthorizationSessionRunning`
/// refinement (see that protocol's doc comment) — this conditional
/// conformance is what makes the type alias above usable there.
extension OAuthKit.ASWebAuthenticationSessionRunner: AuthorizationSessionRunning where Failure == MicrosoftOAuthError {}
