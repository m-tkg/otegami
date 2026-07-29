import AuthenticationServices
import Foundation

/// Mirrors `GoogleOAuth.ASWebAuthenticationSessionRunner` — the real
/// `AuthorizationSessionRunning` backend. See that type's doc comment for
/// the full rationale (identical here): `ASWebAuthenticationSession`
/// intercepts navigation to `callbackURLScheme` itself, so no
/// `CFBundleURLTypes` entry is needed in `Info.plist` for this to work —
/// **but** unlike Google's client-type convention (which needs no redirect
/// URI registered in Google Cloud Console at all), Microsoft/Azure AD *does*
/// require the exact redirect URI to be registered ahead of time for the
/// app registration (see `MicrosoftOAuthEndpoints`'s doc comment and
/// `docs/oauth-setup.md`).
@MainActor
public final class ASWebAuthenticationSessionRunner: NSObject, AuthorizationSessionRunning, @unchecked Sendable {
    private let presentationContextProvider: ASWebAuthenticationPresentationContextProviding
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
                    continuation.resume(throwing: MicrosoftOAuthError.userCancelled)
                    return
                }
                continuation.resume(throwing: error ?? MicrosoftOAuthError.missingAuthorizationCode)
            }
            session.presentationContextProvider = presentationContextProvider
            // Ephemeral: doesn't share cookies/state with the user's
            // ordinary Safari session, matching GoogleOAuth's identical
            // choice (a previously-signed-in Microsoft account staying
            // signed in in Safari never silently short-circuits the account
            // picker on re-auth).
            session.prefersEphemeralWebBrowserSession = true
            activeSession = session
            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: MicrosoftOAuthError.userCancelled)
                return
            }
        }
    }
}
