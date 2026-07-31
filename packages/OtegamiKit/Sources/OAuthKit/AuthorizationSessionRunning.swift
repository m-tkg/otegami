import Foundation

/// Abstracts "present the authorization URL in a web browser and wait for
/// the callback redirect" — the one piece of the OAuth flow that has to
/// touch UI (`ASWebAuthenticationSession`, which needs a presentation
/// anchor). Everything else in `GoogleOAuthClient`/`MicrosoftOAuthClient`
/// (building the authorization URL, parsing the callback, exchanging the
/// code, refreshing) is plain `URLSession` traffic and needs no such
/// abstraction — this protocol is what lets each provider's client tests
/// exercise "auth code received → token exchange → refresh" end-to-end with
/// a `FakeAuthorizationFlow` standing in for real Safari/
/// `ASWebAuthenticationSession` UI, per the plan's "FakeAuthorizationFlow +
/// ローカル HTTP スタブ" design.
///
/// This is the shared, provider-agnostic base. `GoogleOAuth`/`MicrosoftOAuth`
/// each declare their own local `AuthorizationSessionRunning` protocol that
/// refines this one (rather than re-exporting this type directly under a
/// module-qualified name) — a plain type alias to the same underlying
/// protocol would make `GoogleOAuth.AuthorizationSessionRunning` and
/// `MicrosoftOAuth.AuthorizationSessionRunning` literally the same nominal
/// protocol, and at least one call site in the app (`NotificationService`'s
/// `UnreachableAuthorizationSessionRunner`) conforms to both simultaneously —
/// which the compiler rejects as a "redundant conformance" once they're the
/// same type. Two distinct (but structurally identical, zero-extra-requirement)
/// refining protocols keep that call site's dual conformance valid while
/// still centralizing the one actual requirement here.
public protocol AuthorizationSessionRunning: Sendable {
    /// Presents `authorizationURL` and waits for the system to capture a
    /// redirect to `callbackURLScheme`. Returns the full callback URL
    /// (query parameters and all) on success; throws the provider's
    /// `.userCancelled` error if the user dismisses the sheet, or rethrows
    /// any other presentation-layer failure.
    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL
}
