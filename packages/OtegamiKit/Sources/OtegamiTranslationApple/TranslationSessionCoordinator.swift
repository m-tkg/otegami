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
/// than reused across calls for the same target (this SDK's own
/// `Configuration` shape includes an internal identity/version field,
/// confirmed by symbol inspection of the compiled `Translation.swiftmodule`
/// — the framework's `invalidate()` method exists precisely to let a caller
/// force a fresh session for the same source/target, which a brand-new
/// `Configuration` value achieves the same way) — the previous "reuse the
/// session for an already-current target with no re-suspension" fast path
/// is exactly what caused this bug and is gone.
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
        timeoutError: { TranslationServiceError.failed(message: "翻訳セッションを取得できませんでした") },
        requestSupply: { [weak self] target in
            self?.configuration = TranslationSession.Configuration(source: nil, target: target)
        }
    )

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
    /// — see `SupplyGatedRequestQueue.supply(_:)`'s doc comment for why a
    /// late/unmatched call here is a safe no-op, not a crash.
    public func attach(_ session: TranslationSession) async {
        await requestQueue.supply(session)
    }
}
