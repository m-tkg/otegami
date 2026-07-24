import Foundation
import Testing
@testable import MailTransportMailCore
import MailCore
import MailTransport
import OtegamiCore

/// Pure unit tests (no network, no dev mailstack — unlike this file's
/// integration-test siblings, so these always run under `make test`) for
/// `MailCoreSMTPSession.isRetriableWithoutAuth(auth:error:)`, the decision
/// point behind the AUTH-not-supported fallback documented on
/// `MailCoreSMTPSession.connect(auth:)`. Constructs the same shape of
/// `NSError` mailcore2 actually produces (domain `MailCoreErrorDomain`,
/// code `.errorAuthentication`, `userInfo["MCOSMTPResponseCodeKey"]` set to
/// the raw SMTP response code, boxed as `NSNumber(int32: ...)` — see
/// `nsError(code:responseCode:domain:)`'s doc comment on why that exact
/// boxing matters here) rather than talking to a real server, so these
/// assert the classification logic itself: 502/503/504-class responses
/// ("the server doesn't support AUTH at all") should retry without
/// authenticating, while 535-class responses ("these credentials are
/// wrong") must not.
struct SMTPAuthFallbackTests {
    private static let authFailure = Int(MailCoreError.errorAuthentication.rawValue)
    private static let connectionFailure = Int(MailCoreError.errorConnection.rawValue)

    /// `responseCode` is boxed as an `NSNumber` wrapping a C `int` (`Int32`
    /// on this platform), matching exactly what mailcore2's own
    /// `MCOSMTPOperation._errorFromNativeOperation` does
    /// (`userInfo[MCOSMTPResponseCodeKey] = @(op->lastSMTPResponseCode())`,
    /// `lastSMTPResponseCode()` returns a C `int`) — confirmed against the
    /// dev mailstack's real Mailpit that a plain `Int` literal here does
    /// **not** reproduce the same dynamic type Swift gives that value
    /// (`Int32`, not `Int`), which is exactly the bug
    /// `isAuthCommandRejectedAsUnsupported(_:)` had until this was caught
    /// by `SMTPIntegrationTests.nonBlankUsernameAgainstNoAuthServerStillConnects`
    /// against the real server: `as? Int` silently returned `nil` for an
    /// `Int32`-boxed `NSNumber`, so every real-world response code failed
    /// to classify as retriable. A plain-`Int` version of this helper would
    /// have let that regression slip back in undetected.
    private static func nsError(code: Int, responseCode: Int32?, domain: String = MailCoreErrorDomain) -> NSError {
        var userInfo: [String: Any] = [:]
        if let responseCode {
            userInfo["MCOSMTPResponseCodeKey"] = NSNumber(value: responseCode)
        }
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }

    @Test("502/503/504/500 command-not-implemented-class responses retry without auth", arguments: [500, 502, 503, 504] as [Int32])
    func authCommandUnsupportedResponseCodesRetry(responseCode: Int32) {
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        let error = Self.nsError(code: Self.authFailure, responseCode: responseCode)
        #expect(MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("real credential-rejection responses (530/534/535/550/553) are never retried", arguments: [530, 534, 535, 550, 553] as [Int32])
    func realAuthFailureResponseCodesDoNotRetry(responseCode: Int32) {
        let auth = MailAuth.password(username: "test1@otegami.test", password: "wrong-password")
        let error = Self.nsError(code: Self.authFailure, responseCode: responseCode)
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("an authentication error with no attached SMTP response code is treated as a real failure (safe side)")
    func missingResponseCodeDoesNotRetry() {
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        let error = Self.nsError(code: Self.authFailure, responseCode: nil)
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("a non-authentication MailCore error (e.g. connectionFailed) never retries, even with a 502-looking response code")
    func nonAuthenticationErrorCodeDoesNotRetry() {
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        let error = Self.nsError(code: Self.connectionFailure, responseCode: 502)
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("an error from a foreign NSError domain never retries")
    func foreignDomainDoesNotRetry() {
        let auth = MailAuth.password(username: "test1@otegami.test", password: "test1234")
        let error = Self.nsError(code: Self.authFailure, responseCode: 502, domain: "SomeOtherDomain")
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("a blank SMTP username never retries — it already skipped AUTH up front, so this path shouldn't be reachable for it")
    func blankUsernameDoesNotRetry() {
        let auth = MailAuth.password(username: "", password: "")
        let error = Self.nsError(code: Self.authFailure, responseCode: 502)
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }

    @Test("XOAuth2 auth never retries — clearing username/password alone wouldn't skip its login path anyway")
    func xoauth2AuthDoesNotRetry() {
        let auth = MailAuth.xoauth2(username: "test1@gmail.com", accessToken: "some-token")
        let error = Self.nsError(code: Self.authFailure, responseCode: 502)
        #expect(!MailCoreSMTPSession.isRetriableWithoutAuth(auth: auth, error: error))
    }
}
