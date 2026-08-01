import SwiftUI
import PushRelayClient

/// Task #213 — 設定 → プッシュ通知 → 「プッシュ通知の診断」から開く画面。
/// `TranslationDiagnosticsView`と同じ発想: Mac に接続して `log
/// stream`/Console.app を操作しなくても、この端末だけでスクリーンショット
/// 1枚を撮ればどの段階で失敗しているか (特に Yahoo! JAPAN アカウントの
/// 実機報告、`docs/architecture.md`の落とし穴 i. 参照) が分かるようにする。
///
/// `environment.pushDiagnostics`(`PushDiagnosticsStore`) が別プロセスの
/// `NotificationService`が共有 App Group `UserDefaults`へ書いた記録を読む
/// — この画面を開くたび (`.task`) と「更新」ボタンで明示的に
/// `refresh()`を呼ぶ (`PushDiagnosticsStore`のdoc comment参照、他プロセス
/// の書き込みはこのプロセスへ自動通知されない)。
///
/// 表示内容は本文・件名・差出人・資格情報を一切含まない
/// (`PushDiagnosticsRun`のdoc comment参照) — 各段階の成否の種別
/// (`category`)・レート制限の疑い・所要時間だけ。
struct PushDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        settingsContainer
            .navigationTitle("プッシュ通知の診断")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .macSettingsBackButton()
            #endif
            .task { environment.pushDiagnostics.refresh() }
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
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Button {
                environment.pushDiagnostics.refresh()
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("pushDiagnostics.refreshButton")
        } footer: {
            Text("通知を処理した端末自身の記録です。本文・件名・差出人・資格情報は一切記録しません。各段階の成否の種別と所要時間のみを保存します（最大20件）。")
        }

        Section {
            if environment.pushDiagnostics.runs.isEmpty {
                Text("まだ記録がありません。通知が届くと記録されます。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("pushDiagnostics.empty")
            } else {
                ForEach(environment.pushDiagnostics.runs) { run in
                    PushDiagnosticsRunRow(run: run)
                }
            }
        } header: {
            Text("直近の通知処理")
        }
    }
}

/// 通知1件分の処理記録 — 独立した`View`型にしたのは
/// `TranslationAttemptRow`/`LanguageDetectionAttemptRow`と同じ理由
/// (`CLAUDE.md`の「1つの`body`を長く書かない」方針、CIの型チェック
/// タイムアウト対策)。
private struct PushDiagnosticsRunRow: View {
    let run: PushDiagnosticsRun

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                Text(Self.dateFormatter.string(from: run.date))
                    .font(.caption.bold())
                Spacer()
                if let totalElapsedMs = run.totalElapsedMs {
                    Text(verbatim: "\(totalElapsedMs)ms")
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                }
            }
            ForEach(run.stages) { stage in
                PushDiagnosticsStageRow(stage: stage)
            }
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("pushDiagnostics.run")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// 1段階分 (`PushDiagnosticsRun.Stage`) の表示 — `PushDiagnosticsRunRow`と
/// 同じ理由で独立させた。
private struct PushDiagnosticsStageRow: View {
    let stage: PushDiagnosticsRun.StageRecord

    var body: some View {
        HStack(alignment: .top, spacing: OtegamiSpacing.xs) {
            stageLabel(for: stage.stage)
                .font(OtegamiFont.caption())
            Spacer()
            if let elapsedMs = stage.elapsedMs {
                Text(verbatim: "\(elapsedMs)ms")
                    .font(.caption2)
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            outcomeView
        }
        .accessibilityIdentifier("pushDiagnostics.stage")
    }

    /// 8段階それぞれの日本語表示名 — Task #213 の依頼文そのままの語彙
    /// (通知の解析/設定の読み取り/アカウントの引き当て/資格情報の取得/
    /// 接続/メールボックス選択/見出し取得/本文取得)。ローカライズ対象
    /// (`scripts/generate-localizable.py`にエントリあり)。
    @ViewBuilder
    private func stageLabel(for stage: PushDiagnosticsRun.Stage) -> some View {
        switch stage {
        case .parsePayload: Text("通知の解析")
        case .preferences: Text("設定の読み取り")
        case .accountLookup: Text("アカウントの引き当て")
        case .credential: Text("資格情報の取得")
        case .connect: Text("接続")
        case .select: Text("メールボックス選択")
        case .fetchEnvelope: Text("見出し取得")
        case .fetchBody: Text("本文取得")
        }
    }

    /// `category`/`reason`/`logDetail`はいずれも実行時の文字列 (Swift
    /// パッケージ側の分類結果・エラー種別名) — `AccountFilterChip.swift`の
    /// 教訓どおり `Text(verbatim:)` で組み立て、`LocalizedStringKey`経由の
    /// Markdown解釈を避ける。`TranslationAttemptRow.outcomeView`の
    /// `.failure`ケースと同じパターン。
    @ViewBuilder
    private var outcomeView: some View {
        switch stage.outcome {
        case .success:
            Label("成功", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(OtegamiColor.accent)
        case .skipped(let reason):
            Label {
                Text(verbatim: "スキップ: \(reason)")
            } icon: {
                Image(systemName: "arrow.forward.circle")
            }
            .font(.caption2)
            .foregroundStyle(OtegamiColor.inkSecondary)
        case .failure(let category, let looksRateLimited, let logDetail):
            VStack(alignment: .trailing, spacing: 2) {
                Label {
                    Text(verbatim: looksRateLimited ? "失敗: \(category) (レート制限の疑いあり)" : "失敗: \(category)")
                } icon: {
                    Image(systemName: "xmark.octagon")
                }
                .font(.caption2)
                .foregroundStyle(OtegamiColor.destructive)
                if let logDetail {
                    Text(verbatim: logDetail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PushDiagnosticsView()
    }
    .environment(AppEnvironment())
}
