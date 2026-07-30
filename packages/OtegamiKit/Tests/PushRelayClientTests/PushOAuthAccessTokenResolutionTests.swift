import Foundation
import Testing

@testable import PushRelayClient

/// Unit coverage for `PushOAuthAccessTokenResolution` — the timeout-racing
/// helper `NotificationService.oauthAccessToken(for:)` uses to turn a
/// `.oauth2` account's refresh-token-to-access-token exchange into a single
/// `nil`-or-token result. Every case here uses a fake `tokenFetch` closure
/// with small, fixed delays (`Task.sleep`) — no real Keychain, network, or
/// `GoogleOAuth`/`MicrosoftOAuth` type is touched, so this suite stays fast
/// and deterministic under plain `swift test`.
@Suite("PushOAuthAccessTokenResolution")
struct PushOAuthAccessTokenResolutionTests {
    @Test("returns the token when tokenFetch succeeds well within the timeout")
    func returnsTokenOnSuccess() async {
        let result = await PushOAuthAccessTokenResolution.resolve(timeout: 5) {
            "access-token-123"
        }
        #expect(result == "access-token-123")
    }

    @Test("returns nil when tokenFetch throws")
    func returnsNilOnThrow() async {
        struct FakeError: Error {}
        let result = await PushOAuthAccessTokenResolution.resolve(timeout: 5) {
            throw FakeError()
        }
        #expect(result == nil)
    }

    @Test("returns nil when tokenFetch is slower than the timeout, without waiting for it to finish")
    func returnsNilOnTimeout() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await PushOAuthAccessTokenResolution.resolve(timeout: 0.05) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "too-late"
        }
        let elapsed = start.duration(to: clock.now)
        #expect(result == nil)
        // Generous upper bound (well under the 5s the fake fetch itself
        // sleeps for) — this asserts the race actually short-circuits
        // rather than happening to also finish quickly for some other
        // reason.
        #expect(elapsed < .seconds(2))
    }

    @Test("returns the token when tokenFetch finishes just before the timeout")
    func returnsTokenWhenFastEnough() async {
        let result = await PushOAuthAccessTokenResolution.resolve(timeout: 2) {
            try await Task.sleep(nanoseconds: 10_000_000)
            return "just-in-time"
        }
        #expect(result == "just-in-time")
    }
}
