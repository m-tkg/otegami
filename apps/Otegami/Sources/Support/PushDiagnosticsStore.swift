import Foundation
import Observation
import PushRelayClient

/// Task #213 (前段: Task #211 の OSLog 診断ログは Mac に有線接続しないと
/// 読めなかった): `NotificationService` (別プロセスの App Extension) が
/// 共有 App Group の `UserDefaults` へ書き出した直近の通知処理記録
/// (`PushDiagnosticsRun`) を、この端末上の「プッシュ通知の診断」画面
/// (`PushDiagnosticsView`) 向けに読み出すだけの薄いストア。
///
/// `TranslationDiagnosticsStore`と違い、この`Observable`インスタンス自身に
/// 書き込みは一切起きない — 記録するのは別プロセスの`NotificationService`
/// で、こちらは常に`UserDefaults`から読み直す。そのため`@Observable`の
/// 自動再描画だけでは新しい記録の到着を検知できず (`UserDefaults`への
/// 他プロセスからの書き込みはこのプロセスへ変化通知が飛んでこない)、
/// `refresh()`を明示的に呼ぶ必要がある — `PushDiagnosticsView`は画面表示
/// のたびに`.task`から呼ぶ (前例:
/// `PushNotificationSettingsView.refreshWatchRows()`が同じ「開くたびに
/// 取り直す」設計)。
@MainActor
@Observable
final class PushDiagnosticsStore {
    /// Newest first — already `PushDiagnosticsHistory.loadRuns(fromSuite:)`'s
    /// own ordering (`PushDiagnosticsHistory.inserting(_:into:)`'s doc
    /// comment).
    public private(set) var runs: [PushDiagnosticsRun] = []

    init() {
        refresh()
    }

    /// Re-reads the shared App Group `UserDefaults` suite. Empty (not an
    /// error) when there's no App Group configured at all — always true on
    /// macOS (`OtegamiAppGroup.identifier`'s doc comment: no
    /// `NotificationService` there to begin with, per this type's own doc
    /// comment on where records come from) — or when nothing has been
    /// recorded there yet.
    func refresh() {
        // `scripts/verify-screen.sh`'s `push-diagnostics-populated` scenario
        // — same "fixed fixture data behind a UITest-only env var" pattern
        // as `AppEnvironment.uitestFixedPushWatchSummaries`
        // (`OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES`'s doc comment): a
        // Simulator/dev Mac never receives a real APNs push, so
        // `NotificationService` never actually runs here — this is the only
        // way to screenshot what a populated (non-empty) diagnostics screen
        // looks like, deterministically.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FIXED_PUSH_DIAGNOSTICS"] == "1" {
            runs = Self.uitestFixedRuns
            return
        }
        guard let appGroupIdentifier = OtegamiAppGroup.identifier,
              let defaults = UserDefaults(suiteName: appGroupIdentifier)
        else {
            runs = []
            return
        }
        runs = PushDiagnosticsHistory.loadRuns(fromSuite: defaults)
    }

    /// Two canned runs covering every `PushDiagnosticsRun.Outcome` case at
    /// least once: a fully successful run (every stage `.success`, one
    /// `.skipped` for `fetchBody`), and a Yahoo-flavored failure run
    /// (`.failure` with `looksRateLimited: true` at `select`, matching
    /// `docs/architecture.md`'s pitfall i. — the motivating real-world case
    /// this whole screen exists for).
    private static var uitestFixedRuns: [PushDiagnosticsRun] {
        let now = Date()
        return [
            PushDiagnosticsRun(
                date: now,
                stages: [
                    .init(stage: .parsePayload, outcome: .success, elapsedMs: 0),
                    .init(stage: .preferences, outcome: .success, elapsedMs: 0),
                    .init(stage: .accountLookup, outcome: .success, elapsedMs: 4),
                    .init(stage: .credential, outcome: .success, elapsedMs: 1),
                    .init(stage: .connect, outcome: .success, elapsedMs: 320),
                    .init(stage: .select, outcome: .success, elapsedMs: 45),
                    .init(stage: .fetchEnvelope, outcome: .success, elapsedMs: 60),
                    .init(stage: .fetchBody, outcome: .skipped(reason: "showsBodyPreview off"), elapsedMs: 0),
                ],
                totalElapsedMs: 430
            ),
            PushDiagnosticsRun(
                date: now.addingTimeInterval(-600),
                stages: [
                    .init(stage: .parsePayload, outcome: .success, elapsedMs: 0),
                    .init(stage: .preferences, outcome: .success, elapsedMs: 0),
                    .init(stage: .accountLookup, outcome: .success, elapsedMs: 3),
                    .init(stage: .credential, outcome: .success, elapsedMs: 1),
                    .init(stage: .connect, outcome: .success, elapsedMs: 280),
                    .init(
                        stage: .select,
                        outcome: .failure(category: "serverError", looksRateLimited: true, logDetail: "A87 NO [LIMIT] STATUS Rate limit hit."),
                        elapsedMs: 190
                    ),
                ],
                totalElapsedMs: 474
            ),
        ]
    }
}
