import Foundation

/// Task #202 (実機フィードバック — 「一度翻訳が成功した後は、以後の翻訳が
/// 必ず『翻訳セッションを取得できませんでした』でタイムアウトし続ける」、
/// 診断画面のカウンタは「設定要求N回/セッション供給N回、いずれも今回の
/// リクエストには届きませんでした」と、要求した数だけ`supply(_:)`が実際に
/// 呼ばれているのにこの`perform`だけが毎回タイムアウトすることを示していた
/// — 根本原因): `supply(_:)`は以前、引数の`session`が「今まさに
/// `pendingOperation`にある項目」に対する応答だという保証を一切検証せずに
/// 受け取っていた。`TranslationSessionHostView`の`.translationTask(_:action:)`
/// クロージャは`id`(=`configuration`)が変わるとSwiftUIに**協調的に**
/// キャンセルされる (`Task.isCancelled`をどこもチェックしていない) だけで、
/// 実行そのものは止まらない — Appleのセッション確立自体に実機で数秒
/// かかることは珍しくなく、その間にこの項目自身の`timeoutSeconds`が先に
/// 尽きて`drainIfNeeded()`が次の項目へ進んでいることは十分あり得る。その
/// 「もう誰も待っていないはずの」古いクロージャが後から`supply(_:)`を
/// 呼んだとき、以前の実装は`pendingOperation`が(次の項目のものへ)
/// 非nilに変わっていることを区別できず、**古いセッションで新しい項目の
/// `operation`をそのまま実行してしまっていた** — 新しい項目からすれば
/// 「要求はしたのに自分宛の供給が一度も届かない」状態になり、やがて
/// **自分自身の**タイムアウトで諦める。これが「要求N回・供給N回なのに
/// 毎回タイムアウトする」の正体: 供給は確かにN回起きているが、そのうち
/// 実際に自分の項目へ届いたのは1回もない (常に1つ前の項目が「盗んで」
/// いた) ということがあり得た。「最初の1回だけ成功し、以後は必ず失敗する」
/// という実機パターンも符合する — アプリ起動後・このコーディネータの
/// 生涯で最初の項目だけは先行する「古いクロージャ」が存在しえず、2件目
/// 以降は常に「1つ前の項目のクロージャがまだ生きているかもしれない」
/// 状態からスタートするため。
///
/// **修正**: `drainIfNeeded()`が項目をキューから取り出すたびに新しい
/// `Ticket`を発行し、`requestSupply`にその項目の`target`と一緒に渡す。
/// 外部の供給元 (`TranslationSessionCoordinator`) はこの`ticket`を
/// 保持しておき、実際に供給する際 (`supply(_:for:)`) に添えて返す責任を
/// 持つ。`supply(_:for:)`は`ticket`が**現在**`pendingOperation`が待って
/// いるものと一致する場合にのみ処理し、一致しなければ (=古い項目からの
/// 遅延応答) `pendingOperation`に一切触れずに安全に無視する — ちょうど
/// 「タイムアウト後の遅延`supply`」と同じ「安全な no-op」の扱いを、
/// 「タイムアウトはまだ起きていないが別の項目に取って代わられた」ケース
/// にも拡張したもの。`SupplyGatedRequestQueueTests
/// .lateSupplyForSupersededTicketDoesNotStealNewerItem`がこの具体的な
/// レースを (Fakeな`Target`/`Session`で) 直接再現・固定している。
///
/// 2026-07-30 (実機フィードバック — 退行「テスト翻訳を実行」がスピナーの
/// まま無反応、メール本文画面でも翻訳できなくなった): `TranslationSessionCoordinator`
/// の「セッションを外部 (SwiftUI の `.translationTask` アクションクロージャ)
/// から供給してもらうまで待つ」というキュー/直列化/タイムアウトの仕組みは
/// `Translation.TranslationSession`固有の話ではない、一般的な「供給待ち
/// リクエストキュー」パターン — この型として`TranslationSession`に一切
/// 依存しない形へ切り出した。理由: `TranslationSession`は公開イニシャライザ
/// が無くテストプロセス内で構築不可能 (`TranslationLanguageLocaleTests`の
/// doc comment参照) なため、`TranslationSessionCoordinator`自体に対しては
/// 「供給が一切来ないケース」「二重resumeが起きないこと」「並行リクエスト
/// が両方とも必ず終わること」を単体テストできない。この型は`Target`/
/// `Session`を任意の`Sendable`型にできるので、`SupplyGatedRequestQueueTests`
/// が`Int`/`String`のような素の型で上記すべてを直接検証する。
///
/// 使い方: `requestSupply`は「外部の供給元にこの`target`向けの供給を
/// 依頼して」という通知だけを行う (`TranslationSessionCoordinator`では
/// `configuration`を差し替えるだけ) — 実際の供給は非同期にいつか
/// `supply(_:)`が呼ばれることで届く。`perform(target:operation:)`は
/// その供給が届くまで (または`timeoutSeconds`が過ぎるまで) 待ち、
/// `operation`を実行してその結果を返す。
@MainActor
public final class SupplyGatedRequestQueue<Target: Sendable, Session: Sendable> {
    /// Task #202: an opaque per-drain identifier, handed to `requestSupply`
    /// alongside the `target` it's for, and required back on `supply(_:for:)`
    /// — see this file's top-level doc comment for the exact race this
    /// closes. Callers can't construct one themselves (`fileprivate` field,
    /// only a synthesized `fileprivate` memberwise init), only receive and
    /// echo back whatever `requestSupply` gave them; that's deliberate — a
    /// `Ticket` a caller invented itself would defeat the whole point (it
    /// could always "happen" to match). `public` (not `internal`, this
    /// class's own default) purely so `TranslationSessionCoordinator` can
    /// re-export it as `RequestTicket` for `apps/Otegami`'s
    /// `TranslationSessionHostView` (a different module) to hold and pass
    /// back to `attach(_:ticket:)` — this class's *construction*
    /// (`init`) stays unexported, only ever built inside this module.
    public struct Ticket: Sendable, Equatable {
        fileprivate let rawValue: Int
    }

