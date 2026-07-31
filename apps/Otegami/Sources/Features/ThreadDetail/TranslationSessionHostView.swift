import SwiftUI
import Translation
import OtegamiTranslationApple

/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替):
/// the one place in this app that actually invokes SwiftUI's
/// `.translationTask(_:action:)` — `Translation.TranslationSession` has no
/// public initializer, so this is Apple's only supported way to obtain one.
/// `AppleTranslationService` (`OtegamiTranslationApple`) never touches
/// SwiftUI itself; it asks `AppEnvironment.translationSessionCoordinator`
/// for a session by target language, and that coordinator's `configuration`
/// is what this view reads and hands to `.translationTask` — see
/// `TranslationSessionCoordinator`'s own doc comment for the full handshake.
///
/// Mounted once, invisibly, at `ThreadDetailView`'s root (`.background`) —
/// every message's translate call (`MessageView.requestTranslation` →
/// `AppEnvironment.messageTranslator` → `HybridTranslationService` →
/// `AppleTranslationService`) ultimately depends on this view being present
/// somewhere in the tree whenever a thread is open; without it,
/// `coordinator.configuration` would change but nothing would ever act on
/// it, and every translate attempt would hang forever awaiting a session
/// that never arrives. Zero-sized and non-interactive (`Color.clear` at
/// `0×0`, `.accessibilityHidden`) — it renders nothing on screen, purely a
/// `.translationTask` anchor point.
@available(iOS 18.0, macOS 15.0, *)
struct TranslationSessionHostView: View {
    let coordinator: TranslationSessionCoordinator

    var body: some View {
        // Task #202: read `configuration`/`ticket` together, once, into
        // locals *before* `.translationTask` — both are written together,
        // synchronously, by `TranslationSessionCoordinator`'s
        // `requestSupply` closure, so reading them together here (rather
        // than `coordinator.pendingTicket` freshly inside the closure
        // below, which could by then have moved on to a *later* request)
        // guarantees `ticket` is the one that actually corresponds to
        // *this* render's `configuration` — see `attach(_:ticket:)`'s doc
        // comment for why that correspondence is the whole fix.
        let configuration = coordinator.configuration
        let ticket = coordinator.pendingTicket
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(configuration) { session in
                // 2026-07-30 (実機フィードバック、`TranslationSessionCoordinator`
                // の全面書き直し): `await` — fire-and-forget にしない。この
                // クロージャの`Task`が実際に`session`を使い終わるまで
                // 生き続けることそのものが、セッションをクロージャの外へ
                // 持ち出さないための修正の要 — `TranslationSessionCoordinator`
                // のdoc comment参照。
                //
                // Task #202: `ticket`は`configuration`が`nil`でない限り
                // 必ず非nil (`requestSupply`が両方を同じ瞬間にセットする、
                // 上のコメント参照) — 万一`nil`ならこの呼び出し自体が
                // どの要求にも対応しない (起こり得ないはずの) 状態なので、
                // `SupplyGatedRequestQueue.supply(_:for:)`と同じ「安全な
                // no-op」の方針でそのまま無視する。
                guard let ticket else { return }
                await coordinator.attach(session, ticket: ticket)
            }
    }
}
