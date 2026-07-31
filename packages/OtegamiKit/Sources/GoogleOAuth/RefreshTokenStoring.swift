import Foundation
import OAuthKit
import Security

/// `RefreshTokenStoring`/`KeychainRefreshTokenStore` now live in `OAuthKit`
/// (shared, byte-identical implementation between `GoogleOAuth` and
/// `MicrosoftOAuth`) — these type aliases keep `GoogleOAuth.RefreshTokenStoring`/
/// `GoogleOAuth.KeychainRefreshTokenStore` resolving exactly as before for
/// any existing qualified reference. Unlike `AuthorizationSessionRunning`,
/// a plain alias (not a refining protocol) is safe here: nothing in the app
/// conforms to both providers' `RefreshTokenStoring` simultaneously, so
/// there's no "redundant conformance" risk in making this the literal same
/// nominal protocol as `MicrosoftOAuth.RefreshTokenStoring`.
public typealias RefreshTokenStoring = OAuthKit.RefreshTokenStoring
public typealias KeychainRefreshTokenStore = OAuthKit.KeychainRefreshTokenStore
