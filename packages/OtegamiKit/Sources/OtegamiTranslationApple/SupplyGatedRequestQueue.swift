import Foundation

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
final class SupplyGatedRequestQueue<Target: Sendable, Session: Sendable> {
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
    /// currently at the front of the queue until `supply(_:)` finishes
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

    private let timeoutSeconds: UInt64
    private let timeoutError: @MainActor @Sendable () -> Error
    private let requestSupply: @MainActor (Target) -> Void

    /// - Parameters:
    ///   - timeoutSeconds: how long `perform(target:operation:)` waits for
    ///     a matching `supply(_:)` call before giving up — structurally
    ///     guarantees no caller can wait forever, no matter what goes
    ///     wrong on the supply side (a missing/misconfigured supplier, a
    ///     bug in this type, ...).
    ///   - timeoutError: builds the error a timed-out `perform` call
    ///     throws — a closure (not a fixed value) so callers can supply a
    ///     domain-specific message without this generic type needing to
    ///     know about it.
    ///   - requestSupply: called (on the main actor) exactly once per
    ///     queue item, when it's that item's turn — the external
    ///     supplier's cue to eventually call `supply(_:)`.
    init(timeoutSeconds: UInt64, timeoutError: @escaping @MainActor @Sendable () -> Error, requestSupply: @escaping @MainActor (Target) -> Void) {
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
                        self.drainIfNeeded()
                    }
                }
            )
        }
    }

    /// Called by the external supplier once it has a `Session` ready for
    /// whichever `target` this queue most recently asked for via
    /// `requestSupply`. A safe no-op if there's no `pendingOperation` right
    /// now — the matching request may have already timed out and moved
    /// the queue forward itself (see `perform`'s timeout `Task`); a late
    /// `supply(_:)` in that case must not crash or double-run anything.
    func supply(_ session: Session) async {
        guard let operation = pendingOperation else { return }
        pendingOperation = nil
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
        pendingOperation = item.operation
        requestSupply(item.target)
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
