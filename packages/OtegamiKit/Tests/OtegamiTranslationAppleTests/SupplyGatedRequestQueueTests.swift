import Testing
@testable import OtegamiTranslationApple

/// 2026-07-30 (実機フィードバック — 退行「テスト翻訳を実行」がスピナーの
/// まま無反応になり、メール本文画面でも翻訳できなくなった): a real
/// `Translation.TranslationSession` can't be constructed in a test process
/// at all (no public initializer — see `TranslationLanguageLocaleTests`'s
/// doc comment), so `TranslationSessionCoordinator` itself can't be unit
/// tested against "the supplier never shows up". `SupplyGatedRequestQueue`
/// was extracted specifically so that scenario — and the exactly-once-
/// resume/no-hang guarantees this whole rewrite exists to provide — are
/// directly testable with plain `String`/`Int` stand-ins for `Target`/
/// `Session`.
@MainActor
@Suite("SupplyGatedRequestQueue")
struct SupplyGatedRequestQueueTests {
    private struct TimeoutMarker: Error, Equatable {}

    @Test("a request whose supply never arrives times out with the configured error, rather than hanging forever")
    func neverSuppliedTimesOutRatherThanHanging() async throws {
        // `timeoutSeconds: 0` — resolves almost immediately, so this test
        // itself stays fast; `requestSupply` deliberately never calls
        // `supply(_:)`, simulating exactly the real-device bug (a screen
        // with no `.translationTask` host mounted anywhere in its tree).
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 0,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _ in }
        )

        await #expect(throws: TimeoutMarker.self) {
            _ = try await queue.perform(target: "en") { session in session }
        }
    }

    @Test("a supply that arrives before the timeout resolves the request normally")
    func suppliedBeforeTimeoutSucceeds() async throws {
        var requestedTargets: [String] = []
        // A generous timeout (5s) that the `supply(_:)` call below —
        // driven manually once `requestSupply` confirms the request
        // actually reached the front of the queue — should never come
        // close to hitting.
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target in requestedTargets.append(target) }
        )

        let resultTask = Task {
            try await queue.perform(target: "en") { session in session * 2 }
        }
        while requestedTargets.isEmpty {
            await Task.yield()
        }
        #expect(requestedTargets == ["en"])
        await queue.supply(42)

        let result = try await resultTask.value
        #expect(result == 84)
    }

    @Test("a supply that arrives after its request already timed out is a safe no-op, not a crash or a double-resume")
    func lateSupplyAfterTimeoutIsSafeNoOp() async throws {
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 0,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _ in }
        )

        await #expect(throws: TimeoutMarker.self) {
            _ = try await queue.perform(target: "en") { session in session }
        }
        // The request already timed out and moved on — this must not
        // crash (a `CheckedContinuation` traps on double-resume) or throw.
        await queue.supply(999)
    }

    @Test("two concurrent requests both eventually complete — neither waits forever behind the other")
    func concurrentRequestsBothEventuallyComplete() async throws {
        var requestedTargets: [String] = []
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target in
                requestedTargets.append(target)
            }
        )

        async let first = queue.perform(target: "en") { session in session + 1 }
        async let second = queue.perform(target: "ja") { session in session + 2 }

        // This queue processes one request at a time — give the first
        // `perform` a moment to actually enqueue and call `requestSupply`
        // before asserting on it (both `perform` calls above return
        // immediately with unstarted work until awaited/scheduled; a tiny
        // yield is enough since no real async work happens before the
        // first `requestSupply` call).
        while requestedTargets.isEmpty {
            await Task.yield()
        }
        #expect(requestedTargets == ["en"])
        await queue.supply(10)

        while requestedTargets.count < 2 {
            await Task.yield()
        }
        #expect(requestedTargets == ["en", "ja"])
        await queue.supply(20)

        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == 11)
        #expect(secondResult == 22)
    }

    @Test("supplying twice for the same pending request only runs the operation once")
    func doubleSupplyOnlyRunsOnce() async throws {
        var callCount = 0
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _ in }
        )

        let resultTask = Task {
            try await queue.perform(target: "en") { session in
                callCount += 1
                return session
            }
        }
        await Task.yield()
        await queue.supply(1)
        // A second supply before anything else was enqueued must be a
        // no-op (`pendingOperation` is already `nil` by then) — not a
        // second invocation of the same operation.
        await queue.supply(2)

        let result = try await resultTask.value
        #expect(result == 1)
        #expect(callCount == 1)
    }
}
