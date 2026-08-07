import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、再読込で
/// サーバ状態に巻き戻る」の調査可能化: `TranslationDiagnosticsView`/
/// `PushDiagnosticsView`と同じ発想 — Mac に接続して `log stream`/
/// Console.app を操作しなくても、この端末上でスクリーンショット1枚を
/// 撮れば「`OpQueueProcessor.replay`がそもそも呼ばれていないのか」「呼ば
/// れてはいるが送信できていないのか」「未送信の操作がどれだけ溜まって
/// いるのか」を切り分けられるようにするための画面。設定の「一般」に入口
/// を置く (`GeneralSettingsView`) — プッシュ通知/デフォルトのメールアプリ
/// と同様、特定のアカウントに紐づかずアプリ全体に横断的に効く同期の
/// 診断のため。
///
/// 表示内容:
/// - 未送信の`opQueue`行数をアカウント別に (件数・最古 enqueue 時刻・
///   attempts の内訳) — `OpQueueDiagnosticsQuery.pendingSummaryByAccount`。
/// - `OpQueueProcessor.replay`の直近実行履歴 (最大`OpQueueProcessor
///   .replayLogCap`件) — いつ呼ばれ、何件送れて何件失敗/破棄したか。
///   一覧の先頭が「最後に replay が起動した時刻」そのもの (invokedAt降順)
///   — この画面を開いた時点で一番上の行が無い/古すぎるなら、replay が
///   そもそも呼ばれていないことを意味する。
///
/// stale discard (uidValidity 失効による自動破棄) の個別一覧は、既存の
/// 「同期エラー」画面 (`FailedOperationsView`) 側に出す — こちらでは
/// replay ログの`discardedStale`件数として集計だけ見える。
///
/// 実機報告「『すべてのメール』の未読件数が iOS と macOS で違う」追記:
/// この画面には**メール取得 (古いメールのバックフィル同期) の進捗**も出す
/// (`MailboxBackfillProgressQuery`)。両者は全く別の系統 — こちらの
/// 「操作同期」は*この端末で行った操作をサーバーへ送る*キューの話で、
/// 「完了」と出ていてもメールの取り込みが終わったことは意味しない。実際
/// その取り違えが起きたので、同じ画面に並べたうえで文言でも切り分ける。
struct OpQueueDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var pendingSummaries: [OpQueueDiagnosticsQuery.PendingSummary] = []
    @State private var replayLog: [OpQueueReplayLogRecord] = []
    /// Task (opqueue スタック修正、診断画面強化): 「今すぐ再送を実行」
    /// ボタンの実行中フラグと直近の結果 — `isRunningManualReplay`は二重
    /// タップ防止とプログレス表示の両方に使う。
    @State private var isRunningManualReplay = false
    @State private var manualReplayOutcomes: [ManualReplayOutcome] = []
    /// メール取得の進捗 (`MailboxBackfillProgressQuery`) — この型の doc
    /// comment 参照。
    @State private var backfillProgress: [MailboxBackfillProgressQuery.AccountProgress] = []
    /// 「未送信の操作を破棄」の確認ダイアログ対象。`isPresented`を別に
    /// 持つのは`confirmationDialog(_:isPresented:presenting:)`のため
    /// (`Binding`をその場で組み立てると`docs/ci.md`の型チェックタイムアウト
    /// 側に効いてくるので、素の`Bool`の`@State`にしている)。
    @State private var discardTarget: OpQueueDiagnosticsQuery.PendingSummary?
    @State private var isShowingDiscardConfirmation = false

    var body: some View {
        settingsContainer
            .navigationTitle("操作同期の診断")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: environment.accounts.map(\.id)) { await observe() }
            .confirmationDialog(
                "未送信の操作を破棄しますか?",
                isPresented: $isShowingDiscardConfirmation,
                presenting: discardTarget
            ) { summary in
                Button("破棄する", role: .destructive) { discardPending(for: summary) }
                    .accessibilityIdentifier("opQueueDiagnostics.pending.discardConfirm")
                Button("やめる", role: .cancel) {}
            } message: { summary in
                // 件数を差し込む実行時の文字列のため`Text(verbatim:)` — この
                // 画面の他の動的行 (再送結果・種類別内訳) と同じ扱い。
                Text(verbatim: "このアカウントの未送信の操作 \(summary.count) 件をサーバーへ送るのをやめ、キューから削除します。この端末で行った既読・移動などの表示はそのままで、次回サーバーと同期したときにサーバー側の状態に戻ります。")
            }
    }

    @ViewBuilder
    private var settingsContainer: some View {
        #if os(macOS)
        Form {
            sections
        }
        .formStyle(.grouped)
        #else
        List {
            sections
        }
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            if let lastInvokedAt = replayLog.first?.invokedAt {
                LabeledContent("最後に replay が起動した時刻") {
                    Text(Self.dateFormatter.string(from: lastInvokedAt))
                }
                .accessibilityIdentifier("opQueueDiagnostics.lastInvokedAt")
            } else {
                Text("まだ記録がありません。オフライン操作(既読化・アーカイブなど)の後、しばらくしても記録が現れない場合は再送の起動自体が行われていない可能性があります。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.replayLog.empty")
            }
        } footer: {
            Text("この端末でメールの既読化・アーカイブなどを行うたびに、サーバーへの再送処理 (replay) が呼ばれます。この時刻が更新され続けているなら再送処理自体は起動できています。")
        }

        Section {
            if pendingSummaries.isEmpty {
                Text("未送信の操作はありません。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.pending.empty")
            } else {
                ForEach(pendingSummaries, id: \.accountId) { summary in
                    PendingSummaryRow(
                        summary: summary,
                        accountDisplayName: accountDisplayName(for: summary.accountId),
                        onDiscard: { confirmDiscardPending(for: summary) }
                    )
                }
            }
        } header: {
            Text("未送信の操作 (アカウント別)")
        } footer: {
            Text("サーバーへまだ送信できていない操作の件数です。再試行待ち・恒久失敗の内訳、操作の種類別の内訳も確認できます。恒久失敗になった操作は「同期エラー」画面から個別に再試行・破棄できます。「未送信の操作を破棄」はそのアカウントの未送信操作をまとめて取り消します (送信待ちのメールも破棄されます)。")
        }

        Section {
            ManualReplayControl(
                isRunning: isRunningManualReplay,
                outcomes: manualReplayOutcomes,
                accountDisplayName: accountDisplayName(for:),
                onRun: { Task { await runManualReplay() } }
            )
        } header: {
            Text("手動再送")
        } footer: {
            Text("この端末にある全アカウントの未送信操作を、今すぐこの場でサーバーへ再送してみます。実機での挙動確認用のボタンです。")
        }

        Section {
            if replayLog.isEmpty {
                Text("まだ記録がありません。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.replayLogList.empty")
            } else {
                ForEach(replayLog) { entry in
                    ReplayLogRow(entry: entry, accountDisplayName: accountDisplayName(for: entry.accountId))
                }
            }
        } header: {
            Text("再送処理 (replay) の直近実行履歴")
        } footer: {
            Text("直近の実行履歴を一定件数まで保持します。「未完了」のまま残っている行は、その回だけアプリが途中で終了した可能性を示します。")
        }

        backfillSection
    }

    /// メール取得 (古いメールのバックフィル同期) の進捗 — この画面の
    /// doc comment 参照。上の各セクションと同じ`sections`の中に書くと1つの
    /// `body`式が長くなりすぎるため、独立した computed property にしている
    /// (`docs/ci.md`の型チェックタイムアウト対策)。
    @ViewBuilder
    private var backfillSection: some View {
        Section {
            if backfillProgress.isEmpty {
                Text("まだ記録がありません。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.backfill.empty")
            } else {
                ForEach(backfillProgress) { progress in
                    BackfillProgressRow(progress: progress, accountDisplayName: accountDisplayName(for: progress.accountId))
                }
            }
        } header: {
            Text("メール取得の進捗 (操作同期とは別)")
        } footer: {
            Text("古いメールをさかのぼって取り込む処理の進み具合です。上の「操作同期」とは別の処理で、こちらが完了していないと、検索や「すべてのメール」の件数がこの端末だけ少なく見えます。バックグラウンドで少しずつ進み、完了すると「取得完了」になります。")
        }
    }

    private func accountDisplayName(for accountId: String) -> String {
        environment.accounts.first(where: { $0.id == accountId })?.displayName ?? accountId
    }

    private func observe() async {
        let accountIds = environment.accounts.map(\.id)
        async let pendingTask: Void = observePendingSummaries(accountIds: accountIds)
        async let replayLogTask: Void = observeReplayLog()
        async let backfillTask: Void = observeBackfillProgress(accountIds: accountIds)
        _ = await (pendingTask, replayLogTask, backfillTask)
    }

    private func observePendingSummaries(accountIds: [String]) async {
        let observation = OpQueueDiagnosticsQuery.pendingSummaryByAccountObservation(accountIds: accountIds, maxAttempts: OpQueueProcessor.maxAttempts)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                pendingSummaries = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    private func observeBackfillProgress(accountIds: [String]) async {
        let observation = MailboxBackfillProgressQuery.progressObservation(accountIds: accountIds)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                backfillProgress = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    /// 「未送信の操作を破棄」のタップハンドラ — 破壊的な操作なので、ここ
    /// では確認ダイアログを出すだけ (実行は`discardPending(for:)`)。
    private func confirmDiscardPending(for summary: OpQueueDiagnosticsQuery.PendingSummary) {
        discardTarget = summary
        isShowingDiscardConfirmation = true
    }

    /// 確認後の実削除。`OpQueue.discardAll(accountId:kind:db:)`が`opQueue`
    /// 行と`send`op の`outboxMessage`をまとめて消す (副作用の判断理由は
    /// そちらのdoc comment)。一覧は`ValueObservation`が拾って自動更新される
    /// ので、ここで再取得はしない。
    private func discardPending(for summary: OpQueueDiagnosticsQuery.PendingSummary) {
        let accountId = summary.accountId
        Task {
            try? await environment.database.dbWriter.write { db in
                try OpQueue.discardAll(accountId: accountId, db: db)
            }
            discardTarget = nil
        }
    }

    /// Task (opqueue スタック修正、診断画面強化): 「今すぐ再送を実行」の
    /// タップハンドラ本体。`isRunningManualReplay`の二重タップガードは
    /// `guard`一発 (実行中に連打されても2本目以降は即 return) — `defer`で
    /// 確実にフラグを戻す。
    private func runManualReplay() async {
        guard !isRunningManualReplay else { return }
        isRunningManualReplay = true
        defer { isRunningManualReplay = false }
        manualReplayOutcomes = await environment.replayOpQueueNowForDiagnostics(accountIds: environment.accounts.map(\.id))
    }

    private func observeReplayLog() async {
        do {
            for try await fetched in replayLogObservation.values(in: environment.database.dbWriter) {
                replayLog = fetched
            }
        } catch {
            // A failing observation just stops the list from updating further.
        }
    }

    private var replayLogObservation: ValueObservation<ValueReducers.Fetch<[OpQueueReplayLogRecord]>> {
        ValueObservation.tracking { db in try OpQueueDiagnosticsQuery.recentReplayLog(limit: OpQueueProcessor.replayLogCap, db: db) }
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// アカウント1件分の未送信サマリ表示 — `CLAUDE.md`の「1つの`body`を長く
/// 書かない」方針に沿って独立させた。
private struct PendingSummaryRow: View {
    let summary: OpQueueDiagnosticsQuery.PendingSummary
    let accountDisplayName: String
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                // `accountDisplayName`はアカウントの表示名という実行時の値
                // のため`Text(verbatim:)` (`AccountFilterChip.swift`の教訓)。
                Text(verbatim: accountDisplayName)
                    .font(.caption.bold())
                Spacer()
                Text(verbatim: "\(summary.count)件")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            Text(verbatim: "最古の enqueue: \(OpQueueDiagnosticsView.dateFormatter.string(from: summary.oldestCreatedAt))")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.inkSecondary)
            Text(verbatim: "未試行 \(summary.neverAttemptedCount) / 再試行待ち \(summary.retryingCount) / 恒久失敗 \(summary.permanentlyFailedCount)")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.inkSecondary)
            // Task (opqueue スタック修正、診断画面強化): 種類別の内訳 —
            // 「1055件がどの操作で積み上がったか」を切り分けるための行。
            if !summary.countByKind.isEmpty {
                Text(verbatim: OpQueueKindDisplay.breakdownText(summary.countByKind))
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.pending.kindBreakdown")
            }
            // ユーザー要望 (2026-08-07「未送信の操作はキャンセルして削除
            // できるようにして」): 「同期エラー」画面の個別「破棄」は恒久
            // 失敗した op しか対象にできず、再試行待ちのまま延々と積み上が
            // った塊 (実機では1000件超) を片付ける手段が無かった。
            Button("未送信の操作を破棄", role: .destructive, action: onDiscard)
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("opQueueDiagnostics.pending.discardButton")
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("opQueueDiagnostics.pending.row")
    }
}

