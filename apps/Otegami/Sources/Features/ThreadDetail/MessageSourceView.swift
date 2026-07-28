import SwiftUI
import OtegamiStore

/// Task #103 ("ソースを表示" — 表示崩れメールの eml を受け渡す調査経路):
/// モノスペースの生 RFC822 ソース表示 + シェアで `.eml` として書き出す。
/// フッターツールバーの「その他」メニュー (既定) から開くシート
/// (`ThreadDetailView.sourceSheet`)。読み込み状態はすべて`loader`
/// (`MessageSourceLoader`) 側 — このビュー自身は`CalendarInviteSectionView`
/// と同じ「状態を出し分けるだけ」の薄いラッパーで、ロード中/エラー(再試行
/// 付き)/表示のいずれかを常に描画する (無言で何も出ない状態を作らない)。
struct MessageSourceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let messageId: Int64
    let accountId: String
    let subject: String?

    @State private var loader = MessageSourceLoader()

    var body: some View {
        NavigationStack {
            Group {
                switch loader.state {
                case .idle, .loading:
                    loadingView
                case .loaded(let source):
                    sourceView(source)
                case .failed(let message):
                    errorView(message)
                }
            }
            .navigationTitle("メールのソース")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("messageSource.closeButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .loaded(let source) = loader.state {
                        ShareLink(item: source.shareURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("messageSource.shareButton")
                    }
                }
            }
        }
        .tint(OtegamiColor.accent)
        .onAppear {
            loader.load(messageId: messageId, accountId: accountId, subject: subject, environment: environment)
        }
        .accessibilityIdentifier("messageSource.navigationStack")
    }

    private var loadingView: some View {
        VStack(spacing: OtegamiSpacing.sm) {
            ProgressView()
            Text("ソースを読み込んでいます…")
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("messageSource.loading")
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: OtegamiSpacing.md) {
            Text(message)
                .font(OtegamiFont.subheadline())
                .foregroundStyle(OtegamiColor.destructive)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OtegamiSpacing.lg)
                .accessibilityIdentifier("messageSource.error")
            Button(String(localized: "再試行"), action: retry)
                .accessibilityIdentifier("messageSource.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// モノスペース・スクロール表示 (`OtegamiFont.monospaceBody()`) —
    /// `.textSelection(.enabled)`でコピーも可能。巨大メール対策の切り詰め
    /// (`MessageSourceLoader.previewByteLimit`) を超えた場合は下部に注記を
    /// 出す — 表示自体は先頭部分のみだが、シェア (`ShareLink`) は常に全文。
    private func sourceView(_ source: MessageSourceLoader.DisplaySource) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(source.previewText)
                .font(OtegamiFont.monospaceBody())
                .foregroundStyle(OtegamiColor.ink)
                .textSelection(.enabled)
                .padding(OtegamiSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if source.isTruncated {
                Text("表示は先頭512KBまでです。全文はシェアで書き出せます。")
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .padding(OtegamiSpacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(OtegamiColor.surface)
                    .accessibilityIdentifier("messageSource.truncatedNote")
            }
        }
        .accessibilityIdentifier("messageSource.content")
    }

    private func retry() {
        loader.retry(messageId: messageId, accountId: accountId, subject: subject, environment: environment)
    }
}
