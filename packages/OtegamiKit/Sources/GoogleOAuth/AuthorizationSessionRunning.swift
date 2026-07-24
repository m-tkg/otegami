import Foundation

/// Abstracts "present the authorization URL in a web browser and wait for
/// the callback redirect" — the one piece of the OAuth flow that has to
/// touch UI (`ASWebAuthenticationSession`, which needs a presentation
/// anchor). Everything else in `GoogleOAuthClient` (building the
/// authorization URL, parsing the callback, exchanging the code, refreshing)
/// is plain `URLSession` traffic and needs no such abstraction — this
/// protocol is what lets `GoogleOAuthClientTests` exercise "auth code
/// received → token exchange → refresh" end-to-end with a
/// `FakeAuthorizationFlow` standing in for real Safari/`ASWebAuthenticationSession`
/// UI, per the plan's "FakeAuthorizationFlow + ローカル HTTP スタブ" design.
public protocol AuthorizationSessionRunning: Sendable {
    /// Presents `authorizationURL` and waits for the system to capture a
    /// redirect to `callbackURLScheme`. Returns the full callback URL
    /// (query parameters and all) on success; throws
    /// `GoogleOAuthError.userCancelled` if the user dismisses the sheet, or
    /// rethrows any other presentation-layer failure.
    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL
}