/// メール取得の進捗、アカウント1件分 — `PendingSummaryRow`と同じ理由で
/// 独立したビューにしている。
private struct BackfillProgressRow: View {
    let progress: MailboxBackfillProgressQuery.AccountProgress
    let accountDisplayName: String

    /// 未完了メールボックスを何件まで並べるか — 診断画面とはいえ、ラベルを
    /// 数十個持つ Gmail アカウントで全件出すと他のセクションが埋もれるため。
    /// 残りは「ほか N 件」に畳む。
    private static let visibleMailboxLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                Text(verbatim: accountDisplayName)
                    .font(.caption.bold())
                Spacer()
                Text(verbatim: "取り込み済み \(progress.syncedMessageCount.formatted()) 件")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            if progress.isComplete {
                // 件数を差し込むため`Label(_:systemImage:)`(`LocalizedStringKey`)
                // ではなく`Text(verbatim:)`を包む形にしている — この画面の
                // 他の動的行と同じ扱い。
                Label {
                    Text(verbatim: "取得完了 (\(progress.mailboxCount) 個のメールボックス)")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .font(.caption2)
                .foregroundStyle(OtegamiColor.accent)
                .accessibilityIdentifier("opQueueDiagnostics.backfill.complete")
            } else {
                Text(verbatim: "取得中 \(progress.pendingMailboxes.count) / \(progress.mailboxCount) メールボックス")
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("opQueueDiagnostics.backfill.pendingCount")
                ForEach(progress.pendingMailboxes.prefix(Self.visibleMailboxLimit)) { mailbox in
                    BackfillMailboxRow(mailbox: mailbox)
                }
                if progress.pendingMailboxes.count > Self.visibleMailboxLimit {
                    Text(verbatim: "ほか \(progress.pendingMailboxes.count - Self.visibleMailboxLimit) 件")
                        .font(.caption2)
                        .foregroundStyle(OtegamiColor.inkSecondary)
                }
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("opQueueDiagnostics.backfill.row")
    }
}

/// まだ遡り切れていないメールボックス1件分の行。割合はあくまで UID 範囲
/// ベースの目安 (`MailboxBackfillProgressQuery.MailboxProgress
/// .scannedFraction`のdoc comment参照) なので、実際の件数と併記する。
private struct BackfillMailboxRow: View {
    let mailbox: MailboxBackfillProgressQuery.MailboxProgress

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // メールボックスの表示名はサーバー由来の実行時の値のため
            // `Text(verbatim:)` (`AccountFilterChip.swift`の教訓)。
            Text(verbatim: mailbox.displayPath)
                .font(.caption2)
                .foregroundStyle(OtegamiColor.inkSecondary)
                .lineLimit(1)
            Spacer()
            Text(verbatim: detailText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier("opQueueDiagnostics.backfill.mailboxRow")
    }

