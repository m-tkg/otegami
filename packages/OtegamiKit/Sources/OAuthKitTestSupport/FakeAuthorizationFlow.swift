import Foundation
import OAuthKit

/// Stands in for `ASWebAuthenticationSessionRunner` (the plan's
/// "FakeAuthorizationFlow"): returns a canned callback URL (or throws a
/// canned error) instead of presenting any real UI, so
/// `GoogleOAuthClientTests`/`MicrosoftOAuthClientTests` can drive
/// `requestAuthorization()` end to end without
/// `AuthenticationServices`/a presentation anchor.
///
/// Conforms only to the shared `OAuthKit.AuthorizationSessionRunning` base
/// protocol here — `GoogleOAuthTests`/`MicrosoftOAuthTests` each add a
/// same-target, zero-code `extension FakeAuthorizationFlow:
/// GoogleOAuth.AuthorizationSessionRunning {}` (their own local refinement
/// protocol; see that protocol's doc comment in `OAuthKit` for why it's a
/// refinement rather than a shared type alias) so the fake is usable
/// wherever their client code expects its provider-qualified protocol.
public final class FakeAuthorizationFlow: OAuthKit.AuthorizationSessionRunning, @unchecked Sendable {
    public enum Outcome {
        case callback(URL)
        case failure(Error)
    }

    public var outcome: Outcome
    /// Records what was actually requested, so a test can assert the
    /// authorization URL carried the right PKCE challenge/state/scope
    /// without needing the client to expose those internals directly.
    public private(set) var lastAuthorizationURL: URL?
    public private(set) var lastCallbackURLScheme: String?

    public init(outcome: Outcome) {
        self.outcome = outcome
    }

    public func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        lastAuthorizationURL = authorizationURL
        lastCallbackURLScheme = callbackURLScheme
        switch outcome {
        case .callback(let url): return url
        case .failure(let error): throw error
        }
    }
}
