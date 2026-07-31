import Foundation
import OAuthKit
import Security

/// `RefreshTokenStoring`/`KeychainRefreshTokenStore` now live in `OAuthKit`
/// (shared, byte-identical implementation with `GoogleOAuth`'s previous
/// copy) — mirrors `GoogleOAuth.RefreshTokenStoring`'s own doc comment.
public typealias RefreshTokenStoring = OAuthKit.RefreshTokenStoring
public typealias KeychainRefreshTokenStore = OAuthKit.KeychainRefreshTokenStore
