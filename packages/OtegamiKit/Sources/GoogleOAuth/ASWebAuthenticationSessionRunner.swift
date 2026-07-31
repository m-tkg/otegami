import AuthenticationServices
import Foundation
import OAuthKit

/// The real `AuthorizationSessionRunning` backend for Gmail — a
/// specialization of the shared `OAuthKit.ASWebAuthenticationSessionRunner`
/// generic implementation (byte-identical to Microsoft's before this
/// consolidation) fixed to throw `GoogleOAuthError`. Existing call sites
/// (`GoogleOAuth.ASWebAuthenticationSessionRunner(presentationContextProvider:...)`)
/// need no changes: this type alias plus the conformance extension below
/// reproduce the exact same public surface the standalone type used to have.
public typealias ASWebAuthenticationSessionRunner = OAuthKit.ASWebAuthenticationSessionRunner<GoogleOAuthError>

/// `GoogleOAuthClient.init(sessionRunner: any AuthorizationSessionRunning, ...)`
/// expects `GoogleOAuth`'s own local `AuthorizationSessionRunning` refinement
/// (not the shared `OAuthKit` base directly — see that protocol's doc
/// comment) — this conditional conformance is what makes the type alias
/// above usable there.
extension OAuthKit.ASWebAuthenticationSessionRunner: AuthorizationSessionRunning where Failure == GoogleOAuthError {}
