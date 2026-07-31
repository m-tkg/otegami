import Foundation
import Observation
import OtegamiTranslation
// `@preconcurrency`: `Translation.TranslationSession` isn't (yet) declared
// `Sendable` by Apple. This coordinator is the *only* place in this package
// that ever holds or touches a `TranslationSession` value — every public
// method below takes/returns only plain `Sendable` types (`String`,
// `Locale.Language`, ...), so the session itself never has to cross an
// actor boundary at all. `@preconcurrency` here just quiets the compiler
// about a type this package doesn't own and can't annotate; it isn't load-
// bearing for the actual safety of this design (see this type's own doc
// comment for why the session never leaves the main actor by construction,
// not by suppressed diagnostics).
@preconcurrency import Translation

/// Task #159: bridges the Translation framework's SwiftUI-only
/// `TranslationSession` (Apple provides no public initializer for it — the
/// only supported way to obtain one is the `.translationTask(_:action:)`
/// view modifier) to `AppleTranslationService`'s plain-`async` API, which has
/// no SwiftUI/View of its own to attach that modifier to.
///
/// **The handshake**: this type owns `configuration` (read by a hosting view
/// living at the app layer — `apps/Otegami/Sources/Features/ThreadDetail
/// /TranslationSessionHostView.swift`, since this package has no SwiftUI
/// dependency and shouldn't need one just to host one modifier call). That
/// view's body reads `configuration` and passes it straight to
/// `.translationTask(_:action:)`; whenever this coordinator changes it (from
/// `enqueue(target:operation:)` below), SwiftUI notices (this class is
/// `@Observable`) and invokes the hosting view's action closure with a fresh
/// `TranslationSession` shortly after, which the hosting view forwards here
/// via `attach(_:)`.
///
/// **Every public method here takes/returns only `Sendable` types, never a
/// `TranslationSession` itself** — `Translation.TranslationSession` is not
/// `Sendable` (confirmed against the actual SDK: an earlier revision of this
/// type that returned a session directly to `AppleTranslationService` failed
/// to compile with exactly that diagnostic), so `translate(_:to:)`/
/// `translateBatch(_:to:)`/`prepareTranslation(to:)` below each obtain the
/// session, use it, and extract a plain result *entirely within this
/// `@MainActor`-isolated type* — the session's whole lifetime stays on the
/// main actor, satisfying `TranslationOnlyService: Sendable` without ever
/// needing an unsafe cast or `@unchecked Sendable`.
///
/// **2026-07-30 rewrite (実機フィードバック, 一連の「翻訳が理由不明のまま
/// 失敗し続ける」報告の最終的な根治)**: the previous revision of this type
/// *stored* the `TranslationSession` SwiftUI handed to `attach(_:)` (in a
/// `currentSession` property) and reused it later, on demand, from whatever
/// unrelated `Task` context called `translate(_:to:)`/`prepareTranslation
/// (to:)` — i.e. *outside* the `.translationTask(_:action:)` action closure
/// that originally produced it. That is explicitly unsupported: Apple's own
/// guidance (WWDC24 "Meet the Translation API" + the framework's own
/// documented pattern of building a batch of requests *inside* the closure
/// and calling `session.translations(from:)` there) is that a session is
/// only valid for the duration of the closure invocation that vends it —
/// using it later either traps ("Attempted to use TranslationSession after
/// the view it was attached to has disappeared") or, on this app's actual
/// wiring (the hosting view never disappears — it's mounted for the whole
/// thread-detail screen's lifetime, only the *closure invocation* that
/// handed out a given session instance ends), throws a plain
/// `TranslationError` — which matches every real-device report in this
/// investigation: `prepareTranslation()` and `translate()` both failing
/// with `domain=Translation.TranslationError code=1`, unconditionally,
/// regardless of how clean the input text was.
///
/// The fix: never store a session past the closure invocation that vends
/// it. Every public method below (`translate`/`translateBatch`/
/// `prepareTranslation`) now *enqueues* the actual `session`-using work
/// (`enqueue(target:operation:)`) instead of fetching a session and using it
/// itself; `attach(_:)` — called from, and `await`ed by, the hosting view's
/// own `.translationTask` action closure — is what actually runs that work,
/// so every `session.translate(_:)`/`.translations(from:)`/
/// `.prepareTranslation()` call now executes on the exact `Task` SwiftUI
/// created for it, never after. Requests are serialized (`isDraining`/
/// `queue`) rather than allowed to overlap: setting `configuration` again
/// while a previous request's matching `attach(_:)` hasn't fired yet would
/// cancel that still-pending `.translationTask` invocation before it ever
/// ran (the same task-modifier semantics as `.task(id:)`), silently
/// dropping that request's continuation forever — the queue means at most
/// one `configuration` change is ever "in flight" waiting for its `attach`.
/// A fresh `Configuration(source:target:)` is now built per request rather
/// than reused across calls for the same target — the previous "reuse the
/// session for an already-current target with no re-suspension" fast path
/// is exactly what caused this bug and is gone.
///
/// **2026-07-30, second regression (実機フィードバック — 最初のホスト
/// ビュー移設だけではまだ直っていなかった)**: the paragraph above's
/// "build a fresh `Configuration` per request" turned out to be *not
/// enough on its own* — verified directly against the real SDK (a plain
/// Swift program constructing two `Configuration(source: nil, target:
/// same)` values independently and comparing them): **they compare
/// `==` equal**. `.translationTask(_:action:)` shares `.task(id:)`'s
/// semantics — it only re-invokes its action closure when the value it's
/// given actually *changes* — so a second request for the same language
/// pair was, from SwiftUI's perspective, re-assigning an equal value,
/// never triggering a new closure invocation, never calling `attach(_:)`,
/// timing out every time after the first successful request (or, if the
/// very first request happened to match a `Configuration` some earlier
/// availability check had already set, from the very first request too —
/// matching that exact real-device symptom). `requestNewConfiguration
/// (target:)` below fixes this properly: when a `configuration` already
/// exists, it mutates that *same* value's `target` and then calls
/// `invalidate()` — confirmed against the real SDK to make the value
/// compare unequal to its prior state even with identical `source`/
/// `target` (this is `invalidate()`'s documented purpose: forcing a
/// retranslation with the same configuration) — guaranteeing SwiftUI
/// always sees a change and always re-invokes the closure.
///
/// `@MainActor` (not an `actor`): `.translationTask`'s action closure and
/// SwiftUI's own re-render of the hosting view both run on the main actor,
/// and `configuration`'s writes/reads need to interleave with those, not
/// with some other executor.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
@Observable
public final class TranslationSessionCoordinator {
    public init() {}