    /// `armTimeout` starts the item's own timeout clock — see
    /// `drainIfNeeded()`'s doc comment (2026-07-30 追記) for why this has
    /// to happen there, not in `perform(target:operation:)`.
    private struct QueueItem {
        let target: Target
        let operation: @MainActor (Session) async -> Void
        let armTimeout: @MainActor () -> Void
    }

    private var queue: [QueueItem] = []
    /// `true` from the moment `requestSupply` is called for the item
    /// currently at the front of the queue until `supply(_:for:)` finishes
    /// running that item's `operation` (or the matching `perform` call's
    /// own timeout gives up first) — i.e. "a supply is currently owed to
    /// us and hasn't arrived yet, or is being processed". While `true`,
    /// `drainIfNeeded()` must not call `requestSupply` again — a second
    /// call before the first's answer arrives could make the external
    /// supplier drop/cancel the first request entirely (this is exactly
    /// what happened with `TranslationSession.Configuration`: changing it
    /// again before `.translationTask`'s previous action closure had
    /// fired cancelled that closure's `Task`, permanently losing the
    /// request it was for).
    private var isDraining = false
    private var pendingOperation: (@MainActor (Session) async -> Void)?
    /// Task #202: which `Ticket` `pendingOperation` (if any) is actually
    /// waiting for — `supply(_:for:)` only honors a call whose `ticket`
    /// matches this exactly, so a late answer meant for an item that's
    /// since been superseded (its own timeout fired, `drainIfNeeded()`
    /// moved on) can never be mistaken for an answer to whatever's pending
    /// *now*. `nil` whenever nothing is pending, matching `pendingOperation`.
    private var pendingTicket: Ticket?
    private var nextTicketValue = 0

    private let timeoutSeconds: UInt64
    private let timeoutError: @MainActor @Sendable () -> Error
    private let requestSupply: @MainActor (Target, Ticket) -> Void

