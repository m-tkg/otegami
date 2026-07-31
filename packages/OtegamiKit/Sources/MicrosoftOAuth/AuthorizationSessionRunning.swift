import Foundation
import OAuthKit

/// `MicrosoftOAuth`'s own `AuthorizationSessionRunning` — mirrors
/// `GoogleOAuth.AuthorizationSessionRunning` exactly: a zero-extra-requirement
/// refinement of `OAuthKit.AuthorizationSessionRunning` rather than a plain
/// type alias to it, so this stays a distinct nominal protocol from
/// `GoogleOAuth`'s copy (see `OAuthKit.AuthorizationSessionRunning`'s doc
/// comment for why — `NotificationService`'s
/// `UnreachableAuthorizationSessionRunner` conforms to both simultaneously).
public protocol AuthorizationSessionRunning: OAuthKit.AuthorizationSessionRunning {}
