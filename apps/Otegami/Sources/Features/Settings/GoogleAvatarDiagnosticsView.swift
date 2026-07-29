import SwiftUI
import GoogleOAuth
import OtegamiStore

/// Task #42「アバター診断」(最優先): 実機で Google プロフィール写真が
/// まだ出ないという報告の原因を、ユーザーが撮った1枚のスクリーンショット
/// だけで確定させるための画面。`AccountEditView`の「アバター診断」導線
/// から開く。開いた瞬間 (`.task`) に
/// `GoogleProfilePhotoAvatarResolver.forceRebuildDiagnostics(accountId:)`
/// を呼び、索引を実際に強制再構築しながらその結果を丸ごと表示する:
///
/// - スコープ3状態 (`GoogleScopeDiagnosisRow`、`AccountEditView`の「認証」
///   節と同じ表示)。
/// - `otherContacts.list`/`people/me/connections`/`people/me`それぞれの
///   HTTP ステータス・取得エントリ数・写真ありエントリ数・エラー時の
///   レスポンス本文冒頭 (メールアドレスはマスクして表示)。
/// - 索引の総アドレス数・最終構築時刻。
/// - 構築が「破棄」されたか (`GooglePeopleFetchDiagnostics.discarded`) —
///   ページ途中の失敗で索引全体を破棄する現在の実装は握り潰さず、破棄が
///   起きた事実とその理由をそのまま表示する。
struct GoogleAvatarDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment
    let account: AccountRecord

    @State private var diagnostics: GoogleAvatarAccountDiagnostics?
    @State private var scopeDiagnosis: GoogleScopeDiagnosisState = .checking
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section("スコープ") {
                GoogleScopeDiagnosisRow(state: scopeDiagnosis)
            }

            if isRefreshing {
                Section {
                    HStack {
                        Text("Google に問い合わせて索引を再構築中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                }
                .accessibilityIdentifier("googleAvatarDiagnostics.loading")
            }

            if let diagnostics {
                if diagnostics.tokenFetchFailed {
                    Section {
                        Label("アクセストークンを取得できませんでした (再認証が必要な可能性があります)", systemImage: "xmark.octagon")
                            .foregroundStyle(OtegamiColor.destructive)
                            .accessibilityIdentifier("googleAvatarDiagnostics.tokenFetchFailed")
                    }
                }

                Section("otherContacts.list (自動収集された連絡先)") {
                    GooglePeopleSourceDiagnosticsRow(outcome: diagnostics.otherContacts, identifierPrefix: "googleAvatarDiagnostics.otherContacts")
                }
                Section("people/me/connections (保存済み連絡先)") {
                    GooglePeopleSourceDiagnosticsRow(outcome: diagnostics.connections, identifierPrefix: "googleAvatarDiagnostics.connections")
                }
                Section("people/me (自分のプロフィール写真)") {
                    GooglePeopleSourceDiagnosticsRow(outcome: diagnostics.selfPhoto, identifierPrefix: "googleAvatarDiagnostics.selfPhoto")
                }

                Section("索引") {
                    LabeledContent("総アドレス数", value: "\(diagnostics.totalIndexedAddresses)")
                        .accessibilityIdentifier("googleAvatarDiagnostics.totalIndexedAddresses")
                    LabeledContent("最終構築時刻", value: Self.dateFormatter.string(from: diagnostics.builtAt))
                        .accessibilityIdentifier("googleAvatarDiagnostics.builtAt")
                }
            }

            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    HStack {
                        Text("もう一度診断する")
                        if isRefreshing { Spacer(); ProgressView() }
                    }
                }
                .accessibilityIdentifier("googleAvatarDiagnostics.refreshButton")
                .disabled(isRefreshing)
            } footer: {
                Text("この画面を開くたびに Google へ実際に問い合わせて索引を再構築します。表示内容のスクリーンショットにはメールアドレスを含む場合があります (エラー本文中のアドレスはマスク済みですが、他の情報は含まれないか確認してから共有してください)。")
            }
        }
        .navigationTitle("アバター診断")
        #if os(macOS)
        // Task #155: see `AccountEditView`'s doc comment on this same
        // modifier — 長いラベルの`LabeledContent`行 (「最終構築時刻」等)
        // が既定の macOS `Form`スタイルでは崩れうるので、他の`Form`
        // 画面と同じく `.grouped` にしている。
        .formStyle(.grouped)
        .toggleStyle(.switch)
        #else
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
        .accessibilityIdentifier("googleAvatarDiagnostics.screen")
        #if os(macOS)
        // Task #155 follow-up: see `MacSettingsBackButton`'s doc comment —
        // this screen is pushed from `AccountEditView`.
        .macSettingsBackButton()
        #endif
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        async let scopeTask: Void = refreshScopeDiagnosis()
        diagnostics = await environment.googleAvatarDiagnostics(for: account)
        await scopeTask
    }

    private func refreshScopeDiagnosis() async {
        scopeDiagnosis = .checking
        guard let scope = await environment.googleGrantedScope(for: account) else {
            scopeDiagnosis = .unknown
            return
        }
        scopeDiagnosis = GoogleScopeDiagnosisState.diagnose(scope: scope)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// 1エンドポイント分の診断表示 (HTTP ステータス・エントリ数・破棄有無・
/// エラー本文) — `GoogleAvatarDiagnosticsView`の3回の呼び出しをまとめる
/// ためだけの、独立した`View`型。`ForEach`ではなく3箇所で個別に呼ばれる
/// だけだが、`CLAUDE.md`が求める「1つの`body`を長く書かない」方針に沿って
/// 切り出した。
private struct GooglePeopleSourceDiagnosticsRow: View {
    let outcome: GooglePeopleIndexOutcome
    let identifierPrefix: String

    var body: some View {
        LabeledContent("結果", value: resultLabel)
            .accessibilityIdentifier("\(identifierPrefix).result")
        if let httpStatus = outcome.diagnostics.httpStatus {
            LabeledContent("HTTP ステータス", value: "\(httpStatus)")
                .accessibilityIdentifier("\(identifierPrefix).httpStatus")
        }
        LabeledContent("取得エントリ数", value: "\(outcome.diagnostics.entriesFetched)")
            .accessibilityIdentifier("\(identifierPrefix).entriesFetched")
        LabeledContent("写真ありエントリ数", value: "\(outcome.diagnostics.entriesWithPhoto)")
            .accessibilityIdentifier("\(identifierPrefix).entriesWithPhoto")
        if outcome.diagnostics.discarded {
            // タスク#43: `discardReason ?? "..."`のまま`Label(String, ...)`
            // へ渡すと`String`型の verbatim オーバーロードに解決され、
            // 固定の既定文言側までカタログを引けなくなる
            // (`docs/localization.md`の「`Text(String)`は自動でローカライズ
            // されない」節と同じ問題)。`discardReason`自体は動的な診断詳細
            // (翻訳対象外) だが、既定文言は固定 UI 文言なので分岐して
            // `LocalizedStringKey`解決になる方へ渡す。
            if let discardReason = outcome.diagnostics.discardReason {
                Label(discardReason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("\(identifierPrefix).discarded")
            } else {
                Label("索引の一部が破棄されました", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("\(identifierPrefix).discarded")
            }
        }
        if let networkError = outcome.diagnostics.networkErrorDescription {
            Text("ネットワークエラー: \(networkError)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix).networkError")
        }
        if let snippet = outcome.diagnostics.errorBodySnippet {
            Text(GooglePeopleDiagnosticsFormatting.maskEmailAddresses(in: snippet))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix).errorBodySnippet")
        }
    }

    private var resultLabel: String {
        // タスク#43: `LabeledContent(_:value:)`の`value:`はStringをverbatim
        // 表示する (`docs/localization.md`の switch→`String(localized:)`
        // パターン1) — 固定文言の2ケースだけ明示的にカタログを引く。
        // `.success`は件数が動的なため対象外のまま (既存の「補間文字列は
        // 対象外」方針を踏襲)。
        switch outcome.result {
        case .success(let index): "成功 (\(index.count)件)"
        case .insufficientScope: String(localized: "スコープ不足")
        case .unavailable: String(localized: "取得失敗")
        }
    }
}