    /// - Parameters:
    ///   - timeoutSeconds: how long `perform(target:operation:)` waits for
    ///     a matching `supply(_:for:)` call before giving up — structurally
    ///     guarantees no caller can wait forever, no matter what goes
    ///     wrong on the supply side (a missing/misconfigured supplier, a
    ///     bug in this type, ...).
    ///   - timeoutError: builds the error a timed-out `perform` call
    ///     throws — a closure (not a fixed value) so callers can supply a
    ///     domain-specific message without this generic type needing to
    ///     know about it.
    ///   - requestSupply: called (on the main actor) exactly once per
    ///     queue item, when it's that item's turn — the external
    ///     supplier's cue to eventually call `supply(_:for:)` with a
    ///     `Session` and the same `Ticket` it was given here.
    init(timeoutSeconds: UInt64, timeoutError: @escaping @MainActor @Sendable () -> Error, requestSupply: @escaping @MainActor (Target, Ticket) -> Void) {
        self.timeoutSeconds = timeoutSeconds
        self.timeoutError = timeoutError
        self.requestSupply = requestSupply
    }

    /// Enqueues `operation` to run with the next `Session` supplied for
    /// `target`, and waits for either that to happen or the timeout to
    /// elapse. `operation` must not stash `session` anywhere that outlives
    /// this call (the whole reason this queue exists — see
    /// `TranslationSessionCoordinator`'s doc comment for the concrete bug
    /// this was built to prevent).
    ///
    /// The returned/thrown result is resolved through `ResumeBox`, which
    /// guarantees `continuation.resume` is called *exactly once* regardless
    /// of whether `operation` finishes first or the timeout fires first —
    /// a `CheckedContinuation` traps if resumed twice and hangs forever if
    /// resumed zero times, and this method has two independent code paths
    /// racing to resolve the same one.
    ///
    /// 2026-07-30 (実機フィードバック — 3度目の退行, 「テスト翻訳は成功
    /// するがメール翻訳は失敗する」): この関数自身はもう`Task.sleep`を
    /// 直接スケジュールしない — 以前はここで即座にタイムアウトの時計を
    /// 回し始めていたが、それは「`perform`が*呼ばれた瞬間*」であって
    /// 「*このリクエストが実際にキューの先頭に来て供給を求められた瞬間*」
    /// ではない。複数のリクエストが立て続けに積まれる (実機ログ通り —
    /// メール翻訳は本文を段落ごとに1件ずつ`translate`を呼ぶ) と、後の方の
    /// リクエストは先行リクエストの処理が終わるまでキューで待たされる
    /// あいだにも持ち時間を消費され、自分の番が来る前に (あるいは来た
    /// 直後に) タイムアウトしてしまっていた — `SupplyGatedRequestQueueTests
    /// .manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay`が
    /// このバグを固定・再現する。タイムアウトを実際に開始する
    /// (`armTimeout`) 責務は`drainIfNeeded()`へ移した — 「このリクエスト
    /// に実際に`requestSupply`を呼んだ瞬間」を起点にすることで、キューで
    /// 待たされた時間は一切タイムアウト予算を消費しない。
    func perform<T: Sendable>(target: Target, operation: @escaping @MainActor (Session) async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let box = ResumeBox(continuation)
            let timeoutSeconds = self.timeoutSeconds
            let timeoutError = self.timeoutError
            enqueue(
                target: target,
                operation: { session in
                    do {
                        let result = try await operation(session)
                        box.resume(returning: result)
                    } catch {
                        box.resume(throwing: error)
                    }
                },
                armTimeout: { [weak self] in
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                        // `box.resume` reports whether *this* call actually
                        // resolved the continuation (`operation` hadn't
                        // already done so first) — only then may this
                        // timeout also advance the queue. Doing so
                        // unconditionally would, on the common "operation
                        // already finished normally, well before the
                        // timeout" path, blow away *a completely
                        // different, later* request's `pendingOperation`
                        // out from under it (this queue only ever tracks
                        // one at a time) — reintroducing the exact
                        // "request never completes" bug this type exists
                        // to prevent, just via the fix's own cleanup code
                        // instead of the original missing-supplier bug.
                        guard box.resume(throwing: timeoutError()) else { return }
                        guard let self else { return }
                        self.isDraining = false
                        self.pendingOperation = nil
                        // Task #202: also clear `pendingTicket` — if
                        // `drainIfNeeded()` right below finds the queue
                        // empty, nothing will overwrite it, and a stale
                        // `supply(_:for:)` call for *this* (just abandoned)
                        // ticket must not still match and re-run an
                        // operation whose `perform` call already gave up
                        // and returned.
                        self.pendingTicket = nil
                        self.drainIfNeeded()
                    }
                }
            )
        }
    }

    /// Called by the external supplier once it has a `Session` ready for
    /// whichever `target` this queue most recently asked for via
    /// `requestSupply` — `ticket` must be the exact `Ticket` that specific
    /// `requestSupply` call received (`TranslationSessionCoordinator`
    /// threads it through `attach(_:ticket:)`). A safe no-op, not a crash,
    /// whenever `ticket` doesn't match `pendingTicket` — covering *two*
    /// distinct "this answer is stale" cases the same way:
    /// - Nothing is pending at all (`pendingTicket == nil`) — the matching
    ///   request already timed out and moved the queue forward with
    ///   nothing behind it (the original, pre-Task #202 scenario this
    ///   doc comment already covered).
    /// - Something *is* pending, but it's a *different, newer* ticket
    ///   (Task #202) — the request this `session` was actually meant for
    ///   already timed out, `drainIfNeeded()` moved on to a later item,
    ///   and this is a late straggler answer for the abandoned one. Without
    ///   the ticket check this would silently run the *newer* item's
    ///   `operation` with the *wrong* `session` and steal its slot — see
    ///   this file's top-level doc comment for the full real-device trace.
    func supply(_ session: Session, for ticket: Ticket) async {
        guard ticket == pendingTicket, let operation = pendingOperation else { return }
        pendingOperation = nil
        pendingTicket = nil
        await operation(session)
        isDraining = false
        drainIfNeeded()
    }

    private func enqueue(target: Target, operation: @escaping @MainActor (Session) async -> Void, armTimeout: @escaping @MainActor () -> Void) {
        queue.append(QueueItem(target: target, operation: operation, armTimeout: armTimeout))
        drainIfNeeded()
    }

    /// Starts the next queued item, if any, *only* when no supply is
    /// currently owed to us — see `isDraining`'s doc comment.
    ///
    /// 2026-07-30 (実機フィードバック — 3度目の退行): `item.armTimeout()`
    /// を呼ぶのは**必ず`requestSupply(item.target)`の直後、この関数の中**
    /// — その項目のタイムアウト予算は「実際にこの項目のために供給を
    /// 求めた瞬間」から数え始める。以前は`perform`が呼ばれた瞬間 (=まだ
    /// キューの先頭に来ていないかもしれない) から数えていたため、複数
    /// リクエストが連続すると後の方の項目がキューで待たされた時間の分
    /// だけ不当に持ち時間を削られていた
    /// (`SupplyGatedRequestQueueTests
    /// .manyQueuedRequestsAllCompleteDespiteCumulativeQueueingDelay`参照)。
    private func drainIfNeeded() {
        guard !isDraining, !queue.isEmpty else { return }
        isDraining = true
        let item = queue.removeFirst()
        // Task #202: a fresh ticket per drained item — see `Ticket`'s and
        // `supply(_:for:)`'s doc comments for why this specific value
        // (rather than `item.target`, which two in-flight requests can
        // share, see `sameTargetRequestedTwiceInARowBothGetSupplied`) is
        // what lets a late answer be told apart from an answer to *this*
        // item.
        let ticket = Ticket(rawValue: nextTicketValue)
        nextTicketValue += 1
        pendingOperation = item.operation
        pendingTicket = ticket
        requestSupply(item.target, ticket)
        item.armTimeout()
    }
}

/// See `SupplyGatedRequestQueue.perform(target:operation:)`'s doc comment
/// for why this exists: a `CheckedContinuation` must be resumed *exactly*
/// once, but `perform` has two independent paths (the operation finishing,
/// or the timeout elapsing) that can each try to resolve the same one —
/// whichever gets there first must win, and the other must silently no-op
/// rather than crash (double-resume) or leave the continuation dangling
/// (zero-resume, i.e. the original hang bug this whole type exists to
/// prevent). `@MainActor`-isolated (matching every caller in this module),
/// so no additional locking is needed for the check-then-clear below to be
/// race-free.
@MainActor
final class ResumeBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Returns whether *this* call actually resumed the continuation
    /// (`true`) or lost the race to an earlier `resume` call (`false`,
    /// safe no-op) — callers that also need to run cleanup only when they
    /// genuinely won (`SupplyGatedRequestQueue.perform`'s timeout `Task`)
    /// branch on this.
    @discardableResult
    func resume(returning value: T) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(throwing: error)
        return true
    }
}