    /// Read by `TranslationSessionHostView.body` and passed straight to
    /// `.translationTask(_:action:)` — `private(set)` because only
    /// `requestQueue`'s internal draining decides when a new session is
    /// actually needed; nothing outside this type should be able to force
    /// a reset.
    public private(set) var configuration: TranslationSession.Configuration?

    /// 2026-07-30 (実機フィードバック — 2度目の退行): アプリのルートへ
    /// ホストビューを移した後もまだ実機でタイムアウトした。原因を
    /// `.swiftinterface`相当の実機検証 (プレーンなSwiftプログラムで
    /// `TranslationSession.Configuration`を2つ独立に構築して`==`比較)
    /// で確定: **同じ`source`/`target`で作った`Configuration`同士は
    /// 等価と判定される** (`a == b` → `true`)。`.translationTask(_:action:)`
    /// は`.task(id:)`と同じ意味論で、渡した値が「変化」した時だけ
    /// クロージャを再実行する — つまり以前の実装
    /// (`TranslationSession.Configuration(source: nil, target: target)`を
    /// 毎回新規に作って代入) は、**2回目以降、同じ言語ペアへのリクエスト
    /// では実質「同じ値の再代入」になり、SwiftUIから見て変化なし**、
    /// クロージャは二度と再発火しなかった。初回から失敗した実機報告も
    /// これで説明できる — 起動直後の可用性チェック等で既に一度同じ
    /// `Configuration`がセットされていれば、以後の代入は全て「変化なし」
    /// になる。
    ///
    /// 修正: 毎回新規`Configuration`を作るのをやめ、既存の`configuration`
    /// があればその場で`target`を書き換えた上で`invalidate()`を呼ぶ —
    /// 同じ実機検証で`invalidate()`後は元の値と`==`で不一致になることを
    /// 確認済み (Apple公式ドキュメント通り、同一設定での再翻訳を促す
    /// ための専用API)。`configuration`が`nil`の場合だけ新規構築する。
    /// これで「2回目以降のリクエストでも必ずクロージャが呼ばれる」ことが
    /// 保証される — `SupplyGatedRequestQueueTests`の
    /// `sameTargetRequestedTwiceInARowBothGetSupplied`が、この関係を
    /// (Fakeな`Session`/`Target`で) 直接固定している。
    private func requestNewConfiguration(target: Locale.Language) {
        if var current = configuration {
            current.target = target
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: nil, target: target)
        }
        configurationRequestCount += 1
        lastConfigurationRequestAt = Date()
    }

    // MARK: - Diagnostics (2026-07-30, 実機フィードバック — 2度目の退行)

    /// 「翻訳の診断」画面が表示する、供給側の可観測性 — `requestSupply`が
    /// 呼ばれた (=新しいセッションを要求した) 回数・最終時刻と、
    /// `attach(_:)`が実際に呼ばれた (=ホストビューの`.translationTask`
    /// クロージャが本当に発火した) 回数・最終時刻。前者だけ増えて後者が
    /// 増えない/一度も無いなら「クロージャが供給元から一度も呼ばれて
    /// いない」ことがこの画面だけで即断できる — 前回の退行 (ホストビュー
    /// 未マウント) も今回の退行 (`Configuration`の等価判定) も、どちらも
    /// この2組の数字を見れば1枚のスクリーンショットで切り分けられていた。
    public private(set) var configurationRequestCount = 0
    public private(set) var lastConfigurationRequestAt: Date?
    public private(set) var attachCallCount = 0
    public private(set) var lastAttachAt: Date?

    /// 2026-07-30 (実機フィードバック — 退行): 設定内の「翻訳の診断」画面
    /// (`TranslationSessionHostView`がマウントされていない画面ツリー)
    /// から`translate`を呼ぶと、`attach(_:)`が一度も呼ばれずに待機中の
    /// リクエストが**永久に**解決されず、「テスト翻訳を実行」ボタンの
    /// スピナーが回り続けたまま止まらない、という構造的な穴があった。
    /// 根本原因 (ホストビューがアプリのどの画面からも常に1つ供給される
    /// 場所に無かったこと) は`TranslationSessionHostView`のマウント位置を
    /// `OtegamiApp`のルートへ移すことで解消済みだが、それとは**独立**に、
    /// この型自体が「供給元がどんな理由であれ現れなかった場合」を構造的に
    /// 無限待機にしない責任を持つ — ホストビュー側の配線ミス・SwiftUI
    /// 側の未知の挙動・将来また同じクラスの穴が空いても、ここでは必ず
    /// 有限時間で終わる (`SupplyGatedRequestQueue`のdoc comment参照 —
    /// この仕組み自体は`TranslationSession`に依存しない汎用型として
    /// 切り出してあり、`SupplyGatedRequestQueueTests`が`Fake`な
    /// `Target`/`Session`で「供給が一切来ないケース」「二重resumeが
    /// 起きないこと」「並行リクエストが両方とも必ず終わること」を直接
    /// 検証している — `TranslationSession`自体は公開イニシャライザが
    /// 無くテストプロセス内で構築できないため)。
    private static let sessionTimeoutSeconds: UInt64 = 10

    /// `lazy`, not assigned in `init`: `requestSupply` below needs to
    /// capture `self` (to write `configuration`), which Swift only allows
    /// once `self` is fully initialized — a `lazy var` initializer runs on
    /// first access (always after `init` returns), not during `init`
    /// itself, so this sidesteps that restriction cleanly rather than
    /// needing a two-phase "construct with a placeholder closure, then
    /// patch it" dance. `@ObservationIgnored`: `@Observable`'s macro
    /// rewrites stored properties into tracked computed ones, which is
    /// incompatible with `lazy` — this property is plumbing, not UI state
    /// SwiftUI needs to watch (only `configuration` is), so opting it out
    /// of that transform is also the semantically correct choice, not just
    /// a workaround.
    @ObservationIgnored
    private lazy var requestQueue: SupplyGatedRequestQueue<Locale.Language, TranslationSession> = SupplyGatedRequestQueue(
        timeoutSeconds: Self.sessionTimeoutSeconds,
        timeoutError: { [weak self] in
            // 2026-07-30: 「一度も供給が来ていない」(=`attachCallCount`が
            // このリクエストの要求時点から増えていない) のか、それとも
            // 何らかの理由で発火はしたが処理が止まったのか — 診断画面を
            // 見ずともエラー文言自体からある程度切り分けられるよう、
            // 現在の供給側カウンタをそのまま埋め込む。
            //
            // Task #202: この詳細な (カウンタ入りの) 文言は`detail`として
            // 診断向け (`errorDescription`/ログ/診断画面) にだけ残す —
            // `.failed(message:)`だった以前は`userFacingMessage`が
            // `message`をそのまま返すため、この生の開発者向け文言が
            // 利用者向けの帯にもそのまま出てしまい、長すぎて画面外へ
            // はみ出す実機バグの直接原因になっていた
            // (`TranslationServiceError.sessionUnavailable`のdoc comment
            // 参照)。`.sessionUnavailable`は固定の短い定型文を返す。
            let requestCount = self?.configurationRequestCount ?? -1
            let attachCount = self?.attachCallCount ?? -1
            if attachCount == 0 {
                return TranslationServiceError.sessionUnavailable(detail: "翻訳セッションを取得できませんでした（供給元が一度も応答していません: 設定要求\(requestCount)回 / セッション供給0回）")
            }
            return TranslationServiceError.sessionUnavailable(detail: "翻訳セッションを取得できませんでした（設定要求\(requestCount)回 / セッション供給\(attachCount)回、いずれも今回のリクエストには届きませんでした）")
        },
        requestSupply: { [weak self] target, ticket in
            self?.requestNewConfiguration(target: target)
            self?.pendingTicket = ticket
        }
    )

    /// Task #202: the `SupplyGatedRequestQueue.Ticket` for whichever request
    /// `configuration` was most recently set for — read by
    /// `TranslationSessionHostView.body` in the *same* render as
    /// `configuration` itself (both are written together, synchronously, in
    /// `requestQueue`'s `requestSupply` closure above) and threaded back
    /// through to `attach(_:ticket:)`. This is what lets `requestQueue`
    /// tell a genuine answer to the request that's current *right now*
    /// apart from a late straggler answer to some earlier, already-
    /// abandoned request — see `SupplyGatedRequestQueue`'s top-level doc
    /// comment for the real-device bug this fixes and
    /// `RequestTicket`'s doc comment alias just below.
    public private(set) var pendingTicket: RequestTicket?

    /// Alias for `TranslationSessionHostView` (which has no reason to know
    /// this coordinator's queue is keyed by `Locale.Language`/
    /// `TranslationSession` specifically) to spell the ticket type without
    /// repeating that generic instantiation.
    public typealias RequestTicket = SupplyGatedRequestQueue<Locale.Language, TranslationSession>.Ticket

    /// Translates `text`, auto-detecting the source language (`Configuration
    /// (source: nil, target:)` — see `AppleTranslationService`'s doc comment,
    /// Task #159 point 4, for why the source is never forced). Returns the
    /// plain translated string — `TranslationSession.Response` itself never
    /// leaves this method, let alone this type.
    public func translate(_ text: String, to target: Locale.Language) async throws -> String {
        try await requestQueue.perform(target: target) { session in
            try await session.translate(text).targetText
        }
    }

    /// Batches every element of `texts` into one `session.translations(from:)`
    /// call (rather than looping `translate(_:to:)`) — see
    /// `AppleTranslationService.translateParagraphs`'s doc comment for why
    /// this is a pure efficiency win here (unlike
    /// `FoundationModelsTranslationService`, `TranslationSession` carries no
    /// conversation history a shared batch call could leak between
    /// paragraphs). Returns results in the same order as `texts`; throws
    /// `TranslationServiceError.failed` if the response count doesn't match
    /// (a genuine engine-level anomaly, not expected in practice).
    public func translateBatch(_ texts: [String], to target: Locale.Language) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        return try await requestQueue.perform(target: target) { session in
            let responses = try await session.translations(from: Self.makeRequests(for: texts))
            var byIndex: [Int: String] = [:]
            byIndex.reserveCapacity(responses.count)
            for response in responses {
                guard let id = response.clientIdentifier, let index = Int(id) else { continue }
                byIndex[index] = response.targetText
            }
            guard byIndex.count == texts.count else {
                throw TranslationServiceError.failed(message: "translation response count mismatch (\(byIndex.count)/\(texts.count))")
            }
            return texts.indices.map { byIndex[$0] ?? "" }
        }
    }

    /// `nonisolated`/`static`, deliberately: building `[TranslationSession
    /// .Request]` inside `translateBatch` itself (a main-actor-isolated
    /// method) made the region-isolation checker treat the array as tied to
    /// the main actor's region, which `session.translations(from:)` — an
    /// `@concurrent` method that hops off the main actor internally —
    /// rejected as an unsafe `sending` argument. Building the same array in
    /// a free-standing, non-actor-isolated function first (its input/output
    /// are both plain `Sendable` values — `String`s in, `Request`s out) sidesteps
    /// that region-isolation false positive entirely.
    private nonisolated static func makeRequests(for texts: [String]) -> [TranslationSession.Request] {
        texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
    }

    /// Apple's documented way to proactively trigger the system's language-
    /// download prompt — a no-op if `target`'s pack is already installed.
    /// `AppleTranslationService` calls this before every `translate`/
    /// `translateBatch` so a first-use download shows up as an explicit,
    /// visible OS flow rather than a confusing mid-translation failure (Task
    /// #159 point 3).
    public func prepareTranslation(to target: Locale.Language) async throws {
        try await requestQueue.perform(target: target) { session in
            try await session.prepareTranslation()
        }
    }

    /// Called by `TranslationSessionHostView`'s `.translationTask` action
    /// closure (`await`ed there, not fire-and-forgotten — see this type's
    /// doc comment for why staying on that closure's own `Task` for the
    /// full duration of the resulting work is the entire point) with the
    /// session SwiftUI just created for whatever `configuration` this
    /// coordinator most recently set. Forwards straight to `requestQueue`
    /// — see `SupplyGatedRequestQueue.supply(_:for:)`'s doc comment for why
    /// a late/unmatched call here is a safe no-op, not a crash.
    ///
    /// Task #202: `ticket` must be whatever `pendingTicket` held at the
    /// exact moment the host view's `body` read `configuration` to set up
    /// *this* `.translationTask` invocation (`TranslationSessionHostView
    /// .body` captures both together, in the same synchronous render, for
    /// exactly this reason) — it's what lets `requestQueue.supply(_:for:)`
    /// reject a late answer from a closure invocation whose own item has
    /// since timed out and been superseded by a later one, instead of
    /// silently handing this `session` to that later item's operation. See
    /// `SupplyGatedRequestQueue`'s top-level doc comment for the real-device
    /// bug ("一度成功した後は必ず失敗する") this fixes.
    public func attach(_ session: TranslationSession, ticket: RequestTicket) async {
        attachCallCount += 1
        lastAttachAt = Date()
        await requestQueue.supply(session, for: ticket)
    }
}
