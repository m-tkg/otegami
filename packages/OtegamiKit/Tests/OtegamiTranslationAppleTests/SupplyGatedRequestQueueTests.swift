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

    /// 2026-07-30, 実機フィードバック — 2度目の退行の核心: `TranslationSessionCoordinator`
    /// の`requestSupply`実装が`TranslationSession.Configuration(source:
    /// target:)`を毎回新規に作っていた — 同じ言語ペアなら2つの独立した
    /// `Configuration`値は`==`で等価と判定される (実SDKで実測確認済み)
    /// ため、`.translationTask(_:action:)`(`.task(id:)`と同じ意味論、値が
    /// 「変化」した時だけ再発火) からは「同じ値の再代入」にしか見えず、
    /// 2回目以降のリクエストで二度と`attach(_:)`が呼ばれなかった。
    ///
    /// `SupplyGatedRequestQueue`自体は`Target`の等価性を一切見ない —
    /// キューから取り出した項目ごとに無条件で`requestSupply`を呼ぶだけ
    /// (`drainIfNeeded()`参照)。このテストは**それ自体を固定する** —
    /// 同じ`target`("ja")で2回連続リクエストしても、`requestSupply`が
    /// 律儀に2回呼ばれ、両方とも独立に`supply(_:)`で完了できることを
    /// 確認する。実際に壊れていたのは`TranslationSessionCoordinator`
    /// 側の`Configuration`の値としての等価性であって、この汎用キュー側の
    /// 「要求のたびに供給を求める」という契約自体は最初から健全だった、
    /// という切り分けをテストとして残す。
    @Test("requesting the exact same target twice in a row still calls requestSupply twice, and both requests complete")
    func sameTargetRequestedTwiceInARowBothGetSupplied() async throws {
        var requestedTargets: [String] = []
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target in requestedTargets.append(target) }
        )

        async let first = queue.perform(target: "ja") { session in session + 1 }
        while requestedTargets.count < 1 {
            await Task.yield()
        }
        #expect(requestedTargets == ["ja"])
        await queue.supply(100)
        let firstResult = try await first
        #expect(firstResult == 101)

        // Second request, same target as the first — must still trigger
        // its own independent `requestSupply` call, not be silently
        // skipped because the target "already matches" the previous one.
        async let second = queue.perform(target: "ja") { session in session + 2 }
        while requestedTargets.count < 2 {
            await Task.yield()
        }
        #expect(requestedTargets == ["ja", "ja"])
        await queue.supply(200)
        let secondResult = try await second
        #expect(secondResult == 202)
    }

    /// 2026-07-30, 実機フィードバック — 3度目の退行の核心 (「テスト翻訳は
    /// 成功するがメール翻訳は失敗する」、診断画面の記録: 3件連続の
    /// `translate`呼び出しのうち3件目だけ「セッションを取得できません
    /// でした」でタイムアウト): メール翻訳は本文を段落/チャンクごとに
    /// **1件ずつ順次`translate`を呼ぶ**設計だったため、複数リクエストが
    /// このキューへ次々積まれる。バグの核心は、`perform(target:operation:)`
    /// が呼ばれた**瞬間** (=キューに並んだ瞬間、まだ自分の番が来ていない
    /// かもしれない) からタイムアウトの時計を回し始めていたこと —
    /// 先行リクエストの処理に時間がかかるほど、後続リクエストは**自分の
    /// 番が来る前に**持ち時間を消費されてしまう。個々の処理自体は
    /// 十分速くても、キューで待たされた時間だけでタイムアウトしうる、
    /// という「行列に並んでいる間に自分の順番が来る前に受付終了時刻を
    /// 過ぎてしまう」ような理不尽な飢餓状態。
    ///
    /// このテストは意図的に「後の方のリクエストほど自分の番が来るまでの
    /// 累積待ち時間が長くなる」状況を再現する — 各リクエストの処理自体は
    /// `timeoutSeconds`より十分短いが、複数件が連続することで後の方の
    /// リクエストが実際に供給を求められる (=`requestSupply`が呼ばれる)
    /// 時刻そのものが`timeoutSeconds`を超えてしまう。修正前のコードでは
    /// このテストは**失敗する**(最後の方のリクエストがタイムアウトする)
    /// — 修正後は、タイムアウトの時計が「実際に供給を求めた時刻」を
    /// 起点にするため、全件が完了する。
    @Test("many requests queued in a burst all eventually complete, even though later ones wait behind earlier ones long enough that an enqueue-time-scoped timeout would have starved them")
    func manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay() async throws {
        // 1秒のタイムアウト予算に対し、1件あたり0.3秒かかる処理を5件 —
        // 5件目が実際に供給を求められるのは(4件目までの処理が終わった)
        // 約1.2秒後 — 「並んだ瞬間から1秒」ルールだったなら、5件目は
        // 自分の番が来るずっと前 (1.0秒時点) に力尽きていたはずの状況。
        let perItemDelayNanoseconds: UInt64 = 300_000_000
        // `queueRef`は`queue`自身をまだ構築し終わる前にその
        // `requestSupply`クロージャから参照される必要がある —
        // 空のBoxを先に宣言し、`queue`を作った直後に中身を入れる
        // (先に`let queue = ...`を書いてしまうと、まだ宣言されて
        // いない`queueRef`をそのクロージャ内で forward reference
        // することになりコンパイルエラーになる)。
        let queueRef = Box<SupplyGatedRequestQueue<Int, Int>>()
        let queue = SupplyGatedRequestQueue<Int, Int>(
            timeoutSeconds: 1,
            timeoutError: { TimeoutMarker() },
            requestSupply: { [weak queueRef] target in
                // 供給元 (実機では`.translationTask`のホストビュー) が
                // 即座にではなく、いくらか時間をかけて応答する状況を
                // シミュレートする — 実機ログの複数件連続翻訳と同じ形。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: perItemDelayNanoseconds)
                    await queueRef?.value?.supply(target)
                }
            }
        )
        queueRef.value = queue

        // `withTaskGroup`'s `addTask` closure hit a compiler limitation
        // ("pattern that the region-based isolation checker does not
        // understand how to check") capturing this `@MainActor`-isolated
        // `queue` — five explicit `async let`s (matching every other test
        // in this file) sidestep it and are just as concurrent for this
        // queue's purposes (all five `perform` calls start before any of
        // them can possibly resolve).
        func attempt(_ index: Int) async -> Result<Int, Error> {
            do {
                return .success(try await queue.perform(target: index) { session in session * 10 })
            } catch {
                return .failure(error)
            }
        }
        async let r0 = attempt(0)
        async let r1 = attempt(1)
        async let r2 = attempt(2)
        async let r3 = attempt(3)
        async let r4 = attempt(4)
        let (v0, v1, v2, v3, v4) = await (r0, r1, r2, r3, r4)
        let results = [v0, v1, v2, v3, v4]

        for (index, result) in results.enumerated() {
            switch result {
            case .success(let value):
                #expect(value == index * 10, "request \(index) succeeded but with the wrong value")
            case .failure(let error):
                Issue.record("request \(index) starved in the queue instead of completing: \(error)")
            }
        }
    }

    /// The same "many requests, no starvation" guarantee, but issued one at
    /// a time (each fully `await`ed before the next starts) — this is
    /// `MessageTranslator.translateAligned`'s actual real-world calling
    /// pattern (see that type's per-chunk loop) and, unlike the burst test
    /// above, was never actually broken (no queueing delay accumulates when
    /// nothing is queued ahead of a request) — kept as a companion so the
    /// "N requests in a row" guarantee is pinned for both calling shapes.
    @Test("many requests issued strictly sequentially all complete")
    func manySequentialRequestsAllComplete() async throws {
        let queueRef = Box<SupplyGatedRequestQueue<Int, Int>>()
        let queue = SupplyGatedRequestQueue<Int, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { [weak queueRef] target in
                Task { @MainActor in
                    await queueRef?.value?.supply(target)
                }
            }
        )
        queueRef.value = queue

        for index in 0..<8 {
            let result = try await queue.perform(target: index) { session in session + 1 }
            #expect(result == index + 1)
        }
    }
}

/// Plain mutable reference box — `manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay`/
/// `manySequentialRequestsAllComplete` need `requestSupply`'s closure to
/// call back into the very `queue` it's still being constructed as part
/// of; a `weak` capture through this box (rather than capturing `queue`
/// itself, which doesn't exist yet at closure-literal-evaluation time)
/// sidesteps that ordering problem the same way `TranslationSessionCoordinator
/// .init`'s `lazy var requestQueue` does for the identical reason. Starts
/// empty (`init()`) so it can be declared *before* the object it will
/// eventually hold, then filled in right after that object's own `init`
/// returns.
@MainActor
private final class Box<T: AnyObject> {
    weak var value: T?
    init() {}
}
