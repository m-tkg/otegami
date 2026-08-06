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
        // `supply(_:for:)`, simulating exactly the real-device bug (a
        // screen with no `.translationTask` host mounted anywhere in its
        // tree).
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 0,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _, _ in }
        )

        await #expect(throws: TimeoutMarker.self) {
            _ = try await queue.perform(target: "en") { session in session }
        }
    }

    @Test("a supply that arrives before the timeout resolves the request normally")
    func suppliedBeforeTimeoutSucceeds() async throws {
        var requestedTargets: [String] = []
        var tickets: [SupplyGatedRequestQueue<String, Int>.Ticket] = []
        // A generous timeout (5s) that the `supply(_:for:)` call below —
        // driven manually once `requestSupply` confirms the request
        // actually reached the front of the queue — should never come
        // close to hitting.
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target, ticket in
                requestedTargets.append(target)
                tickets.append(ticket)
            }
        )

        let resultTask = Task {
            try await queue.perform(target: "en") { session in session * 2 }
        }
        while requestedTargets.isEmpty {
            await Task.yield()
        }
        #expect(requestedTargets == ["en"])
        await queue.supply(42, for: tickets[0])

        let result = try await resultTask.value
        #expect(result == 84)
    }

    @Test("a supply that arrives after its request already timed out is a safe no-op, not a crash or a double-resume")
    func lateSupplyAfterTimeoutIsSafeNoOp() async throws {
        var tickets: [SupplyGatedRequestQueue<String, Int>.Ticket] = []
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 0,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _, ticket in tickets.append(ticket) }
        )

        await #expect(throws: TimeoutMarker.self) {
            _ = try await queue.perform(target: "en") { session in session }
        }
        // The request already timed out and moved on — this must not
        // crash (a `CheckedContinuation` traps on double-resume) or throw,
        // even though `ticket` (the one this now-abandoned request's own
        // `requestSupply` call actually received) is exactly right — there
        // is simply nothing pending anymore to match it against
        // (`pendingTicket` was cleared by the timeout cleanup).
        await queue.supply(999, for: tickets[0])
    }

    @Test("two concurrent requests both eventually complete — neither waits forever behind the other, regardless of which the scheduler happens to start first")
    func concurrentRequestsBothEventuallyComplete() async throws {
        var requestedTargets: [String] = []
        var ticketsByTarget: [String: SupplyGatedRequestQueue<String, Int>.Ticket] = [:]
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target, ticket in
                requestedTargets.append(target)
                ticketsByTarget[target] = ticket
            }
        )

        // `async let`'s two child tasks are both scheduled onto this
        // `@MainActor`-isolated queue, but Swift makes *no* guarantee that
        // "first" (declared textually before "second") is the one whose
        // synchronous enqueue+drain prefix actually runs first — either
        // interleaving is valid concurrent scheduling. A previous version
        // of this test assumed `requestedTargets == ["en"]` after the
        // first poll and `== ["en", "ja"]` after the second — i.e. it
        // assumed declaration order matched drain order — and was
        // empirically flaky because of it (observed failing roughly 1 run
        // in 15 locally, `for i in 1..15; do swift test --filter
        // SupplyGatedRequestQueueTests; done`). This version makes no such
        // assumption: it discovers which target actually got requested
        // first and supplies/asserts accordingly, so it's deterministic
        // regardless of scheduling order while still checking the exact
        // same guarantee (both requests complete, each with the session
        // actually meant for it).
        async let first = queue.perform(target: "en") { session in session + 1 }
        async let second = queue.perform(target: "ja") { session in session + 2 }

        while requestedTargets.isEmpty {
            await Task.yield()
        }
        #expect(requestedTargets.count == 1)
        let firstRequested = requestedTargets[0]
        #expect(firstRequested == "en" || firstRequested == "ja")
        try await queue.supply(10, for: #require(ticketsByTarget[firstRequested]))

        while requestedTargets.count < 2 {
            await Task.yield()
        }
        #expect(Set(requestedTargets) == Set(["en", "ja"]))
        let secondRequested = requestedTargets[1]
        try await queue.supply(20, for: #require(ticketsByTarget[secondRequested]))

        let (firstResult, secondResult) = try await (first, second)
        if firstRequested == "en" {
            #expect(firstResult == 11)  // "en"'s operation: 10 + 1
            #expect(secondResult == 22) // "ja"'s operation: 20 + 2
        } else {
            #expect(firstResult == 21)  // "en"'s operation: 20 + 1
            #expect(secondResult == 12) // "ja"'s operation: 10 + 2
        }
    }

    @Test("supplying twice for the same pending request only runs the operation once")
    func doubleSupplyOnlyRunsOnce() async throws {
        var callCount = 0
        var tickets: [SupplyGatedRequestQueue<String, Int>.Ticket] = []
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { _, ticket in tickets.append(ticket) }
        )

        let resultTask = Task {
            try await queue.perform(target: "en") { session in
                callCount += 1
                return session
            }
        }
        while tickets.isEmpty {
            await Task.yield()
        }
        await queue.supply(1, for: tickets[0])
        // A second supply with the *same* (now-stale) ticket must be a
        // no-op (`pendingTicket`/`pendingOperation` are already `nil` by
        // then, matching `lateSupplyAfterTimeoutIsSafeNoOp`'s reasoning) —
        // not a second invocation of the same operation.
        await queue.supply(2, for: tickets[0])

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
    /// 律儀に2回呼ばれ (それぞれ別の`Ticket`を伴って)、両方とも独立に
    /// `supply(_:for:)`で完了できることを確認する。実際に壊れていたのは
    /// `TranslationSessionCoordinator`側の`Configuration`の値としての
    /// 等価性であって、この汎用キュー側の「要求のたびに供給を求める」
    /// という契約自体は最初から健全だった、という切り分けをテストとして
    /// 残す。
    @Test("requesting the exact same target twice in a row still calls requestSupply twice with distinct tickets, and both requests complete")
    func sameTargetRequestedTwiceInARowBothGetSupplied() async throws {
        var requestedTargets: [String] = []
        var tickets: [SupplyGatedRequestQueue<String, Int>.Ticket] = []
        let queue = SupplyGatedRequestQueue<String, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target, ticket in
                requestedTargets.append(target)
                tickets.append(ticket)
            }
        )

        async let first = queue.perform(target: "ja") { session in session + 1 }
        while requestedTargets.count < 1 {
            await Task.yield()
        }
        #expect(requestedTargets == ["ja"])
        await queue.supply(100, for: tickets[0])
        let firstResult = try await first
        #expect(firstResult == 101)

        // Second request, same target as the first — must still trigger
        // its own independent `requestSupply` call (with its own,
        // different `Ticket`), not be silently skipped because the target
        // "already matches" the previous one.
        async let second = queue.perform(target: "ja") { session in session + 2 }
        while requestedTargets.count < 2 {
            await Task.yield()
        }
        #expect(requestedTargets == ["ja", "ja"])
        #expect(tickets[0] != tickets[1])
        await queue.supply(200, for: tickets[1])
        let secondResult = try await second
        #expect(secondResult == 202)
    }

    /// Task #202 (実機フィードバック — 「一度成功した後は必ず翻訳が失敗
    /// する」、診断画面: 設定要求N回/セッション供給N回なのに、要求した
    /// リクエスト自身には一度も届かないままタイムアウトし続ける): this is
    /// the core regression test for the actual root cause found while
    /// investigating that report — see `SupplyGatedRequestQueue`'s
    /// top-level doc comment for the full real-device trace this
    /// reproduces here with plain `String`/`Int` stand-ins.
    ///
    /// The scenario: item A's own supplier never responds in time (A times
    /// out and the queue moves on to item B) — but the real-world
    /// supplier *eventually* does respond to A anyway, well after the
    /// fact (a `.translationTask` closure that kept running past its
    /// `Task`'s cooperative cancellation, exactly as `TranslationSessionHostView`'s
    /// closure — which never checks `Task.isCancelled` — can). Before
    /// Task #202's ticket fix, `SupplyGatedRequestQueue.supply(_:)` had no
    /// way to tell that late answer apart from a genuine answer to
    /// whatever's pending *now* (B) — it would silently run B's operation
    /// with A's stale session, permanently starving B's own real answer
    /// (which arrives to find `pendingOperation` already `nil`, a no-op).
    /// With the fix, the stale answer for A's (superseded) ticket is
    /// correctly ignored, and B's own, later answer is what actually
    /// resolves it.
    @Test("a late supply answering a ticket that's already been superseded by a newer pending item must not be consumed by that newer item")
    func lateSupplyForSupersededTicketDoesNotStealNewerItem() async throws {
        var tickets: [String: SupplyGatedRequestQueue<String, Int>.Ticket] = [:]
        let queue = SupplyGatedRequestQueue<String, Int>(
            // Real, non-zero timeout — item A actually needs to sit
            // "pending" for a moment while this test observes its ticket,
            // and this same value governs item B below too (this queue has
            // one shared `timeoutSeconds`, matching the one real
            // `TranslationSessionCoordinator` instance backing every
            // translation request in the app).
            timeoutSeconds: 1,
            timeoutError: { TimeoutMarker() },
            requestSupply: { target, ticket in tickets[target] = ticket }
        )

        // Item A: nothing ever supplies it, so it times out for real
        // (~1s) — simulating a `.translationTask` closure that's slow
        // enough that the coordinator gives up waiting before a session
        // ever arrives.
        await #expect(throws: TimeoutMarker.self) {
            _ = try await queue.perform(target: "A") { session in session }
        }
        let ticketForA = try #require(tickets["A"])

        // Item B: a fresh, unrelated request, queued *after* A's timeout
        // already fired and moved the queue forward.
        async let bResult = queue.perform(target: "B") { session in session + 100 }
        while tickets["B"] == nil {
            await Task.yield()
        }
        let ticketForB = try #require(tickets["B"])
        #expect(ticketForA != ticketForB)

        // The stale, late answer for A finally shows up — this must be
        // silently ignored, *not* consumed as if it were B's answer.
        await queue.supply(999, for: ticketForA)

        // B's own, genuine answer arrives next — this is the one that
        // must actually resolve `bResult`.
        await queue.supply(50, for: ticketForB)

        let result = try await bResult
        // 150 = 50 (B's real session) + 100. If the stale answer for A had
        // (bug) been allowed to steal B's slot, this would instead be
        // 1099 (= 999 + 100) — or, if B's own real answer had then further
        // been silently dropped as a no-op (`pendingOperation` already
        // consumed), `bResult` would still resolve to the stale 1099
        // rather than hang, since the operation already ran once.
        #expect(result == 150)
    }

    /// Task #202: the same race as `lateSupplyForSupersededTicketDoesNotStealNewerItem`,
    /// but hammered with many staggered items and late/duplicate/out-of-
    /// order `supply(_:for:)` calls thrown in — including answers for
    /// tickets that never even correspond to any real item — under actual
    /// concurrent scheduling (`async let` for every item, not a serial
    /// loop). Every legitimately-supplied item must still resolve with
    /// exactly its own session, and nothing must hang, crash, or accept a
    /// mismatched session. This is the stress variant `PENDING.md`/Task
    /// #202 asked for ("負荷をかけた状態でも確認する") — run this file's
    /// whole suite in a loop (`for i in 1..10; do swift test --filter
    /// SupplyGatedRequestQueueTests; done`) to additionally exercise
    /// scheduler-order variance across repeated runs.
    @Test("many items, interleaved with stray/late/mismatched supply calls, still each resolve with exactly their own session")
    func manyItemsSurviveStraySuppliesUnderLoad() async throws {
        let itemCount = 40
        var ticketsByTarget: [Int: SupplyGatedRequestQueue<Int, Int>.Ticket] = [:]
        let queueRef = Box<SupplyGatedRequestQueue<Int, Int>>()
        let queue = SupplyGatedRequestQueue<Int, Int>(
            timeoutSeconds: 5,
            timeoutError: { TimeoutMarker() },
            requestSupply: { [weak queueRef] target, ticket in
                ticketsByTarget[target] = ticket
                // Simulate a slow, jittery supplier (real-device session
                // bootstrap latency) *and* — the actual point of this
                // test — a handful of stray/mismatched answers arriving
                // around the same time: an answer for a ticket that
                // doesn't exist at all, and (once `target > 0`) a late
                // answer for the *previous* target's ticket, both of
                // which must be safely ignored rather than corrupting
                // `target`'s own eventual, correct answer.
                Task { @MainActor in
                    if let staleTicket = ticketsByTarget[target - 1] {
                        await queueRef?.value?.supply(-999, for: staleTicket)
                    }
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...20_000_000))
                    await queueRef?.value?.supply(target * 10, for: ticket)
                }
            }
        )
        queueRef.value = queue

        func attempt(_ index: Int) async -> Result<Int, Error> {
            do {
                return .success(try await queue.perform(target: index) { session in session + 1 })
            } catch {
                return .failure(error)
            }
        }

        // `withTaskGroup`'s `addTask` closure hit a compiler limitation
        // capturing this `@MainActor`-isolated `queue` (same issue noted
        // in `manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay`
        // below) — build the `async let`s programmatically isn't possible
        // either (no variadic `async let`), so this loop starts each
        // `Task` explicitly and collects them, which is equally concurrent
        // for this queue's purposes (every `perform` call is issued before
        // any of them can possibly resolve).
        let tasks = (0..<itemCount).map { index in
            Task { await attempt(index) }
        }
        var results: [Result<Int, Error>] = []
        results.reserveCapacity(itemCount)
        for task in tasks {
            results.append(await task.value)
        }

        for (index, result) in results.enumerated() {
            switch result {
            case .success(let value):
                #expect(value == index * 10 + 1, "item \(index) resolved with the wrong session (got a stray/mismatched one)")
            case .failure(let error):
                Issue.record("item \(index) starved instead of completing: \(error)")
            }
        }
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
            requestSupply: { [weak queueRef] target, ticket in
                // 供給元 (実機では`.translationTask`のホストビュー) が
                // 即座にではなく、いくらか時間をかけて応答する状況を
                // シミュレートする — 実機ログの複数件連続翻訳と同じ形。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: perItemDelayNanoseconds)
                    await queueRef?.value?.supply(target, for: ticket)
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
            requestSupply: { [weak queueRef] target, ticket in
                Task { @MainActor in
                    await queueRef?.value?.supply(target, for: ticket)
                }
            }
        )
        queueRef.value = queue

        for index in 0..<8 {
            let result = try await queue.perform(target: index) { session in session + 1 }
            #expect(result == index + 1)
        }
    }

    /// 2026-08-06 (実機フィードバック — Task #202 修正後もなお「設定要求
    /// N回/セッション供給N回、いずれも今回のリクエストには届きません
    /// でした」が再発): タイムアウトは**供給待ちの時間だけ**を計る —
    /// 供給が届いて`operation`が走り始めた後は、その実行が
    /// `timeoutSeconds`を跨いでも呼び出し元へタイムアウトを投げない
    /// (長文のバッチ翻訳・`prepareTranslation()`の言語パックダウンロード
    /// 確認は普通に10秒を跨ぐ)。修正前はこのテストは`TimeoutMarker`で
    /// 失敗する。
    @Test("an operation that outlives the item's own timeout still returns its result — the timeout only covers the waiting-for-supply phase")
    func suppliedOperationOutlivingTimeoutStillReturnsItsResult() async throws {
        let queueRef = Box<SupplyGatedRequestQueue<Int, Int>>()
        let queue = SupplyGatedRequestQueue<Int, Int>(
            timeoutSeconds: 1,
            timeoutError: { TimeoutMarker() },
            requestSupply: { [weak queueRef] target, ticket in
                Task { @MainActor in
                    await queueRef?.value?.supply(target, for: ticket)
                }
            }
        )
        queueRef.value = queue

        let result = try await queue.perform(target: 7) { session in
            // 供給は即座に届くが、operation 自体がタイムアウト予算 (1秒)
            // を跨いで走る — 実機の長文バッチ翻訳と同じ形。
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            return session * 10
        }
        #expect(result == 70)
    }

    /// 2026-08-06 (同上 — 供給ズレ退行の核心): 「supply 到着〜operation
    /// 完了」がその項目自身の`timeoutSeconds`を跨ぐと、修正前は (1) 項目
    /// A のタイムアウト掃除が次項目 B を drain した後に (2) A の
    /// `operation`完了後の`supply`後始末が B の drain 状態を無条件に
    /// 踏み潰して C を drain し、以降「要求済みなのに受け手のいない」
    /// 項目が数珠つなぎに発生 — 供給と要求が恒久的に1つずつズレ、
    /// 後続リクエストが**全滅**する (要求数と供給数は一致したまま、
    /// Task #202 と同じ診断カウンタの見た目になる別バグ)。
    ///
    /// タイムライン (timeout 1秒 / 供給遅延 0.3秒 / A の operation 1.2秒):
    /// A 供給 t=0.3 → A のタイムアウト発火 t=1.0 (修正前: B を drain) →
    /// B 供給 t=1.3・即完了 → C を drain (供給予定 t=1.6) → A の
    /// operation 完了 t=1.5 (修正前: C の drain 状態を踏み潰して D を
    /// drain → C の供給 t=1.6 は不一致破棄 → C タイムアウト掃除が D の
    /// 状態を消す → D の供給も宛先を失う…)。修正後は A のタイムアウトが
    /// 供給済み項目に対して何もしないため、この連鎖の起点自体が存在
    /// しない — 4件全部が自分のセッションで完了する。
    @Test("an operation outliving its own timeout does not desync supply from later queued items")
    func operationOutlivingItsOwnTimeoutDoesNotDesyncLaterItems() async throws {
        let queueRef = Box<SupplyGatedRequestQueue<Int, Int>>()
        let queue = SupplyGatedRequestQueue<Int, Int>(
            timeoutSeconds: 1,
            timeoutError: { TimeoutMarker() },
            requestSupply: { [weak queueRef] target, ticket in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await queueRef?.value?.supply(target, for: ticket)
                }
            }
        )
        queueRef.value = queue

        func attempt(_ index: Int) async -> Result<Int, Error> {
            do {
                return .success(try await queue.perform(target: index) { session in
                    if index == 0 {
                        // 先頭の項目だけ、自分のタイムアウト予算を跨ぐ
                        // 長い operation — 修正前はこれが後続全滅の引き金。
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                    }
                    return session * 10
                })
            } catch {
                return .failure(error)
            }
        }
        async let r0 = attempt(0)
        async let r1 = attempt(1)
        async let r2 = attempt(2)
        async let r3 = attempt(3)
        let (v0, v1, v2, v3) = await (r0, r1, r2, r3)

        for (index, result) in [v0, v1, v2, v3].enumerated() {
            switch result {
            case .success(let value):
                #expect(value == index * 10, "item \(index) resolved with the wrong session")
            case .failure(let error):
                Issue.record("item \(index) failed instead of completing: \(error)")
            }
        }
    }
}

/// Plain mutable reference box — `manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay`/
/// `manySequentialRequestsAllComplete`/`manyItemsSurviveStraySuppliesUnderLoad`
/// need `requestSupply`'s closure to call back into the very `queue` it's
/// still being constructed as part of; a `weak` capture through this box
/// (rather than capturing `queue` itself, which doesn't exist yet at
/// closure-literal-evaluation time) sidesteps that ordering problem the
/// same way `TranslationSessionCoordinator.init`'s `lazy var requestQueue`
/// does for the identical reason. Starts empty (`init()`) so it can be
/// declared *before* the object it will eventually hold, then filled in
/// right after that object's own `init` returns.
@MainActor
private final class Box<T: AnyObject> {
    weak var value: T?
    init() {}
}
