import Foundation
import OAuthKit
import OAuthKitTestSupport
@testable import GoogleOAuth

/// `FakeAuthorizationFlow`/`FakeRefreshTokenStore`/`FakeTokenRefresher`/
/// `StubURLProtocol` now live in `OAuthKitTestSupport` (shared,
/// byte-identical fakes between `GoogleOAuthTests` and
/// `MicrosoftOAuthTests`) — these conformances/aliases are the only
/// `GoogleOAuth`-specific glue left: `FakeAuthorizationFlow` conforms to the
/// shared `OAuthKit.AuthorizationSessionRunning` base, but
/// `GoogleOAuthClient` expects this module's own local refinement (see that
/// protocol's doc comment for why it's a refinement, not a type alias).
extension FakeAuthorizationFlow: GoogleOAuth.AuthorizationSessionRunning {}

/// `OAuthKitTestSupport.FakeTokenRefresher<Tokens>` is generic since
/// `GoogleTokenRefreshing` lives in this package, not `OAuthKitTestSupport`
/// (which can't depend on it without a circular dependency). This
/// conditional conformance plus the type alias below reproduce the original
/// concrete, non-generic `FakeTokenRefresher` every call site in this
/// target already uses (`FakeTokenRefresher { _ in fatalError(...) }`) —
/// fixing `Tokens` via the alias, rather than leaving every call site to
/// infer it from a `fatalError`-bodied closure alone, is what keeps those
/// call sites unchanged (a bare generic `FakeTokenRefresher { ... }` call
/// can't infer `Tokens` from a closure whose body is just `fatalError(...)`).
extension OAuthKitTestSupport.FakeTokenRefresher: GoogleTokenRefreshing where Tokens == GoogleOAuthTokens {}
typealias FakeTokenRefresher = OAuthKitTestSupport.FakeTokenRefresher<GoogleOAuthTokens>

// `PeopleAPIStubURLProtocol` moved to `GooglePeopleTests` (its own
// TestDoubles.swift) together with `GooglePeopleAvatarClientTests` when the
// `GooglePeople` target was split out of `GoogleOAuth` — see that file's
// doc comment for why it stays a separate stub type rather than reusing
// `OAuthKitTestSupport.StubURLProtocol` (used by `GoogleOAuthClientTests`
// in this target).
