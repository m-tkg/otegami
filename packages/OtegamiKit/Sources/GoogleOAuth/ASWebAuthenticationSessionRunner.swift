import AuthenticationServices
import Foundation

/// The real `AuthorizationSessionRunning` backend, wrapping
/// `ASWebAuthenticationSession`. Deliberately the *only* file in this
/// package that imports `AuthenticationServices` — everything else
/// (`GoogleOAuthClient`, `TokenStore`, PKCE/endpoint building) is plain
/// `Foundation`/`Security` and stays testable without a UI runtime at all.
///
/// No `CFBundleURLTypes` entry is needed for the custom-scheme redirect URI
/// `GoogleOAuthEndpoints` builds (`com.googleusercontent.apps.<...>:/oauth2redirect`):
/// `ASWebAuthenticationSession` intercepts navigation to `callbackURLScheme`
/// itself, inside its own ephemeral browser tab, before the system would
/// ever try to hand the URL off to an app via ordinary URL-scheme routing.
/// That's the whole point of the API over a plain `SFSafariViewController`
/// + `application(_:open:)` deep link.
@MainActor
public final class ASWebAuthenticationSessionRunner: NSObject, AuthorizationSessionRunning, @unchecked Sendable {
    // `@unchecked Sendable`: every stored property is only ever read/written
    // from the main actor (this class is itself `@MainActor`-isolated), so
    // there's no actual data race — but the compiler can't verify that for
    // an `NSObject` subclass holding a delegate reference, hence the
    // explicit opt-out rather than plain `Sendable`. `AuthorizationSessionRunning`
    // requires `Sendable` because `GoogleOAuthClient` (an actor) stores one
    // as a `let` and calls into it from its own isolation domain; the
    // `await` at the call site is what actually hops back to the main actor
    // to run `ASWebAuthenticationSession`.
    private let presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    /// Kept alive for the duration of the session — `ASWebAuthenticationSession`
    /// doesn't retain itself, and letting it deallocate mid-flow silently
    /// tears down the presented sheet.
    private var activeSession: ASWebAuthenticationSession?

    public init(presentationContextProvider: ASWebAuthenticationPresentationContextProviding) {
        self.presentationContextProvider = presentationContextProvider
    }

    public func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    continuation.resume(throwing: GoogleOAuthError.userCancelled)
                    return
                }
                continuation.resume(throwing: error ?? GoogleOAuthError.missingAuthorizationCode)
            }
            session.presentationContextProvider = presentationContextProvider
            // Ephemeral: doesn't share cookies/state with the user's
            // ordinary Safari session, so a previous Gmail account staying
            // signed in in Safari never silently short-circuits the account
            // picker on re-auth.
            session.prefersEphemeralWebBrowserSession = true
            activeSession = session
            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: GoogleOAuthError.userCancelled)
                return
            }
        }
    }
}
