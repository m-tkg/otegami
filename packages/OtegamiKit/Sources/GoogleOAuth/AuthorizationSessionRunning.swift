import Foundation
import OAuthKit

/// `GoogleOAuth`'s own `AuthorizationSessionRunning` — a zero-extra-requirement
/// refinement of `OAuthKit.AuthorizationSessionRunning` rather than a plain
/// type alias to it. See `OAuthKit.AuthorizationSessionRunning`'s doc
/// comment for why: a shared type alias would make this the *same* nominal
/// protocol as `MicrosoftOAuth.AuthorizationSessionRunning`, and
/// `NotificationService`'s `UnreachableAuthorizationSessionRunner` conforms
/// to both simultaneously — the compiler rejects that as a "redundant
/// conformance" once they're identical. This refinement keeps
/// `GoogleOAuth.AuthorizationSessionRunning` a distinct type (as it always
/// was) while still sharing the one actual requirement's definition.
public protocol AuthorizationSessionRunning: OAuthKit.AuthorizationSessionRunning {}
