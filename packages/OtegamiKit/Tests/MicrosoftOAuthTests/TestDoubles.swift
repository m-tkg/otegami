import Foundation
import OAuthKit
import OAuthKitTestSupport
@testable import MicrosoftOAuth

/// `FakeAuthorizationFlow`/`FakeRefreshTokenStore`/`FakeTokenRefresher`/
/// `StubURLProtocol` now live in `OAuthKitTestSupport` (shared,
/// byte-identical fakes with `GoogleOAuthTests`'s previous copies — see
/// that target's `TestDoubles.swift` for the full rationale of each). Only
/// two pieces of glue are needed here:
/// - `FakeAuthorizationFlow` conforms to the shared
///   `OAuthKit.AuthorizationSessionRunning` base, but `MicrosoftOAuthClient`
///   expects this module's own local refinement (see that protocol's doc
///   comment for why it's a refinement, not a type alias).
/// - `OAuthKitTestSupport.FakeTokenRefresher<Tokens>` is generic (since
///   `MicrosoftTokenRefreshing` lives in this package, not
///   `OAuthKitTestSupport`); fixing `Tokens` via a local type alias
///   (rather than leaving every call site to infer it) is what keeps this
///   target's existing `FakeTokenRefresher { _ in fatalError(...) }` call
///   sites unchanged — a bare generic call can't infer `Tokens` from a
///   closure whose body is just `fatalError(...)`.
///
/// `StubURLProtocol`/`FakeRefreshTokenStore` need no such glue — a plain
/// `URLProtocol` subclass has no "redundant conformance" concern, and
/// `RefreshTokenStoring` is already the same shared protocol both providers
/// use (see `MicrosoftOAuth.RefreshTokenStoring`'s doc comment) — so this
/// target uses `OAuthKitTestSupport`'s copies of both directly.
extension FakeAuthorizationFlow: MicrosoftOAuth.AuthorizationSessionRunning {}

extension OAuthKitTestSupport.FakeTokenRefresher: MicrosoftTokenRefreshing where Tokens == MicrosoftOAuthTokens {}
typealias FakeTokenRefresher = OAuthKitTestSupport.FakeTokenRefresher<MicrosoftOAuthTokens>
