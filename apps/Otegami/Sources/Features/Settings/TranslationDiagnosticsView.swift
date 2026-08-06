import SwiftUI
import Translation
import OtegamiTranslation
import OtegamiTranslationApple

/// 2026-07-30 (実機フィードバック: 翻訳が理由不明のまま失敗し続ける報告が
/// 連続し、しかもユーザーが外出中で Mac が無く `log collect`/sysdiagnose
/// が採れない場面があった): `GoogleAvatarDiagnosticsView`と同じ発想 —
/// スクリーンショット1枚で原因を伝えられるようにするための、設定内の
/// 診断画面。「メールビューア」設定の「AI 機能」セクションから開く。
///
/// 表示内容 (すべて F15 の趣旨どおり本文そのものは一切含めない):
/// - `LanguageAvailability`の英語→日本語の判定 (source/target/status)。
/// - 「テスト翻訳を実行」ボタン — 固定の英文を`environment
///   .translationService`(実際にメール翻訳が使うのと同じインスタンス)へ
///   通し、成功なら訳文を、失敗ならエラーの domain/code/型名/説明を
///   そのまま表示する。
/// - `AppEnvironment.translationDiagnostics`が持つ直近の実際の翻訳試行
///   (最大5件、`TranslationDiagnosticsStore`のdoc comment参照) — 件数・
///   合計文字数・文字種比率・成否。
struct TranslationDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var languagePairStatus: String = "確認中…"
    @State private var isRunningTestTranslation = false
    @State private var testTranslationResult: TestTranslationResult?

    fileprivate enum TestTranslationResult {
        case success(String)
        case failure(domain: String, code: Int, type: String, description: String)
    }

    /// 固定の英文 — 実際のメール本文とは無関係、この画面専用。
    private static let testInputText = "This is a test message."

    var body: some View {
        settingsContainer
            .navigationTitle("翻訳の診断")
            .task {
                await refreshLanguagePairStatus()
                // 2026-07-30: `scripts/verify-screen.sh`のタップ不要経路用
                // — Translationはシミュレータで動かないため、これは
                // 「スピナーが止まりエラー表示になる (=ハングしない)」
                // ことをスクリーンショットで確認するためのフック。実機/
                // 通常起動ではこの引数が無いので常にno-op。
                if ProcessInfo.processInfo.arguments.contains("-uitestsRunTestTranslationDirectly") {
                    await runTestTranslation()
                }
                // 2026-07-30 (実機フィードバック — 2度目の退行「同じ
                // Configurationの再代入はSwiftUIから見て変化なし」):
                // 1回目のボタン操作の直後に発火する2回目のリクエストが
                // ちゃんとホストビューを再度起動できることを確認する
                // ためのフック — 1回目が完全に終わってから (`await`で
                // 直列に) 2回目を実行する、実際の「もう一度押す」操作と
                // 同じ順序。
                if ProcessInfo.processInfo.arguments.contains("-uitestsRunTestTranslationTwiceDirectly") {
                    await runTestTranslation()
                    await runTestTranslation()
                }
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
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            LabeledContent("言語ペア", value: "English → Japanese")
                .accessibilityIdentifier("translationDiagnostics.languagePair")
            // `Text(verbatim:)` — `languagePairStatus`はAppleのenum値の
            // 生の文字列描画 (`String(describing:)`) を含みうる実行時の値
            // のため、`AccountFilterChip.swift`の教訓どおり
            // `LocalizedStringKey`経由のMarkdown解釈を避ける。
            LabeledContent("判定結果") {
                Text(verbatim: languagePairStatus)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("translationDiagnostics.languagePairStatus")
        } header: {
            Text("言語データの状態")
        } footer: {
            Text("メール翻訳が実際に使う言語ペア (英語→日本語) について、Apple の Translation フレームワークに直接問い合わせた結果です。")
        }

        Section {
            SessionSupplyObservabilityView(coordinator: environment.translationSessionCoordinator)
        } header: {
            Text("セッション供給の状況")
        } footer: {
            // 2026-07-30 (実機フィードバック — 2度目の退行): 「設定要求」
            // だけ増えて「セッション供給」が増えない/一度も無いなら、
            // ホストビューの`.translationTask`クロージャが供給元から
            // 一度も呼ばれていないことをこの画面だけで即断できる —
            // 過去2回の退行 (ホストビュー未マウント、`Configuration`の
            // 等価判定) はどちらもこの2組の数字を見れば1枚の
            // スクリーンショットで切り分けられた。
            Text("「設定要求」はこの端末が新しい翻訳セッションを要求した回数、「セッション供給」はホストビューが実際にセッションを渡してきた回数です。前者だけ増え続けて後者が増えない場合、セッションの供給経路自体が機能していません。")
        }

        Section {
            Button {
                Task { await runTestTranslation() }
            } label: {
                HStack {
                    Text("テスト翻訳を実行")
                    if isRunningTestTranslation { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("translationDiagnostics.runTestButton")
            .disabled(isRunningTestTranslation)

            if let testTranslationResult {
                TestTranslationResultView(result: testTranslationResult)
            }
        } header: {
            Text("テスト翻訳")
        } footer: {
            Text("固定の英文 (\(Self.testInputText)) を実際にメール翻訳と同じ経路で翻訳します。メール本文は一切使いません。")
        }

        Section {
            if environment.translationDiagnostics.attempts.isEmpty {
                Text("まだ記録がありません。メールを開いて翻訳を試すか、上の「テスト翻訳を実行」をお試しください。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("translationDiagnostics.recentAttempts.empty")
            } else {
                ForEach(environment.translationDiagnostics.attempts) { attempt in
                    TranslationAttemptRow(attempt: attempt)
                }
            }
        } header: {
            Text("直近の翻訳試行 (最大5件)")
        } footer: {
            Text("実際にメールを翻訳しようとした際の記録です。件数・文字数・文字の種類の比率のみを表示し、メール本文そのものは表示しません。")
        }

        Section {
            if environment.translationDiagnostics.languageDetectionAttempts.isEmpty {
                Text("まだ記録がありません。メールを開くと記録されます。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("translationDiagnostics.recentLanguageDetections.empty")
            } else {
                ForEach(environment.translationDiagnostics.languageDetectionAttempts) { attempt in
                    LanguageDetectionAttemptRow(attempt: attempt)
                }
            }
        } header: {
            Text("直近の言語判定 (最大5件)")
        } footer: {
            // Task #203: プレーンテキスト/HTMLどちらの候補で言語判定できた
            // (できなかった) かをここで確認できる — 「翻訳元の言語を判定
            // できませんでした」のようなエラーの切り分け用。文字種比率のみ
            // で本文そのものは表示しない。
            Text("メールを開くたびに再判定した結果です。プレーンテキスト/HTML どちらの候補で判定できたか、文字の種類の比率のみを表示します。")
        }
    }

    private func refreshLanguagePairStatus() async {
        let status = await LanguageAvailability().status(from: Locale.Language(languageCode: .english), to: Locale.Language(languageCode: .japanese))
        languagePairStatus = String(describing: status)
    }

    private func runTestTranslation() async {
        isRunningTestTranslation = true
        defer { isRunningTestTranslation = false }
        do {
            let translated = try await environment.translationService.translate(Self.testInputText, from: .english, to: .japanese)
            testTranslationResult = .success(translated)
        } catch {
            let nsError = error as NSError
            testTranslationResult = .failure(
                domain: nsError.domain,
                code: nsError.code,
                type: String(describing: type(of: error)),
                description: error.localizedDescription
            )
        }
    }
}

/// テスト翻訳ボタンの結果表示だけを担う独立した`View`型 —
/// `CLAUDE.md`の「1つの`body`を長く書かない」方針に沿って切り出した
/// (SwiftUIビューの型チェックタイムアウト対策)。
private struct TestTranslationResultView: View {
    let result: TranslationDiagnosticsView.TestTranslationResult

    var body: some View {
        switch result {
        case .success(let translated):
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Label("成功", systemImage: "checkmark.circle")
                    .foregroundStyle(OtegamiColor.accent)
                Text(verbatim: translated)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("translationDiagnostics.testResult.success")
        case .failure(let domain, let code, let type, let description):
            VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                Label("失敗", systemImage: "xmark.octagon")
                    .foregroundStyle(OtegamiColor.destructive)
                Text(verbatim: "domain: \(domain)")
                Text(verbatim: "code: \(code)")
                Text(verbatim: "type: \(type)")
                Text(verbatim: description)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.monospaced())
            .accessibilityIdentifier("translationDiagnostics.testResult.failure")
        }
    }
}

/// 2026-07-30 (実機フィードバック — 2度目の退行「テスト翻訳を実行」が
/// またタイムアウトした): `TranslationSessionCoordinator`の供給側
/// カウンタをそのまま表示するだけの独立した`View`型 — 他の行と同じく
/// 型チェック負荷を分散する目的もあるが、ここでは特に「この画面が
/// `environment.translationSessionCoordinator`を直接観測できる」ことを
/// 素直な形で示す。`@Observable`な`coordinator`を直接プロパティに持つ
/// ので、`attach(_:)`/`requestNewConfiguration(target:)`が呼ばれるたびに
/// 自動的に再描画される。
private struct SessionSupplyObservabilityView: View {
    let coordinator: TranslationSessionCoordinator

    var body: some View {
        LabeledContent("設定要求") {
            Text(verbatim: "\(coordinator.configurationRequestCount)回" + lastTimeSuffix(coordinator.lastConfigurationRequestAt))
        }
        .accessibilityIdentifier("translationDiagnostics.configurationRequestCount")
        LabeledContent("セッション供給") {
            Text(verbatim: "\(coordinator.attachCallCount)回" + lastTimeSuffix(coordinator.lastAttachAt))
        }
        .accessibilityIdentifier("translationDiagnostics.attachCallCount")
        // 2026-08-06: 供給のうち ticket 不一致で捨てられた回数 — 「供給は
        // 来ているのに全部捨てられている」(今回の供給ズレ退行の症状) を
        // この画面のスクリーンショット1枚で切り分けるための行
        // (`TranslationSessionCoordinator.attachDiscardedCount`参照)。
        LabeledContent("供給の不一致破棄") {
            Text(verbatim: "\(coordinator.attachDiscardedCount)回")
        }
        .accessibilityIdentifier("translationDiagnostics.attachDiscardedCount")
    }

    private func lastTimeSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        return " / 最終 \(Self.dateFormatter.string(from: date))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// 直近の翻訳試行1件分の表示 — `TranslationAttemptRow`として独立させた
/// 理由も`TestTranslationResultView`と同じ (型チェック負荷の分散)。
private struct TranslationAttemptRow: View {
    let attempt: TranslationDiagnosticsStore.Attempt

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                Text(verbatim: attempt.kind)
                    .font(.caption.bold())
                Spacer()
                Text(Self.dateFormatter.string(from: attempt.date))
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            Text(verbatim: "要素数: \(attempt.elementCount) / 合計文字数: \(attempt.totalChars)")
                .font(OtegamiFont.caption())
            Text(verbatim: attempt.characterClassSummary)
                .font(.caption.monospaced())
                .foregroundStyle(OtegamiColor.inkSecondary)
            outcomeView
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("translationDiagnostics.attempt")
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch attempt.outcome {
        case .success(let resultChars):
            Label("成功 (結果 \(resultChars) 文字)", systemImage: "checkmark.circle")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.accent)
        case .failure(let domain, let code, let type, let description):
            VStack(alignment: .leading, spacing: 2) {
                // `Label { Text(verbatim:) } icon:` — `domain`/`type`は
                // Apple側のエラー型が返す実行時の値 (`AccountFilterChip
                // .swift`の教訓どおり、`Label(_:systemImage:)`の
                // `LocalizedStringKey`経由だとMarkdown解釈のリスクがある
                // ため`Text(verbatim:)`を使う)。
                Label {
                    Text(verbatim: "失敗: \(domain) code=\(code) (\(type))")
                } icon: {
                    Image(systemName: "xmark.octagon")
                }
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.destructive)
                Text(verbatim: description)
                    .font(.caption2.monospaced())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// 直近の言語判定1件分の表示 (Task #203) — `TranslationAttemptRow`と同じ
/// 理由 (`CLAUDE.md`の型チェック負荷分散方針) で独立させた `View`。
private struct LanguageDetectionAttemptRow: View {
    let attempt: TranslationDiagnosticsStore.LanguageDetectionAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            HStack {
                Text(verbatim: "言語判定")
                    .font(.caption.bold())
                Spacer()
                Text(Self.dateFormatter.string(from: attempt.date))
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            candidateSummaryView(label: "plainText", summary: attempt.plainTextSummary)
            candidateSummaryView(label: "html", summary: attempt.htmlSummary)
            outcomeView
        }
        .padding(.vertical, OtegamiSpacing.xs)
        .accessibilityIdentifier("translationDiagnostics.languageDetectionAttempt")
    }

    @ViewBuilder
    private func candidateSummaryView(label: String, summary: String?) -> some View {
        // `summary`はAppleの文字種比率計算の生の文字列描画のため
        // `Text(verbatim:)` (`AccountFilterChip.swift`の教訓どおり)。
        Text(verbatim: "\(label): \(summary ?? "(候補なし)")")
            .font(.caption.monospaced())
            .foregroundStyle(OtegamiColor.inkSecondary)
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch attempt.outcome {
        case .detected(let language, let source):
            Label {
                Text(verbatim: "判定成功: \(language) (使用したのは \(source.rawValue))")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(OtegamiFont.caption())
            .foregroundStyle(OtegamiColor.accent)
        case .undetected:
            Label("判定できず", systemImage: "questionmark.circle")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.destructive)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
