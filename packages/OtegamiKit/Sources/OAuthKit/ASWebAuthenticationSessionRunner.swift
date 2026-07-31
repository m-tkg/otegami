import AuthenticationServices
import Foundation

/// The real `AuthorizationSessionRunning` backend, wrapping
/// `ASWebAuthenticationSession`. Deliberately the *only* file in this
/// target that imports `AuthenticationServices` — everything else
/// (`PKCE`, `RefreshTokenStoring`, `TokenStore`) is plain
/// `Foundation`/`Security` and stays testable without a UI runtime at all.
///
/// Generic over `Failure` (a provider's `GoogleOAuthError`/`MicrosoftOAuthError`,
/// both conforming to `OAuthFlowError`) so the same implementation — byte-
/// identical between the two providers before this consolidation — can throw
/// each provider's own error type without either package depending on the
/// other. `GoogleOAuth`/`MicrosoftOAuth` each expose this via a
/// `public typealias ASWebAuthenticationSessionRunner = OAuthKit
/// .ASWebAuthenticationSessionRunner<TheirError>` plus a same-module
/// extension conforming that concrete specialization to their own local
/// `AuthorizationSessionRunning` refinement (see that protocol's doc
/// comment for why it's a refinement rather than a shared type alias) —
/// existing call sites (`GoogleOAuth.ASWebAuthenticationSessionRunner(...)`)
/// need no changes at all.
///
/// No `CFBundleURLTypes` entry is needed for the custom-scheme redirect URI
/// each provider's `Endpoints` type builds:
/// `ASWebAuthenticationSession` intercepts navigation to `callbackURLScheme`
/// itself, inside its own ephemeral browser tab, before the system would
/// ever try to hand the URL off to an app via ordinary URL-scheme routing.
/// That's the whole point of the API over a plain `SFSafariViewController`
/// + `application(_:open:)` deep link.
@MainActor
public final class ASWebAuthenticationSessionRunner<Failure: OAuthFlowError>: NSObject, AuthorizationSessionRunning, @unchecked Sendable {
    // `@unchecked Sendable`: every stored property is only ever read/written
    // from the main actor (this class is itself `@MainActor`-isolated), so
    // there's no actual data race — but the compiler can't verify that for
    // an `NSObject` subclass holding a delegate reference, hence the
    // explicit opt-out rather than plain `Sendable`. `AuthorizationSessionRunning`
    // requires `Sendable` because `GoogleOAuthClient`/`MicrosoftOAuthClient`
    // (actors) store one as a `let` and call into it from their own
    // isolation domain; the `await` at the call site is what actually hops
    // back to the main actor to run `ASWebAuthenticationSession`.
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
            let box = ContinuationResumeBox(continuation)
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackURLScheme
            ) { @Sendable [weak self] callbackURL, error in
                // `ASWebAuthenticationSession` does *not* guarantee this
                // completion handler runs on the main thread — on macOS it
                // was observed firing synchronously on the
                // `com.apple.SafariLaunchAgent` XPC reply queue (from
                // `_endSessionWithCallbackURL:error:`), not main.
                //
                // `@Sendable` on this closure literal is load-bearing, not
                // decorative: this is an `@escaping (URL?, Error?) -> Void`
                // parameter (an imported ObjC block type) with no actor
                // annotation, and it's written textually inside this
                // `@MainActor`-isolated method. Swift 6's closure-isolation
                // inference (SE-0420) therefore infers this closure as
                // MainActor-isolated by default and inserts a *dynamic*
                // isolation check at its entry to assert that assumption
                // holds at runtime — that inserted check
                // (`swift_task_isCurrentExecutorWithFlagsImpl` /
                // `_dispatch_assert_queue_fail`) is what actually trapped
                // in production, before any of this closure's own code
                // ever ran: wrapping just the `activeSession` mutation
                // below in a `Task { @MainActor in }` hop (an earlier,
                // insufficient version of this fix) did *not* help, because
                // the trap fires at closure entry regardless of what the
                // body does. iOS happened not to expose this (its delivery
                // queue is main more often, though never contractually
                // guaranteed) but macOS did. Marking the closure
                // `@Sendable` makes it explicitly nonisolated — matching
                // reality — so the compiler has nothing to assert and
                // doesn't insert the check. Do *not* use
                // `MainActor.assumeIsolated` instead: we're genuinely not
                // on the main actor here, so that would just relocate the
                // same false assumption.
                if let self {
                    Task { @MainActor in
                        self.activeSession = nil
                    }
                }
                // Resuming the continuation itself is thread-safe from any
                // queue; `ContinuationResumeBox` just guards the (now
                // possible, since we no longer serialize everything onto
                // the main actor) case of this firing more than once from
                // guaranteeing only the first resume wins.
                if let callbackURL {
                    box.resume(returning: callbackURL)
                    return
                }
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    box.resume(throwing: Failure.userCancelled)
                    return
                }
                box.resume(throwing: error ?? Failure.missingAuthorizationCode)
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
                box.resume(throwing: Failure.userCancelled)
                return
            }
        }
    }
}

/// Thread-safe once-only `CheckedContinuation` resume guard. Deliberately
/// *not* `@MainActor` (unlike `OtegamiTranslationApple.ResumeBox`, which
/// this mirrors the intent of) — `ASWebAuthenticationSessionRunner`'s
/// completion handler can fire off the main actor (see its doc comment
/// above), so guarding "already resumed" must not itself require hopping
/// onto the main actor first.
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