    private var detailText: String {
        guard let fraction = mailbox.scannedFraction else {
            return "未同期"
        }
        let percent = Int((fraction * 100).rounded())
        return "\(percent)% ・ \(mailbox.syncedMessageCount.formatted()) 件"
    }
}

/// Task (opqueue スタック修正、診断画面強化): `OpQueueRecord.kind`の生の
/// 文字列 (`SyncEngine.OpQueueKind`のrawValue) を、この画面用の日本語
/// ラベルへ変換する。`OpQueueDiagnosticsQuery.PendingSummary.countByKind`
/// が`OtegamiStore`側で文字列キーのまま持つ理由 (`SyncEngine`への依存を
/// 増やさないため) は同型のdoc comment参照 — ここ (アプリ側、既に
/// `SyncEngine`をimport済み) で初めて型付きの`OpQueueKind`に戻して表示名を
/// 決める。
enum OpQueueKindDisplay {
    static func displayName(for raw: String) -> String {
        switch OpQueueKind(rawValue: raw) {
        case .setFlags: "既読/フラグ変更"
        case .move: "移動"
        case .delete: "ゴミ箱へ移動"
        case .junk: "迷惑メールへ移動"
        case .archive: "アーカイブ"
        case .unarchive: "アーカイブ解除"
        case .send: "送信"
        case .saveDraft: "下書き保存"
        case .deleteDraft: "下書き削除"
        case nil: raw
        }
    }

