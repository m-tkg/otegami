import Foundation

/// Mirrors `GoogleOAuth.AuthorizationSessionRunning` — abstracts "present
/// the authorization URL in a web browser and wait for the callback
/// redirect" so `MicrosoftOAuthClientTests` can inject a fake flow instead
/// of real `ASWebAuthenticationSession` UI.
public protocol AuthorizationSessionRunning: Sendable {
    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL
}
