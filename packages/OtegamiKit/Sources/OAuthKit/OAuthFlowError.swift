import Foundation

/// The two error cases `ASWebAuthenticationSessionRunner` itself needs to be
/// able to throw, abstracted so the generic runner doesn't have to know
/// which provider's error enum (`GoogleOAuthError`/`MicrosoftOAuthError`) it
/// is instantiated with. A plain no-payload `enum` case automatically
/// satisfies a `static var` protocol requirement of the same name (a
/// standard Swift "enum case as protocol witness" — see e.g.
/// `GoogleOAuthError.userCancelled`), so conforming an existing provider
/// error enum to this protocol needs no extra code beyond the conformance
/// declaration itself.
public protocol OAuthFlowError: Error, Sendable {
    /// The user dismissed/cancelled the `ASWebAuthenticationSession` sheet.
    static var userCancelled: Self { get }
    /// The callback URL had no `code` parameter at all (and no `error`
    /// either) — malformed redirect. Used as the fallback when
    /// `ASWebAuthenticationSession`'s completion handler fires with neither
    /// a callback URL nor an `Error`.
    static var missingAuthorizationCode: Self { get }
}