    /// 件数の多い順に「表示名 件数」を` / `区切りで並べる。
    static func breakdownText(_ countByKind: [String: Int]) -> String {
        countByKind
            .sorted { $0.value > $1.value }
            .map { "\(displayName(for: $0.key)) \($0.value)" }
            .joined(separator: " / ")
    }
}

/// Task (opqueue スタック修正、診断画面強化): 「今すぐ再送を実行」ボタン
/// と、実行後の結果一覧。`OpQueueDiagnosticsView.sections`の`body`を長く
/// しないための独立ビュー (`CLAUDE.md`の「SwiftUIビューは小さく保つ」方針)。
private struct ManualReplayControl: View {
    let isRunning: Bool
    let outcomes: [ManualReplayOutcome]
    let accountDisplayName: (String) -> String
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Button(action: onRun) {
                if isRunning {
                    HStack(spacing: OtegamiSpacing.xs) {
                        ProgressView()
                        Text("実行中…")
                    }
                } else {
                    Text("今すぐ再送を実行")
                }
            }
            .disabled(isRunning)
            .accessibilityIdentifier("opQueueDiagnostics.manualReplay.button")

            if !isRunning && !outcomes.isEmpty {
                ForEach(outcomes) { outcome in
                    ManualReplayOutcomeRow(outcome: outcome, accountDisplayName: accountDisplayName(outcome.accountId))
                }
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
    }
}

/// `ManualReplayControl`の実行結果1件 (1アカウント分) の表示 — 成功時は
/// `OpQueueProcessor.ReplayResult`の内訳、失敗時はエラー文言を出す。
private struct ManualReplayOutcomeRow: View {
    let outcome: ManualReplayOutcome
    let accountDisplayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text(verbatim: accountDisplayName)
                .font(.caption.bold())
            if let result = outcome.result {
                Text(verbatim: "成功 \(result.succeeded) / 破棄 \(result.discardedStale) / 再試行待ち \(result.retrying) / 恒久失敗 \(result.permanentlyFailed)")
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            if let errorDescription = outcome.errorDescription {
                Text(verbatim: errorDescription)
                    .font(.caption2.monospaced())
                    .foregroundStyle(OtegamiColor.destructive)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("opQueueDiagnostics.manualReplay.outcomeRow")
    }
}

/// replay実行履歴1件分の表示 — `PendingSummaryRow`と同じ理由で独立させた。
private struct ReplayLogRow: View {
    let entry: OpQueueReplayLogRecord
    let accountDisplayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                Text(verbatim: accountDisplayName)
                    .font(.caption.bold())
                Spacer()
                Text(OpQueueDiagnosticsView.dateFormatter.string(from: entry.invokedAt))
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            outcomeView
            if entry.parsedOutcome == .completed || entry.parsedOutcome == .aborted {
                Text(verbatim: "成功 \(entry.succeeded) / 破棄 \(entry.discardedStale) / 再試行待ち \(entry.retrying) / 恒久失敗 \(entry.permanentlyFailed)")
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            if let errorDescription = entry.errorDescription {
                Text(verbatim: errorDescription)
                    .font(.caption2.monospaced())
                    .foregroundStyle(OtegamiColor.destructive)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("opQueueDiagnostics.replayLog.row")
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch entry.parsedOutcome {
        case .inProgress:
            Label("未完了 (アプリが途中で終了した可能性があります)", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.destructive)
        case .coalesced:
            Label("他の再送処理と統合されました (何もしていません)", systemImage: "arrow.triangle.merge")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.inkSecondary)
        case .completed:
            Label("完了", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.accent)
        case .aborted:
            Label("中断 (接続エラーなど)", systemImage: "xmark.octagon")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.destructive)
        case nil:
            Label("不明", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        OpQueueDiagnosticsView()
    }
    .environment(AppEnvironment())
}
