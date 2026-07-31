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
/// Records whether a fake `tokenFetch` ran past a cancellation point,
/// without relying on wall-clock timing (Task #204 — see `returnsNilOnTimeout`).
private actor CompletionMarker {
    private(set) var reachedCompletion = false
    func markReachedCompletion() {
        reachedCompletion = true
    }
}

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

    // Task #204: `ci-app` flaked 3 runs in a row on this test's old
    // wall-clock assertion (`elapsed < .seconds(2)`), with elapsed times up
    // to 8.37s — once even exceeding the fake fetch's own 5s delay, which
    // ruled out "the loser task simply ran to completion" as the whole
    // story. A CPU-constrained reproduction (1200 synthetic CPU-bound tests
    // running in parallel alongside this one, mimicking `ci-app`'s ~1211
    // concurrent tests) confirmed the real cause: `withTaskGroup` correctly
    // cancels the losing `tokenFetch` task (`Task.sleep` throws
    // `CancellationError` immediately, well before its 5s deadline), but
    // under scheduler contention, resuming that *already-cancelled* task's
    // continuation and unwinding `withTaskGroup`'s implicit wait for it can
    // itself take several seconds of queueing — inflating elapsed time for
    // reasons unrelated to whether cancellation worked. See docs/ci.md.
    //
    // So instead of inferring "was it cancelled?" from wall-clock elapsed
    // time (flaky under CI's parallel test load), this asserts it directly:
    // the fake fetch flips `reachedCompletion` only if its `Task.sleep`
    // finishes *without* being cancelled. `resolve` returning before that
    // happens is exactly the "without waiting for it to finish" behavior
    // this test is named for, independent of how long that takes in wall
    // time on a loaded machine.
    @Test("returns nil when tokenFetch is slower than the timeout, without waiting for it to finish")
    func returnsNilOnTimeout() async {
        let marker = CompletionMarker()
        let result = await PushOAuthAccessTokenResolution.resolve(timeout: 0.05) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            // Only reached if the sleep above ran to completion instead of
            // being interrupted by cancellation.
            await marker.markReachedCompletion()
            return "too-late"
        }
        #expect(result == nil)
        #expect(await marker.reachedCompletion == false)
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
