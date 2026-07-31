import SwiftUI
import OtegamiStore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        #if os(macOS)
        // Task #205 (実機報告「mac 版では view source で何も表示されない」):
        // M10 fix と同じ原因 — macOS は `.sheet` を `NavigationStack { ... }`
        // 中身の内在サイズからは算出せず、この画面のように中身が
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)` だけの柔軟な
        // レイアウト (このビューは `List` すら持たない) だと算出できる
        // 内在サイズが無いに等しく、シートがタイトルバー＋ツールバーだけの
        // ほぼ無に近い高さで開いていた (`AccountTypeSelectionView`等の doc
        // comment参照 — `AccountSetupView`/`AccountsSettingsView`/
        // `ICloudAccountSetupView`等、同じ形のシート全部に既に適用済みの
        // 定番修正だが、Task #103 でこの画面を追加したときにこの1行だけ
        // 付け忘れていた)。iOS は `.sheet` が画面いっぱいに広がる既定の
        // 挙動なのでこの問題自体が起きない (`CLAUDE.md` 通り iOS の挙動は
        // 変えていない)。生ソース (RFC822、長いヘッダ行を折り返さず表示—
        // `MonospaceSourceTextView`のdoc comment参照) を読むための画面なので
        // 他の設定シート (480x420) よりやや広めに確保する。
        .frame(minWidth: 640, minHeight: 480)
        #endif
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

    /// モノスペース表示、コピー可能。巨大メール対策の切り詰め
    /// (`MessageSourceLoader.previewByteLimit`) を超えた場合は下部に注記を
    /// 出す — 表示自体は先頭部分のみだが、シェア (`ShareLink`) は常に全文。
    ///
    /// Task #111 (実機報告: このシートを開くと画面が空白になる — 数十KB級の
    /// 実メールで再現): 元実装は`ScrollView`の中で切り詰め後の文字列
    /// (最大512KB) をまるごと1つの`Text`に渡していた。SwiftUI の`Text`を
    /// `ScrollView`にネストして巨大な多行文字列を渡すと、レイアウトが
    /// 内部で Core Graphics のテクスチャサイズ上限相当に達し、エラーも
    /// クラッシュもせず**無言で何も描画しない**という既知の挙動を踏む —
    /// シェアシートからの`.eml`書き出し (`MessageSourceLoader`側) は正常な
    /// ことから、原因は取得側でなく表示側のこの`Text`だろうという疑いが
    /// 実際の原因だった。`UITextView`/`NSTextView` (TextKit — 大量テキストの
    /// 表示・選択・スクロールのために作られている) を薄くラップした
    /// `MonospaceSourceTextView`に置き換えることでこの上限を回避する。
    private func sourceView(_ source: MessageSourceLoader.DisplaySource) -> some View {
        MonospaceSourceTextView(text: source.previewText)
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

/// Task #111 — see `MessageSourceView.sourceView(_:)`'s doc comment for why
/// this exists instead of a plain SwiftUI `Text` in a `ScrollView`. A thin
/// `UIViewRepresentable`/`NSViewRepresentable` around `UITextView`/
/// `NSTextView`: both are TextKit-backed and built to hold and scroll
/// through large bodies of text without the rendering ceiling a single
/// SwiftUI `Text` hits. Read-only but selectable (`isEditable = false`,
/// `isSelectable = true`) so copying still works, matching the
/// `.textSelection(.enabled)` behavior this replaces. Deliberately does
/// *not* wrap lines — like the `ScrollView([.horizontal, .vertical])` it
/// replaces, raw RFC822 source (long header lines especially) is shown
/// as-is with horizontal scrolling rather than reflowed, since reflowing
/// would make e.g. wrapped `Content-Type` parameter lines harder to read
/// than the original.
struct MonospaceSourceTextView: View {
    let text: String

    var body: some View {
        PlatformMonospaceTextView(text: text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
private struct PlatformMonospaceTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textColor = UIColor(OtegamiColor.ink)
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        let baseFont = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        view.textContainerInset = UIEdgeInsets(
            top: OtegamiSpacing.md, left: OtegamiSpacing.md, bottom: OtegamiSpacing.md, right: OtegamiSpacing.md
        )
        // No line wrapping — see this view's doc comment above.
        view.textContainer.widthTracksTextView = false
        view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.accessibilityIdentifier = "messageSource.textView"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}
#elseif os(macOS)
private struct PlatformMonospaceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = NSColor(OtegamiColor.ink)
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: OtegamiSpacing.md, height: OtegamiSpacing.md)
        // No line wrapping — see this view's doc comment above.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("messageSource.textView")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
#endif
