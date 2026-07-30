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
            let box = ContinuationResumeBox(continuation)
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { @Sendable [weak self] callbackURL, error in
                // Mirrors `GoogleOAuth.ASWebAuthenticationSessionRunner`'s
                // fix for a real macOS crash — see that type's doc comment
                // for the full mechanism. Short version: this completion
                // handler is *not* guaranteed to run on the main thread
                // (observed firing on the `com.apple.SafariLaunchAgent` XPC
                // reply queue on macOS). `@Sendable` on this closure
                // literal is load-bearing: without it, Swift 6's
                // closure-isolation inference (SE-0420) assumes this
                // `@escaping`, non-`@Sendable`, unannotated-ObjC-block
                // closure inherits this method's `@MainActor` isolation
                // (since it's written textually inside a `@MainActor`
                // method) and inserts a *dynamic* isolation check at the
                // closure's entry to assert that — the check that actually
                // trapped in production, before any of this closure's own
                // code ran. `@Sendable` makes the closure explicitly
                // nonisolated, matching reality, so there's nothing left to
                // assert. Touching `activeSession` (main-actor isolated)
                // still needs an explicit hop rather than
                // `MainActor.assumeIsolated` (we're genuinely not on the
                // main actor here).
                if let self {
                    Task { @MainActor in
                        self.activeSession = nil
                    }
                }
                // Resuming the continuation itself is thread-safe from any
                // queue; `ContinuationResumeBox` guards against a firing
                // more than once from ever double-resuming.
                if let callbackURL {
                    box.resume(returning: callbackURL)
                    return
                }
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    box.resume(throwing: MicrosoftOAuthError.userCancelled)
                    return
                }
                box.resume(throwing: error ?? MicrosoftOAuthError.missingAuthorizationCode)
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
                box.resume(throwing: MicrosoftOAuthError.userCancelled)
                return
            }
        }
    }
}

/// Thread-safe once-only `CheckedContinuation` resume guard. See
/// `GoogleOAuth.ASWebAuthenticationSessionRunner`'s identical private type
/// for the full rationale — deliberately *not* `@MainActor` since the
/// completion handler above can fire off the main actor.
private final class ContinuationResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
