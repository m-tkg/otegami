import SwiftUI
import WebKit
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine
import os
#if os(iOS)
import SafariServices
#elseif os(macOS)
import AppKit
#endif

/// Renders an HTML message body: a `WKWebView` with page JavaScript
/// disabled and, independently, two kinds of image auto-display gated by
/// their own settings (`ImageSettingsStore`) — external (`http`/`https`)
/// resources via a `WKContentRuleList`, and embedded (`cid:`) images via
/// whether `CIDURLRewriter` even rewrites them to the resolvable
/// `otegami-cid://` scheme. The two settings stay independent (unblocking
/// one never touches the other), but they share a single "画像を表示"-style
/// banner (`imagesBanner`) — a plain tap-to-reveal button when only one
/// kind is actually blocked for this message, or a `Menu` offering both
/// choices when both are. Lifting a block only applies for that message,
/// for the rest of this app session — a relaunch (or opening a different
/// message) goes back to each setting's default.
///
/// The web view scrolls internally (rather than the SwiftUI-side content
/// being measured and sized to fit an outer `ScrollView`) — simpler and
/// more robust than measuring rendered height via injected JavaScript,
/// which would have needed page JavaScript to be at least partially
/// enabled just to answer "how tall is this content". `MessageView` gives
/// this view the remaining space below its (non-scrolling) header instead
/// of nesting it inside its own `ScrollView`.
///
/// M8/B5: `accountId`/`messageId`/`mailboxPath` back a `WKURLSchemeHandler`
/// for `cid:` inline images (`CIDSchemeHandler`, registered on the web
/// view's configuration below) — kept entirely independent of
/// `allowsExternalContent`/the `WKContentRuleList` (which only ever
/// matches `^https?://`), so `allowsEmbeddedImages` is a wholly separate
/// gate (whether `CIDURLRewriter` even runs at all) rather than being
/// folded into the same content-rule-list mechanism as remote images.
struct HTMLMessageView: View {
    let html: String
    let accountId: String
    let messageId: Int64
    let mailboxPath: String?
    /// Task #56 (実機フィードバック: 要約/翻訳フローティングボタンがHTML本文
    /// に被る): `MessageView.floatingButtonsReservedBottomInset`と同じ値を
    /// 渡してもらい、`HTMLDocumentBuilder.wrap(bodyHTML:...:bottomContentInset:)`
    /// が読み込む文書自体の末尾にその高さ分の余白 (spacer) を注入する —
    /// プレーンテキスト側の `.contentMargins(.bottom:)` と同じ「フローティング
    /// ボタンの分だけ最後にスクロールしても本文の下に空白を残す」効果を、
    /// `WKWebView`側でも実現する。`WKWebView`の`scrollView`(iOS)/相当機構
    /// (macOS) 経由の`contentInset`ではなく文書側にDOM要素を足す方式を選んだ
    /// のは、iOS/macOSで共通のコード1本になる (`WKWebView`はmacOSでは
    /// `UIScrollView`を持たない) のと、fit-to-width のスケール計算
    /// (`#otegami-fit-outer`/`#otegami-fit-inner`) の対象に含めない兄弟要素
    /// として置くことで、スケール処理と一切干渉しないため — 詳細は
    /// `HTMLDocumentBuilder.wrap(bodyHTML:autoAdjustColorsInDarkMode:
    /// bottomContentInset:)`のdoc comment参照。既定値 0 (呼び出し側が
    /// 明示的に渡さない限り、フローティングボタンぶんの余白は付かない)。
    let bottomContentInset: CGFloat

    /// 1i「HTMLメールもレイアウトを保持したまま翻訳」— `MessageView` owns the
    /// actual translation (it alone has `AppEnvironment.messageTranslator`
    /// and the bar's `MessageTranslationState`); this view only needs to
    /// know *what* to show. `nil` means "no translation to display" (not
    /// yet requested, still in flight, or failed) — the loaded document
    /// shows its own original text untouched, same as before this feature
    /// existed. Non-nil and `showOriginalText == false` means "overlay
    /// these translated strings onto the document's text nodes, in the same
    /// order `HTMLTranslationController.extractTranslatableTexts()` would
    /// produce them" — see that method's doc comment for why the ordering
    /// contract holds without either side needing to know about the
    /// other's internals.
    let translatedTexts: [String]?
    /// The bar's 訳文/原文 segment, mirrored down from `MessageView` —
    /// meaningless (ignored) when `translatedTexts == nil`.
    let showOriginalText: Bool
    /// Handed a live `HTMLTranslationController` once this view exists (and
    /// `nil` right before it's torn down, e.g. the user navigates to a
    /// different message) — `MessageView`'s translate button handler calls
    /// `extractTranslatableTexts()` on whatever controller this last
    /// reported. A plain callback rather than this view returning the
    /// controller some other way: SwiftUI views can't hand values back to
    /// their parent except through a binding or a callback like this one,
    /// and a `Binding<HTMLTranslationController?>` would let `MessageView`
    /// mistakenly think it could *assign* a new controller in, which makes
    /// no sense here (only this view can ever construct one, since only it
    /// creates the `WKWebView` the controller wraps).
    let onTranslationControllerReady: (HTMLTranslationController?) -> Void
    /// Task #58 (根治) — see `HTMLWebViewCoordinator.onHeightChange`'s doc
    /// comment for the full root-cause writeup this exists to fix. Default
    /// no-op so every other call site (none currently exist beyond
    /// `MessageView`, but this keeps the initializer source-compatible)
    /// doesn't have to opt in.
    let onHeightChange: (CGFloat) -> Void

    @Environment(AppEnvironment.self) private var environment
    /// Created once per `HTMLMessageView` instance (one per opened message,
    /// like `allowsExternalContent`/`allowsEmbeddedImages` below) —
    /// `HTMLWebViewRepresentable.makeUIView`/`makeNSView` fills in its
    /// `webView` the moment the platform view is created.
    @State private var translationController = HTMLTranslationController()
    /// B: both seeded from `ImageSettingsStore`'s persisted defaults in
    /// `init` — not `@AppStorage` directly, since `@AppStorage`'s own
    /// default-value parameter only applies the *first* time a given
    /// `@AppStorage` call site is read, and every `HTMLMessageView`
    /// instance (one per opened message — see `MessageView`) is a *new*
    /// call site each time; reading `UserDefaults.standard` explicitly
    /// here instead means each freshly opened message correctly reflects
    /// the current setting value, not just whatever the very first
    /// `HTMLMessageView` ever constructed happened to see.
    /// `UserDefaults.registerOtegamiImageDefaults()` (called once from
    /// `AppEnvironment.init()`) is what makes the un-set-key case resolve
    /// to the right default even before any explicit write.
    @State private var allowsExternalContent: Bool
    @State private var allowsEmbeddedImages: Bool
    /// Task #45「ダークモードで文字が読めない」— seeded the same way as the
    /// two image settings above (see their doc comment; same reasoning:
    /// this bakes into the loaded document itself via `HTMLDocumentBuilder
    /// .wrap(bodyHTML:autoAdjustColorsInDarkMode:)`, so a fresh read at
    /// `init` time — not `@AppStorage` — is what keeps each newly opened
    /// message honest about the current setting).
    @State private var autoAdjustColorsInDarkMode: Bool
    /// Task #71「メールの背景を常に白に」— seeded the same way as
    /// `autoAdjustColorsInDarkMode` just above (same reasoning: bakes into
    /// the loaded document via `HTMLDocumentBuilder.wrap(bodyHTML:
    /// autoAdjustColorsInDarkMode:forceLightBackground:)`).
    @State private var forceLightBackground: Bool

    // MARK: - C7 link handling

    /// "メール内リンクを開くブラウザ" — read fresh on every tap (`handleLinkTap`),
    /// not baked into a `@State` at `init` time the way the two image
    /// settings above are: this isn't part of what gets rendered into the
    /// loaded document, so there's no staleness risk in reading it via
    /// plain `@AppStorage` the normal way.
    @AppStorage(LinkBrowserSettingsStore.openInAppBrowserKey) private var openInAppBrowser = LinkBrowserSettingsStore.defaultOpenInAppBrowser
    #if os(iOS)
    /// Non-nil while `SFSafariViewController` is presented for a tapped
    /// link — `IdentifiableURL` only exists to give a plain `URL` the
    /// `Identifiable` conformance `.sheet(item:)` needs.
    @State private var presentedSafariURL: IdentifiableURL?
    #endif

    init(
        html: String, accountId: String, messageId: Int64, mailboxPath: String?,
        bottomContentInset: CGFloat = 0,
        translatedTexts: [String]? = nil, showOriginalText: Bool = false,
        onTranslationControllerReady: @escaping (HTMLTranslationController?) -> Void = { _ in },
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.html = html
        self.accountId = accountId
        self.messageId = messageId
        self.mailboxPath = mailboxPath
        self.bottomContentInset = bottomContentInset
        self.translatedTexts = translatedTexts
        self.showOriginalText = showOriginalText
        self.onTranslationControllerReady = onTranslationControllerReady
        self.onHeightChange = onHeightChange
        _allowsExternalContent = State(initialValue: UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowRemoteImagesKey))
        _allowsEmbeddedImages = State(initialValue: UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowEmbeddedImagesKey))
        _autoAdjustColorsInDarkMode = State(initialValue: UserDefaults.standard.bool(forKey: HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey))
        _forceLightBackground = State(initialValue: UserDefaults.standard.bool(forKey: HTMLDisplaySettingsStore.forceLightBackgroundKey))
    }

    private var hasExternalContent: Bool {
        HTMLExternalResourceScanner.containsExternalResource(html: html)
    }

    private var hasEmbeddedContent: Bool {
        CIDURLRewriter.containsCIDReference(html: html)
    }

    /// 画像バナー統合 (実機フィードバック追加分): 埋め込み画像とリモート画像を
    /// 個別にブロックしうる状態はそれぞれ独立 (`ImageSettingsStore`) だが、
    /// 両方が同時にブロックされているメールでは以前 `imagesBanner`
    /// の直下に2つのバナーが縦に並んでしまい、どちらが何を表示するのか
    /// 紛らわしかった。`isEmbeddedImagesBlocked`/`isExternalImagesBlocked`
    /// で状況を判定し `imagesBanner` (下) が実際の1つのバナーに集約する。
    private var isEmbeddedImagesBlocked: Bool { hasEmbeddedContent && !allowsEmbeddedImages }
    private var isExternalImagesBlocked: Bool { hasExternalContent && !allowsExternalContent }

    /// 画像バナー統合: ブロックされている種類がちょうど1つなら (従来と同じ)
    /// タップで即座にその種類を表示するボタン、2つとも同時にブロックされて
    /// いる場合だけ `Menu` でどちらを表示するか選ばせる。`body`
    /// (`@ViewBuilder` の外) から毎回再評価されるので、メニューで片方だけ
    /// 選んだ直後は自動的に「残り1種類だけブロックされている」状態に落ち、
    /// 次の再描画で単純ボタン表示に切り替わる — 「両方選んだ後にバナーが
    /// 消える」「片方選んだ後にメニューの残りの選択肢だけが残る」という
    /// 遷移を個別にコーディングする必要がない。
    ///
    /// アクセシビリティ識別子は既存のもの (`messageDetail
    /// .showEmbeddedImagesBanner`/`messageDetail.showImagesBanner`) を
    /// 単一種類ブロック時にそのまま流用 — 既存の XCUITest
    /// (`OtegamiImageSettingsUITests`/`OtegamiM8CIDImageUITests`) が
    /// 前提にしているラベル/識別子を変えない。
    @ViewBuilder
    private var imagesBanner: some View {
        if isEmbeddedImagesBlocked && isExternalImagesBlocked {
            Menu {
                Button {
                    allowsEmbeddedImages = true
                } label: {
                    Label("埋め込み画像を表示", systemImage: "photo")
                }
                .accessibilityIdentifier("messageDetail.imagesBanner.showEmbedded")
                Button {
                    allowsExternalContent = true
                } label: {
                    Label("リモート画像も読み込む", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("messageDetail.imagesBanner.showRemote")
            } label: {
                Label("画像を表示", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showImagesBanner")
        } else if isEmbeddedImagesBlocked {
            Button {
                allowsEmbeddedImages = true
            } label: {
                Label("埋め込み画像を表示", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showEmbeddedImagesBanner")
        } else if isExternalImagesBlocked {
            Button {
                allowsExternalContent = true
            } label: {
                Label("画像を表示", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showImagesBanner")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imagesBanner

            HTMLWebViewRepresentable(
                html: html,
                allowsExternalContent: allowsExternalContent,
                allowsEmbeddedImages: allowsEmbeddedImages,
                autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode,
                forceLightBackground: forceLightBackground,
                bottomContentInset: bottomContentInset,
                cidContext: CIDResolutionContext(
                    environment: environment, accountId: accountId, messageId: messageId, mailboxPath: mailboxPath
                ),
                translationController: translationController,
                onOpenLink: handleLinkTap,
                onHeightChange: onHeightChange
            )
            .accessibilityIdentifier("messageDetail.htmlWebView")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .sheet(item: $presentedSafariURL) { item in
            SafariViewRepresentable(url: item.url)
                .ignoresSafeArea()
        }
        #endif
        .onAppear { onTranslationControllerReady(translationController) }
        .onDisappear { onTranslationControllerReady(nil) }
        // 1i: whenever `MessageView` hands down a fresh translated-text
        // array or flips 訳文/原文, reflect it into the live document.
        // Re-running `applyTranslations` every time (not just once right
        // after a translation completes) is deliberate — it's cheap and
        // idempotent (`HTMLTranslationController.applyTranslations`'s doc
        // comment), and it's what makes this self-healing after
        // `HTMLWebViewCoordinator.load(...)` reloads the document from
        // scratch (e.g. an image-blocking banner toggled mid-session, which
        // wipes the DOM stamps a previous `applyTranslations` call left
        // behind) without this view needing to know that happened.
        .task(id: HTMLTranslationDisplayKey(showOriginal: showOriginalText, translatedTexts: translatedTexts)) {
            guard let translatedTexts, !translatedTexts.isEmpty else { return }
            if showOriginalText {
                await translationController.showOriginal()
            } else {
                await translationController.applyTranslations(translatedTexts)
                await translationController.showTranslated()
            }
        }
    }

    /// C7: where a tap on an `http(s)://` link inside message HTML ends up
    /// — normally via `HTMLWebViewCoordinator.decidePolicyFor`/
    /// `createWebViewWith`, which cancel the in-place navigation first (mail
    /// HTML never gets to actually browse away from itself) and call this
    /// instead; on this project's current toolchain those two delegate
    /// methods don't actually fire for a plain link tap (a confirmed
    /// platform anomaly, not an app bug — see `HTMLWebViewCoordinator
    /// .strayNavigationObservation`'s doc comment), so
    /// `recoverFromStrayNavigation` calls this too, as a delegate-
    /// independent fallback that reaches the same outcome. `javascript:`/
    /// other schemes never reach here at all (see `decidePolicyFor`), so
    /// this only ever has to decide *how* to open a legitimate web link,
    /// never whether to.
    private func handleLinkTap(_ url: URL) {
        #if os(iOS)
        if openInAppBrowser {
            presentedSafariURL = IdentifiableURL(url: url)
        } else {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        // macOS has no `SFSafariViewController` equivalent — see
        // `LinkBrowserSettingsStore`'s doc comment for why this setting is
        // iOS-only and every mail link on macOS always opens the system
        // default browser.
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(iOS)
/// Not `private` — `MessageView`'s plain-text body (`linkifiedText`) reuses
/// this same pair for the identical "アプリ内ブラウザ" behavior on a tapped
/// `http(s)://` link, so both the HTML and plain-text rendering paths
/// share one `SFSafariViewController` wrapper instead of two.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Wraps `SFSafariViewController` for `.sheet(item:)` presentation — the
/// "アプリ内ブラウザ" option (C7). A thin, state-free `UIViewControllerRepresentable`;
/// `SFSafariViewController` manages its own navigation UI (address bar,
/// reader/share/Safari-open buttons, its own "完了" dismiss) once presented,
/// so there's nothing else for this wrapper to coordinate.
struct SafariViewRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif

/// Everything `CIDSchemeHandler` needs to resolve a `cid:` reference to
/// bytes: which message's `attachment` rows to search, and how to fetch one
/// on demand if it isn't downloaded yet. A plain struct (not passed as
/// separate parameters down through the representable/coordinator/handler
/// chain) purely to keep those signatures short — `AppEnvironment` itself
/// is a `@MainActor` reference type, so capturing it here doesn't change
/// its isolation.
struct CIDResolutionContext {
    let environment: AppEnvironment
    let accountId: String
    let messageId: Int64
    let mailboxPath: String?
}

/// The full HTML document loaded into the web view: wraps the message's
/// body-only HTML (`MessageBodyContent.html`, from MailCore2's
/// `htmlBodyRendering()`) with a minimal reset so it reads legibly in both
/// light and dark mode without the message's own styling fighting the
/// app's chrome (plan: "背景透過・文字色継承・max-width: 100%・画像縮小").
///
/// 実機フィードバック第3弾 (B): a marketing/notification HTML mail (参考画像1)
/// rendered at desktop width — a large logo cropped, text pushed off the
/// right edge — despite this file already carrying a viewport `<meta>` and
/// `max-width: 100% !important` on images/tables *before* this fix. See
/// `extractBodyContent(from:)`'s doc comment for the actual root cause this
/// traced to.
///
/// fit-to-width (実機フィードバック — 楽天銀行のような幅600-800px級の固定幅
/// テーブルHTMLメールが等倍描画され、右端がクリップ・文字が巨大に見える):
/// 上の`table { width: auto !important; }`等の CSS リセットだけでは、
/// `white-space: nowrap`が指定されたセル (幅寄せのための隣接ラベル/値など、
/// 固定幅前提のテンプレートで頻出) の**描画内容**がボックス自体の幅制約を
/// 無視してはみ出す実際のケースをカバーしきれない — ボックスの幅は
/// `max-width: 100%!important`で正しく制約されていても、そのボックスから
/// 中身が視覚的にはみ出すのは別の話 (はみ出た分は`overflow-x: hidden`で
/// クリップされるだけで、縮小はされない)。Spark 等の参考実装と同じ
/// "fit-to-width" — 実際に必要な幅 (`scrollWidth`) を計測し、ビューポート幅
/// を超えていれば `transform: scale()` でページ全体を視覚的に縮小する —
/// で解決する。`wrap(bodyHTML:)`が本文を`#otegami-fit-outer`/
/// `#otegami-fit-inner`の入れ子`div`で包むのはこのための足場: `outer`は
/// `overflow: hidden`を持つ固定サイズのコンテナ (縮小後の見た目の寸法に
/// JS側で明示的に合わせる — `transform`はペイント時の視覚効果でしかなく
/// レイアウト上のボックスサイズを変えないため、`outer`側で明示しないと
/// 縮小後も元の大きな高さ分だけ下に空白が残ってしまう)、`inner`が実際に
/// `scale()`される対象。JS 本体は `HTMLWebViewCoordinator
/// .fitToWidthScript`/`applyFitToWidth(to:)` — `didFinish`(ページ読み込み
/// 完了)後に評価される。ページ自身のスクリプトは`allowsContentJavaScript
/// = false`で無効化済みだが、ホスト側 (Swift) からの`evaluateJavaScript`
/// 呼び出しはこの設定と独立に動作する (WebKit の一般的な仕様: `allowsContentJavaScript`
/// が制限するのはページ自身が埋め込むスクリプト/イベントハンドラ/
/// `javascript:` URLであり、アプリ自身が能動的に呼ぶ`evaluateJavaScript`
/// はこの制限を受けない) — 同じ仕組みを1i の HTML レイアウト保持翻訳
/// (`HTMLTranslationController`) も流用する。
///
/// HTML 表示の高さ問題 (B の直後の実機フィードバック): B のこの `extractBodyContent`
/// が、実在するマーケティング/通知テンプレートが `<head>` にごく普通に含む
/// **MSO (Outlook) 条件付きコメント** (`<!--[if mso]> ... <![endif]-->`、
/// 別レンダリングエンジン向けのフォールバックを丸ごと埋め込むのが一般的な
/// パターン) の中にたまたま `<body`/`</body>` という文字列が含まれていた場合
/// (例: コメント内のフォールバック骨格 `<html><body>...</body></html>` や、
/// デバッグ用に埋め込まれた完全なコピー)、それを本物のタグと誤認して本文の
/// 大半を切り捨てていた — `stripHTMLComments(from:)` で HTML コメントを丸ごと
/// 除去してからタグ探索する形に修正済み (コメントはブラウザ上も非表示なので
/// 除去しても見た目に影響しない)。閉じタグ側も `.backwards` で「文書中最後の
/// `</body>`」を探すよう変更 — 開始タグ検出は最初の `<body` のままで正しい
/// (コメント除去済みなので、もう `<head>` 内の紛れ込みを拾わない)。
/// 実機スクリーンショット (WebView の表示エリアが画面の半分程度で頭打ちに
/// なり、本文が途中で切れ、その下に大きな空白が残る) から発見。
/// `extractHeadStyles(from:)` も参照 — 同じ B の変更が本文抽出と一緒に元
/// `<head>` の `<style>` ブロックも丸ごと捨てていた副作用の修正。
enum HTMLDocumentBuilder {
    /// Task #45「ダークモードで文字が読めない」→ Task #51 で条件を絞り
    /// 込んだ経緯:
    ///
    /// Task #45 の初版は、メール自身が`mailDeclaresOwnDarkModeSupport
    /// (bodyHTML:)`で判定する自前のダークモード対応を持たない限り
    /// **常に**`#otegami-fit-inner`へ`filter: invert(1) hue-rotate
    /// (180deg)`(古典的な「反転」手法、NetNewsWire 等と同方式) を適用して
    /// いた。だがこれは「色指定を一切持たないメール」を壊す実機退行を
    /// 生んだ: そのようなメールは元々このファイル自身の CSS リセット
    /// (`:root { color-scheme: light dark; }` + `color: CanvasText`) の
    /// おかげで、ダークモード中は WebKit が自動的に明るい文字色を解決
    /// して正しく読めていた — そこへ無条件の反転がかかると、その明るい
    /// `CanvasText`が暗い文字色へ逆変換されてしまい、透明な (＝アプリの
    /// ダーク背景がそのまま透ける) 背景の上でほぼ読めなくなる。反転が
    /// 本当に必要なのは「メールが明示的にライト配色 (明るい背景) を
    /// 描画するよう指定している」場合だけで、「メールが何も指定して
    /// いない」場合は逆効果というのが実機の教訓。
    ///
    /// **Task #51 での修正**: 静的なタグ検査 (`mailDeclaresOwnDarkModeSupport`
    /// だけ) で invert するかどうかを決めるのをやめ、ページ読み込み後に
    /// JS で**実測**する方式に変えた。`wrap(bodyHTML:autoAdjustColorsInDarkMode:)`
    /// が行うのは「反転を検討してよいか」(`autoAdjustColorsInDarkMode`が
    /// true、かつメールが自前のダーク対応を持たない) を判定し、条件を
    /// 満たす場合だけ CSS のクラス (`.otegami-invert-for-dark`、下記) と、
    /// JS 側が実測結果を書き込む対象を示す `data-otegami-invert-check`
    /// 属性を仕込むところまで。**実際に invert するかどうかの最終判断は
    /// `HTMLWebViewCoordinator.fitToWidthScript`が画像読み込み完了後に
    /// 行う** — `body`/`#otegami-fit-inner`/本文中で最大面積を占める
    /// 背景要素の`getComputedStyle(...).backgroundColor`と、代表的な
    /// テキストノード数点の`color`を実際に読み取り、実効背景の輝度
    /// (WCAG 相対輝度、0.5 を閾値) が高い場合に限って`.otegami-invert-
    /// for-dark`クラスを`#otegami-fit-inner`へ付与する。背景が最後まで
    /// 透明で確定しない (＝色指定を一切持たないメール) 場合は**何も
    /// しない**(安全側のデフォルト) — これが今回の退行ケースを直す。
    /// 詳細な計測ロジックは `fitToWidthScript`のdoc comment参照。
    ///
    /// `img`/`picture`/`video`と、インライン`style`に`background-image`を
    /// 持つ要素には同じフィルタをもう一度適用して打ち消す (二重反転で
    /// 元の色に戻る) — 写真・ロゴが色反転して不自然にならないようにする
    /// ため。ブランドカラー (テキスト色・アクセント色) は反転後も概ね保た
    /// れる (色相環上で180度回転するため、青系統は青系統のまま程度の変化
    /// に留まることが多い)。
    ///
    /// メール自身が既にダークモード対応済みの場合は何もしない (二重に
    /// 反転させると壊れるため) — Spark/Gmail と同じ「メールが対応済みなら
    /// 尊重する」方針。実測はこの判定より**後**には効かない — 自前対応が
    /// あると分かった時点で`shouldConsiderDarkModeHandling`自体が false に
    /// なり、JS側の実測は一切走らない。
    ///
    /// **Task #80 でのさらなる変更 (実機動画 f012→f015 — MakerWorld 等の
    /// ライトデザインメールで「初期描画は正しいライト → 読み込み後に反転
    /// が後がけされて暗転する」チラつき + 反転アーティファクトの報告)**:
    /// 上の実測ロジック自体 (実効背景色/文字色の測定、Task #56 の「背景
    /// なし+暗文字」拡張分岐含む) はそのまま — 変わったのは**実測が
    /// 「介入が要る」と判定したときにどちらの対処をするか**。
    /// `autoAdjustColorsInDarkMode`の既定が ON→OFF に変わったのに伴い、
    /// 既定 (OFF) では**反転せずメール本来のライト配色のまま見せる**
    /// (`.otegami-keep-light-active`、下記) — 反転は明示的に ON にした
    /// ユーザー向けのオプトインになった。判定自体 (`shouldConsiderDark
    /// ModeHandling`) はこの設定値と無関係に常に行う (`autoAdjustColorsIn
    /// DarkMode`はもう判定条件に含めない) — 実際にどちらの対処になるかは
    /// `data-otegami-prefer-invert`属性経由でJSに伝わる。色指定を一切
    /// 持たないメールが「介入不要」判定に落ち着く (＝ダークネイティブの
    /// まま) のは従来どおり変わらない。
    ///
    /// **Task #98**: 「背景なし+暗文字」拡張分岐 (Task #56、上記) 自体の
    /// 実測ロジックをさらに一段拡張 — `HTMLWebViewCoordinator
    /// .explicitDarkTextIsMajority`のdoc comment参照。この関数 (`wrap`) 自体
    /// に変更はない (Swift側は相変わらず「介入を検討してよいか」までしか
    /// 決めない)。
    ///
    /// **Task #104**: このファイル自身が注入する3つの`<style>`タグに
    /// `data-otegami-base-style="1"`を付けるようになった (下記) — JS側の
    /// `collectExplicitColorSelectors`がメール自身の`<style>`ブロックだけを
    /// 走査し、このファイル自身のCSSルールを「著者の明示指定」と誤認しない
    /// ようにするための目印。判定ロジック自体 (「介入を検討してよいか」まで
    /// しか決めない、実際の判定はJS側) という役割分担は変わらない。
    static func wrap(bodyHTML: String, autoAdjustColorsInDarkMode: Bool, forceLightBackground: Bool = false, bottomContentInset: CGFloat = 0) -> String {
        let innerBody = extractBodyContent(from: bodyHTML)
        let originalHeadStyles = extractHeadStyles(from: bodyHTML)
        // Task #51: この時点ではまだ「介入 (反転 or ライト維持) を検討して
        // よいか」までしか決めない — 実際にどちらの対処を行うか (あるいは
        // 何もしないか) は実測 (`fitToWidthScript`の`decideDarkInversion`)
        // 任せ。変数名を旧来の`shouldInvertForDarkMode`から変えたのはこの
        // 意味の変化を明示するため。
        //
        // Task #80: `autoAdjustColorsInDarkMode`はもうここでの分岐条件に
        // 含めない — 「介入してよいか」自体は常に判定する (対処が要ると
        // 分かったときにどちらの対処 (ライト維持 or 反転) を選ぶかだけを
        // 左右する、下の`fitOuterAttributes`の`data-otegami-prefer-invert`
        // 経由でJSに伝える値になった)。これにより新既定
        // (`autoAdjustColorsInDarkMode == false`) でも「実効的にライト
        // デザインのメールをライトのまま見せる」判定自体は動く。
        //
        // Task #71 (「メールの背景を常に白に」): `forceLightBackground`が
        // 真なら、この判定自体を検討する余地を最初から無くす — 下の
        // `forceLightBackgroundStyle`がこの文書自体を無条件でライト固定
        // にするので、判定対象がそもそも存在しない (Gmailの「ライト表示」
        // 相当、色指定のないメールも含め常にライト)。
        let shouldConsiderDarkModeHandling = !forceLightBackground && !mailDeclaresOwnDarkModeSupport(html: bodyHTML)
        // Task #71: `:root`の`color-scheme: light dark;`(下の基本`<style>`)
        // と、メール自身の`<style>`(`originalHeadStyles`、この文書の`<head>`
        // 内でこの後に続く) が持ちうる`color-scheme`宣言の両方に確実に勝つ
        // よう`!important`。`html, body`の背景も同様に白へ固定 — メール
        // 自身の`<style>body{background:...}`が非`!important`のライト背景
        // を指定していればそのまま活きる (この状況では無害) が、万一暗い
        // 背景を指定していた場合や、何も指定していない場合 (このファイル
        // 自身の`background: transparent`のままだとアプリのダーク背景が
        // 透けてしまう) にも確実にライト表示になるようにするための保険。
        let forceLightBackgroundStyle = forceLightBackground ? """
        <style data-otegami-base-style="1">
          :root { color-scheme: light !important; }
          html, body { background-color: #ffffff !important; }
        </style>
        """ : ""
        let darkModeInvertStyle = shouldConsiderDarkModeHandling ? """
        <style data-otegami-base-style="1">
          @media (prefers-color-scheme: dark) {
            /* Task #45/#51: ライト前提で書かれたメールをダークモードでも
               読めるようにする「反転」手法 — Task #80 でこの手法を選ぶのは
               「ダークモードで配色を自動調整」トグルを明示的に ON にした
               ユーザーだけになった (新既定は下の `otegami-keep-light-for-dark`
               を使う)。実際にこのクラスが付くかどうかは JS の実測
               (`fitToWidthScript`) 任せ — ここではクラスが付いたときの
               見た目だけを用意する。#otegami-fit-inner は fit-to-width の
               scale(transform) も受けうる同じ要素だが、filter と
               transform は独立したペイント/コンポジット効果同士で、
               レイアウト計算 (scrollWidth/scrollHeight) には互いに影響
               しない。 */
            #otegami-fit-inner.otegami-invert-for-dark {
              filter: invert(1) hue-rotate(180deg);
            }
            /* 画像・動画・背景画像は反転を打ち消してもう一度反転 (＝
               元の色に戻す) — 写真やロゴの色が不自然に変わらないように
               する。`[style*="background-image"]` は CSS ではクラス経由の
               background-image までは拾えないが、「やり過ぎない範囲で」
               という方針どおり、インライン style で背景画像を指定する
               頻出パターンだけを対象にした現実的な範囲。 */
            #otegami-fit-inner.otegami-invert-for-dark img,
            #otegami-fit-inner.otegami-invert-for-dark picture,
            #otegami-fit-inner.otegami-invert-for-dark video,
            #otegami-fit-inner.otegami-invert-for-dark [style*="background-image"] {
              filter: invert(1) hue-rotate(180deg);
            }
            /* 実機フィードバック (MakerWorld 比較 — 右端に縦の白帯・セクション
               間の色ムラ): `.otegami-invert-for-dark`のフィルタは
               `#otegami-fit-inner`とその子孫にしかかからないため、メール
               自身の `<style>body{background:#fff}`のようなルール
               (`extractHeadStyles`がこのファイル自身の `background:
               transparent` の後に差し込むので、非`!important`同士なら
               後勝ちでそちらが実際に採用される) はそのまま`body`の実ペイント
               色として残ってしまい、`body`のpadding分の余白 (左右12px) や、
               要素どうしの隙間で本来のライト背景色がそのまま透けて見えて
               いた — 「反転された本文の中に反転されていない帯が残る」の
               正体。`html.otegami-invert-active`はJS側 (`decideDarkInversion`)
               が実際に反転を決めたときだけ付与するクラスで、その間だけ
               `body`/`html`自身の背景を強制的に透明化する — 反転しない
               メール (ダークモード対応済み・元から暗背景等) の見た目は
               一切変えない。`body`本来の背景色は同じJSが`#otegami-fit-inner`
               自身へ移し替える (下記コメント) ので、キャンバス色そのものは
               失われず、フィルタの対象内に収まる。 */
            html.otegami-invert-active,
            html.otegami-invert-active body {
              background-color: transparent !important;
            }
            /* 実機フィードバック (MakerWorld ロゴが暗背景に沈む): 透過PNGの
               ロゴ (黒い線画、背景なし) は上の img 二重反転ルールで「元の
               色 (黒)」に戻る一方、ページ側は反転済みで暗背景になるため、
               黒の線画が暗い背景にほぼ同化して見えなくなる — Gmail のダーク
               表示が小さい透過ロゴにやっているのと同じ対処 (白系の背景
               チップを敷いて元の配色のまま読めるようにする) を採る。
               どの画像が「透過ロゴ」かをCSS/DOMだけから確実に判定するのは
               難しいため、`decideDarkInversion`が実測した画像の内在サイズ
               (`naturalWidth`/`naturalHeight`) が両方 200px 以下という
               実用的なヒューリスティクスで対象を絞る (写真本体は大抵もっと
               大きいので誤爆しにくい、という判断 — 詳細は`docs/design-system.md`
               参照)。対象の画像だけに `otegami-invert-logo-chip` クラスが
               付く。 */
            #otegami-fit-inner.otegami-invert-for-dark img.otegami-invert-logo-chip {
              background-color: rgba(255, 255, 255, 0.94);
              border-radius: 6px;
              padding: 4px;
            }
            /* Task #80 (新既定 — チラつき+反転アーティファクトの実機
               フィードバックを受けた変更): 「ダークモードで配色を自動
               調整」が OFF (既定) のとき、`decideDarkInversion`が「介入が
               要る」と判定したメール (実効的にライトデザイン — 明背景を
               実測、または背景なし+暗い文字色を実測、Task #56 の
               「背景が解決しない」拡張分岐と同じ判定) には、反転ではなく
               こちらを使う — メール本来の配色のまま (白カード) 見せる。
               反転と違い画像・ロゴの色には一切手を加えない (元々ライトな
               ページにライトな画像がそのまま乗っているだけなので、色を
               打ち消す必要がない — `decideLogoChips`もこの経路では呼ば
               ない)。`html`自身に`color-scheme: light`を強制するのは、
               このサブツリー内で著者が明示指定していない部分が誤って
               `CanvasText`等のダーク側システム色に解決されるのを防ぐ
               ため。`html`/`body`の背景を白へ強制するのは
               `forceLightBackgroundStyle`と同じ保険 — メール自身が
               `body`へ明示的な背景を指定していればそれがそのまま活きる
               (非`!important`同士でこのルールより前に来るので無害) が、
               指定が要素の隙間などで途切れている場合や、介入判定が
               「背景なし+暗文字」経由だった場合 (背景色はそもそも透明の
               まま) にも確実にライト表示になるようにする。 */
            html.otegami-keep-light-active,
            html.otegami-keep-light-active body {
              color-scheme: light !important;
              background-color: #ffffff !important;
            }
          }
        </style>
        """ : ""
        // Task #51: `#otegami-fit-outer`にこの属性を付けておくと、
        // `fitToWidthScript`側は Swift の状態を別途受け渡されなくても
        // 「このドキュメントは介入 (反転 or ライト維持) を検討してよいか」
        // をDOMから直接読める — `didFinish`直後・1.5秒後の遅延呼び出し・
        // 1i翻訳後の再適用のどの呼び出し経路でも同じ1本のスクリプトが
        // 自己完結して動く。
        //
        // Task #80: `data-otegami-prefer-invert`は「介入が要ると分かった
        // ときに反転 (旧既定・オプトイン) を選ぶか、ライト維持 (新既定)
        // を選ぶか」をJSに伝える — `autoAdjustColorsInDarkMode`が true の
        // ときだけ付与する。この属性が無い (== false) 場合の既定は
        // ライト維持。
        let fitOuterAttributes = shouldConsiderDarkModeHandling
            ? " data-otegami-invert-check=\"1\"" + (autoAdjustColorsInDarkMode ? " data-otegami-prefer-invert=\"1\"" : "")
            : ""
        // Task #56 (実機フィードバック: 要約/翻訳フローティングボタンが
        // HTML本文に被る): プレーンテキスト側の `.contentMargins(.bottom:)`
        // と同じ効果を、この文書自身の末尾に高さ分の空 `<div>` を1つ足す
        // ことで実現する — `#otegami-fit-outer`の*兄弟*として`body`直下に
        // 置く (中に入れない) のがポイント: fit-to-width
        // (`HTMLWebViewCoordinator.fitToWidthScript`) は`#otegami-fit-inner`
        // の`scrollWidth`/`scrollHeight`だけを測って`outer`のtransform/
        // サイズを決めるので、この spacer をその外に置けば scale 計算には
        // 一切影響しない (スケールされたメール本文の下に、常にスケール
        // されていない一定の高さの余白が残る)。`bottomContentInset <= 0`
        // (フローティングボタンが1つも出ない設定の場合など) なら何も足さず
        // 従来どおり — `MessageView.floatingButtonsReservedBottomInset`が
        // 既に同じ「出ないときは0」ガードを持っている。
        let bottomInsetSpacer = bottomContentInset > 0
            ? "<div id=\"otegami-bottom-inset-spacer\" style=\"height: \(Int(bottomContentInset.rounded(.up)))px; flex-shrink: 0;\"></div>"
            : ""
        // Task #104 (実機フィードバック: Readdle Documents のニュースレター等、
        // `<style>` ブロックの CSS クラスで文字色を指定するメールがダーク
        // ネイティブのまま読めなかった — Task #98 の `explicitDarkTextIsMajority`
        // はインライン `style` の `color` しか見ておらず、クラス経由の
        // 明示指定を見落としていた): 3つの `<style>` タグ (この基本リセット、
        // 下の `darkModeInvertStyle`、`forceLightBackgroundStyle`) すべてに
        // `data-otegami-base-style="1"` を付け、`fitToWidthScript`側の
        // `collectExplicitColorSelectors` がこの属性を持つ `<style>` を
        // 「アプリ自身の注入スタイル」として除外できるようにする —
        // `originalHeadStyles` (メール自身が持っていた `<style>` ブロック、
        // すぐ下で差し込む) だけがマークされずに残るので、そちらだけが
        // 「メール著者が明示指定した色」の走査対象になる。この属性が無いと
        // このファイル自身の `a { color: LinkText; }` のようなルールまで
        // 「著者の明示指定」に誤カウントしてしまう。
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=yes">
        <meta charset="utf-8">
        <style data-otegami-base-style="1">
          :root { color-scheme: light dark; }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
            color: CanvasText;
            font: -apple-system-body;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
            overflow-wrap: break-word;
            overflow-x: hidden;
          }
          body { padding: 8px 12px; }
          /* Task #56: `img` はこの `*` の対象から除外し、専用ルール群
             (下、`img { box-sizing: border-box; ... }` 以降) で個別に扱う
             — 理由はそちらのコメント参照 (この `!important` が著者の
             インライン `max-width` を問答無用で踏み潰していた実機バグの
             修正)。 */
          *:not(img) { max-width: 100% !important; box-sizing: border-box; }
          video, table, iframe { max-width: 100% !important; height: auto !important; }
          /* Task #56「画像の巨大化禁止」(実機フィードバック: TestFlight
             通知メールのアプリアイコン ~120px 画像が画面幅いっぱいに
             引き伸ばされていた): 原因は責任分解の失敗 — メール側は
             「画面に合わせて縮むが上限は120px」という業界標準のレスポン
             シブ画像手法 (`width` 属性 + `style="width:100%;
             max-width:120px;"` の併用、Litmus/Email on Acid 等が推奨する
             定石) を使っていたのに、この `<style>` の `img` 向けリセットが
             `max-width: 100% !important` を無条件にかけていたため、著者の
             `max-width: 120px` (`!important` 無し) を、`!important` 同士
             なら詳細度を問わず勝つという CSS のカスケード規則により問答
             無用で上書きしていた — 結果「上限なし」＝コンテナ幅いっぱい
             まで拡大 (実機ログ・再現手順は `docs/design-system.md` の
             Task #56 節参照。ローカルの WKWebView 計測スクリプトで複数の
             実装候補を比較のうえ選定した)。
             著者が独自の `max-width` をインライン `style` に持たない画像
             だけへ `!important` の100%上限をかけ
             (`img:not([style*="max-width" i])`)、独自の `max-width` を
             持つ画像には非`!important`のフォールバック上限だけを与える
             (`img[style*="max-width" i]`) — これなら CSS の詳細度
             (インライン `style` が最優先) により著者側のより小さい値が
             自然に勝つ。著者が `max-width` を極端に大きく指定していた
             場合でも、ページ全体の fit-to-width
             (`HTMLWebViewCoordinator.fitToWidthScript`) がページ全体を
             縮小する安全網としてなお機能する (下の固定幅テーブル対策と
             同じ考え方)。 */
          img { box-sizing: border-box; height: auto !important; }
          img:not([style*="max-width" i]) { max-width: 100% !important; }
          img[style*="max-width" i] { max-width: 100%; }
          /* 拡大禁止の残り半分: `width` 属性もインライン `style` の
             `width` も持たない画像は常に自然サイズ (`width: auto`) で
             描画する — これが無いと、著者の `<style>` ブロック側で
             `img { width: 100% !important; }` のような汎用リセットが
             仕込まれていた場合 (これもテンプレートで頻出) にそれがその
             まま採用され、結局自然サイズより拡大されてしまう。`width`
             属性/インライン `style` で明示指定がある画像はこの対象から
             除外し、その指定をそのまま尊重する — 拡大方向にだけ効く
             他のルールと違い、こちらは `!important` を使っても
             フィットスケール以外に副作用がない (対象を明示指定なしの
             画像だけに絞っているため)。 */
          img:not([width]):not([style*="width" i]) { width: auto !important; }
          /* 幅固定のマーケティングHTML (width="600"のテーブル等) 対策:
             max-width: 100% だけだと table-layout: auto のセル内容が要求
             する幅次第でテーブル自体がなおコンテナ幅を超えうる。width: auto
             でテーブル自身の希望幅を「内容に合わせる」側に倒し、頻出する
             spacerセルの min-width 属性も無効化する — table-layout: fixed
             (テーブル全体を強制的に均等割りする、もっと強い手段) は列比率が
             崩れて見た目が壊れるケースがあるため見送った (「やり過ぎない
             範囲で」という指示どおりの選択)。 */
          table { width: auto !important; }
          td, th { min-width: 0 !important; }
          a { color: LinkText; }
          pre, code { white-space: pre-wrap; }
          /* fit-to-width の足場 (`HTMLWebViewCoordinator.fitToWidthScript`
             が JS から実際に幅・transform を設定する) — #otegami-fit-outer
             に `overflow: hidden` が要るのは、`transform: scale()` が
             `#otegami-fit-inner`の*レイアウト上の*ボックスサイズ (＝縮小前の
             元の大きな幅・高さ) を変えないため。JS 側が `outer` の
             width/height を縮小後の見た目の寸法に明示的に合わせても、
             `overflow: hidden` が無いと `inner` の (縮小前のままの)
             レイアウト上のボックスが `outer` をはみ出して結局スクロール
             領域が縮小前の大きいままになってしまう。 */
          #otegami-fit-outer { overflow: hidden; }
        </style>
        \(originalHeadStyles)
        \(darkModeInvertStyle)
        \(forceLightBackgroundStyle)
        </head>
        <body><div id="otegami-fit-outer"\(fitOuterAttributes)><div id="otegami-fit-inner">\(innerBody)</div></div>\(bottomInsetSpacer)</body>
        </html>
        """
    }

    /// Task #45: whether `html` (the *original*, unwrapped message HTML —
    /// checked before `extractBodyContent`/`extractHeadStyles` run, so this
    /// sees the original `<head>` regardless of whether it survives
    /// extraction) already declares its own dark-mode support, in which case
    /// `wrap(bodyHTML:autoAdjustColorsInDarkMode:)` leaves it untouched
    /// rather than risking a double-inversion. Two real-world signals,
    /// either one sufficient:
    /// - `<meta name="color-scheme" content="...">` (the HTML-level opt-in
    ///   most mail-authoring tools emit alongside a dark-mode stylesheet).
    /// - A `prefers-color-scheme` media query anywhere in the message's own
    ///   markup (almost always inside a `<style>` block — the actual dark-
    ///   mode color overrides live behind it).
    /// Plain case-insensitive substring search, not a real CSS/HTML parser —
    /// consistent with this file's existing pragmatic approach elsewhere
    /// (`stripHTMLComments(from:)`'s doc comment makes the same tradeoff).
    /// A false positive (text that happens to contain one of these strings
    /// without it actually governing color) just means this app trusts the
    /// message's own dark-mode handling instead of applying its own — the
    /// safe direction to be wrong in, same as leaving a message's colors
    /// alone entirely would be.
    private static func mailDeclaresOwnDarkModeSupport(html: String) -> Bool {
        let lowercased = html.lowercased()
        return lowercased.contains("prefers-color-scheme") || lowercased.contains("name=\"color-scheme\"") || lowercased.contains("name='color-scheme'")
    }

    /// MailCore2's `MCOMessageParser.htmlBodyRendering()` hands back
    /// whatever the message's own `text/html` MIME part actually contained
    /// — for a great many real senders (marketing/notification templates
    /// especially) that's a **complete** `<html><head>...</head><body>...
    /// </body></html>` document, not a bare fragment, and that original
    /// `<head>` commonly carries its own `<meta name="viewport">` and/or a
    /// `<style>` block written for a desktop-width preview pane. The
    /// pre-fix version of this function did `<body>\(bodyHTML)</body>` —
    /// nesting that entire second document *inside* this file's own
    /// `<body>` tag. Per the HTML5 parsing algorithm a `<head>` start tag
    /// encountered while already "in body" insertion mode is dropped, and a
    /// bare `<meta>`/`<style>` that follows gets inserted as ordinary body
    /// content instead of governing the page the way it would from a real
    /// `<head>` — in practice, real WebKit builds have been observed
    /// treating the *second*, malformed `<meta viewport>` as authoritative
    /// anyway once it's present anywhere in the document, silently
    /// overriding this file's own correctly-placed one and putting the
    /// whole page back into desktop-width layout. Extracting just the
    /// original document's own `<body>...</body>` content (falling back to
    /// the input unchanged when there's no `<body>` tag to find — the
    /// already-a-fragment case, still the common one for plainer mail)
    /// guarantees this file's `<head>` is the *only* one WebKit ever
    /// parses, so its viewport meta and CSS reset can't be shadowed by
    /// whatever the original message happened to ship.
    private static func extractBodyContent(from html: String) -> String {
        // HTML 表示の高さ問題の修正: comment-stripped first (see
        // `stripHTMLComments(from:)`'s doc comment) — a real marketing
        // template's `<head>` commonly contains an MSO/Outlook conditional
        // comment holding a whole fallback skeleton, which can itself
        // contain the literal text `<body`/`</body>`. Scanning the raw
        // (comment-including) string let that spurious occurrence win,
        // truncating almost the entire real message body.
        let sanitized = stripHTMLComments(from: html)
        guard let bodyTagRange = sanitized.range(of: "<body", options: [.caseInsensitive]),
              let bodyTagCloseIndex = sanitized[bodyTagRange.lowerBound...].firstIndex(of: ">")
        else {
            return html
        }
        let contentStart = sanitized.index(after: bodyTagCloseIndex)
        // `.backwards`: the *real* closing tag is always the last one in a
        // well-formed document (it closes the one `<body>` element whose
        // opening tag was just located above) — searching backwards is a
        // second, independent safety net against any stray `</body>`-like
        // text elsewhere in `<head>` that comment-stripping alone didn't
        // happen to catch (e.g. inside a `<script>`/`<style>` string
        // literal rather than an HTML comment).
        let contentEnd = sanitized.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? sanitized.endIndex
        guard contentStart <= contentEnd else { return html }
        return String(sanitized[contentStart..<contentEnd])
    }

    /// HTML 表示の高さ問題の修正: B (`extractBodyContent(from:)`) が
    /// 元ドキュメントの `<body>...</body>` だけを取り出す一方で、その
    /// `<head>` に書かれていた `<style>` ブロック (クラス経由でしか本文の
    /// 見た目を制御していないマーケティングテンプレートは珍しくない) を
    /// 完全に捨ててしまっていた副作用の修正。抽出したスタイルは `wrap
    /// (bodyHTML:)` でこのファイル自身の `<style>` (viewport/幅の
    /// `!important` リセット) の**後**に差し込む — CSS の cascade では
    /// `!important` は宣言順を問わず勝つので、元テンプレートの `width:
    /// 600px` のような非 `!important` 宣言に上書きされる心配はなく、色や
    /// 余白のような非競合スタイルだけが素直に復元される。
    /// `stripHTMLComments(from:)` を先に通すのは `extractBodyContent(from:)`
    /// と同じ理由 (MSO 条件付きコメント内の `<style>` は Outlook 専用の
    /// フォールバックであって、WebKit でそのまま適用すべきものではない) —
    /// コメントごと除去することで自然に除外される。
    private static func extractHeadStyles(from html: String) -> String {
        let sanitized = stripHTMLComments(from: html)
        guard let headOpenRange = sanitized.range(of: "<head", options: [.caseInsensitive]),
              let headCloseRange = sanitized.range(of: "</head>", options: [.caseInsensitive]),
              headOpenRange.lowerBound < headCloseRange.lowerBound
        else {
            return ""
        }
        let headSection = sanitized[headOpenRange.lowerBound..<headCloseRange.upperBound]
        var result = ""
        var searchStart = headSection.startIndex
        while let openRange = headSection.range(of: "<style", options: [.caseInsensitive], range: searchStart..<headSection.endIndex),
              let openTagCloseIndex = headSection[openRange.lowerBound...].firstIndex(of: ">") {
            let styleContentStart = headSection.index(after: openTagCloseIndex)
            guard let closeRange = headSection.range(of: "</style>", options: [.caseInsensitive], range: styleContentStart..<headSection.endIndex) else {
                break
            }
            result += String(headSection[openRange.lowerBound..<closeRange.upperBound])
            result += "\n"
            searchStart = closeRange.upperBound
        }
        return result
    }

    /// Removes every `<!-- ... -->` HTML comment from `html` — comments
    /// never render (browsers treat them as inert), so stripping them
    /// before `extractBodyContent(from:)`/`extractHeadStyles(from:)` scan
    /// for tags never changes anything visible; it only stops literal
    /// tag-like text *inside* a comment (an MSO/Outlook conditional
    /// fallback skeleton is the common real-world case — see
    /// `extractBodyContent(from:)`'s doc comment) from being mistaken for
    /// a real tag. `.dotMatchesLineSeparators` so a multi-line comment
    /// (the norm for these conditional blocks) is matched as one unit
    /// rather than stopping at the first newline. Falls back to the input
    /// unchanged if the regex itself somehow fails to compile (a fixed,
    /// valid pattern — should never happen, but this is display code, not
    /// somewhere worth crashing over).
    private static func stripHTMLComments(from html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }
}

/// 実機フィードバック第3弾 (C): one `WKProcessPool` shared by every
/// `HTMLMessageView` this app ever creates. `WKWebViewConfiguration
/// .processPool` defaults to a **brand-new** `WKProcessPool` per
/// configuration unless one is explicitly assigned — before this existed,
/// every single message opened (HTML or not, since `makeWebViewConfiguration`
/// runs regardless) spun up its own throwaway WebKit content process from
/// scratch, which is the primary suspect for the real-device report
/// "起動し直すと読み込みが入る。表示まで時間がかかる" (`docs/verify.md`'s C note
/// has the actual measured timings). Sharing one pool lets WebKit reuse an
/// already-running content process for the second and later message opens
/// in the same launch; `HTMLWebViewPrewarmer` (below) additionally warms
/// that first process up *before* the user's first tap, so a fresh launch
/// benefits too, not just repeat opens within one session.
@MainActor
enum HTMLWebViewProcessPool {
    static let shared = WKProcessPool()
}

/// 実機フィードバック第3弾 (C): kicked off once, in the background, from
/// `AppEnvironment.init()` — creates one throwaway, never-displayed
/// `WKWebView` sharing `HTMLWebViewProcessPool.shared` and loads a trivial
/// blank document into it, then keeps it alive for the rest of the process
/// (a `static var`, never deallocated) purely to keep that pool's content
/// process warm. `HTMLWebViewProcessPool` alone only helps the *second*
/// message a session opens — there's no already-running process yet for
/// the very first one on a cold launch, exactly the case the real-device
/// report called out ("起動し直すと"). Deliberately dispatched from a
/// `Task` (see the call site), not run synchronously inside `init()` —
/// spinning up a `WKWebView` has its own non-trivial cost, and blocking
/// `AppEnvironment.init()` (which runs synchronously before `RootView`'s
/// first render) on it would trade "message screen feels slow" for "app
/// launch feels slow", not actually fix anything.
@MainActor
enum HTMLWebViewPrewarmer {
    private static var warmWebView: WKWebView?

    static func prewarm() {
        guard warmWebView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.processPool = HTMLWebViewProcessPool.shared
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        warmWebView = webView
    }
}

/// A `WKWebViewConfiguration` with page-authored JavaScript disabled
/// (plan: "JS 無効") and, when `cidHandler` is provided, the
/// `otegami-cid://` scheme registered for inline `cid:` image resolution
/// (M8). Set once at configuration time — rather than per navigation via
/// the delegate's `decidePolicyFor:preferences:` — since every load this
/// view ever does should be equally restricted; there's no case where a
/// message body should be allowed to run script.
@MainActor
private func makeWebViewConfiguration(cidHandler: CIDSchemeHandler?) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    // 実機フィードバック第3弾 (C) — see `HTMLWebViewProcessPool`'s doc comment.
    configuration.processPool = HTMLWebViewProcessPool.shared
    // Explicit even though it's already the default — makes clear this
    // view deliberately relies on WebKit's own persistent on-disk cache
    // (images, HTTP cache) surviving across app relaunches, rather than an
    // ephemeral (`.nonPersistent()`) store that would silently defeat the
    // "2回目以降はローカルから" requirement.
    configuration.websiteDataStore = .default()
    let preferences = WKWebpagePreferences()
    preferences.allowsContentJavaScript = false
    configuration.defaultWebpagePreferences = preferences
    if let cidHandler {
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: CIDURLRewriter.scheme)
    }
    return configuration
}

/// `HTMLMessageView`'s `.task(id:)` re-application key — see its call site's
/// doc comment. A plain `Equatable` struct (not `Hashable`; `.task(id:)`
/// only requires `Equatable`) so SwiftUI can tell "the translation display
/// state genuinely changed" apart from "this view just re-rendered for an
/// unrelated reason" without restarting the task on every body evaluation.
private struct HTMLTranslationDisplayKey: Equatable {
    let showOriginal: Bool
    let translatedTexts: [String]?
}

/// 1i「HTMLメールもレイアウトを保持したまま翻訳」(実機フィードバック
/// 「htmlメールの場合、レイアウトをなるべく崩さないように翻訳を表示して
/// 欲しい」): the handle `HTMLMessageView` vends to `MessageView` (via
/// `onTranslationControllerReady`) so translation — which needs
/// `AppEnvironment.messageTranslator`, firmly `MessageView`'s
/// responsibility, and has no business knowing about `WKWebView` — can
/// still collect and rewrite the live web view's DOM text nodes without
/// `MessageView` ever importing `WebKit` itself. `HTMLDocumentBuilder.wrap
/// (bodyHTML:)`'s "fit-to-width" doc comment already explains why a host-
/// initiated `evaluateJavaScript` call works fine even though page-authored
/// script is disabled (`allowsContentJavaScript = false`) — this reuses the
/// exact same mechanism for a different purpose.
///
/// Every extracted/rewritten text node is wrapped in a `<span data-otegami-
/// i="N">` the first time any of these methods sees it — `data-otegami-i`
/// gives each node a stable handle across the several separate JS round
/// trips this feature needs (collect → translate (async, off the web view
/// entirely — `MessageTranslator` is a plain Swift actor) → write back),
/// `data-otegami-original` preserves the pre-translation text so
/// `showOriginal()` can restore it without asking Swift for it again. Not
/// `@Observable`/`ObservableObject`: nothing reads its properties
/// reactively, it's a purely imperative handle whose methods are called at
/// specific moments (a button tap, `HTMLMessageView`'s `.task(id:)`).
///
/// Every method is a no-op when `webView` is still `nil` (the brief window
/// before `HTMLWebViewRepresentable.makeUIView`/`makeNSView` has run) —
/// `HTMLMessageView`'s `.task(id:)` re-runs on the next relevant state
/// change regardless, so a caller racing view construction just means "try
/// again shortly", not a crash.
@MainActor
final class HTMLTranslationController {
    fileprivate weak var webView: WKWebView?

    /// The DOM walk every method below shares, as a JS function source
    /// fragment: skips `<script>`/`<style>`/`<title>` and whitespace-only
    /// text, wraps each qualifying (or reuses each already-wrapped) text
    /// node in a stamped `<span>`, and calls `onText(span, index)` for each
    /// one in document order — `extractTranslatableTexts`/`applyTranslations`
    /// both embed this and just differ in what their `onText` callback does
    /// with it. Scoped to `#otegami-fit-inner` (`HTMLDocumentBuilder.wrap`'s
    /// fit-to-width wrapper) rather than the whole document — conveniently
    /// already exactly "this message's own rendered content and nothing
    /// else" (this app's fixed CSS reset in `<style>`/`<head>` isn't inside
    /// it, so there's no risk of ever touching that instead). Idempotent by
    /// construction: a node already stamped by an earlier pass (e.g. a
    /// retry after a failed translation, or `applyTranslations` re-running
    /// after `HTMLWebViewCoordinator.load(...)` reloaded the document from
    /// scratch — in which case there's nothing stamped yet, so this
    /// re-wraps from zero) is reused rather than re-wrapped or double-
    /// counted.
    private static let walkAndWrapFunctionSource = """
    function otegamiWalkAndWrap(onText) {
      function shouldSkip(tag) { return tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE'; }
      var index = 0;
      function walk(node) {
        if (node.nodeType === 1) {
          if (shouldSkip(node.tagName)) { return; }
          if (node.hasAttribute && node.hasAttribute('data-otegami-i')) {
            onText(node, Number(node.getAttribute('data-otegami-i')));
            return;
          }
          var children = Array.prototype.slice.call(node.childNodes);
          for (var i = 0; i < children.length; i++) { walk(children[i]); }
          return;
        }
        if (node.nodeType === 3) {
          var text = node.nodeValue;
          if (text && text.trim().length > 0) {
            var span = document.createElement('span');
            span.setAttribute('data-otegami-i', String(index));
            span.setAttribute('data-otegami-original', text);
            node.parentNode.insertBefore(span, node);
            span.appendChild(node);
            onText(span, index);
            index += 1;
          }
        }
      }
      walk(document.getElementById('otegami-fit-inner') || document.body);
    }
    """

    /// Task #61 (実機フィードバック「HTMLメールの翻訳ボタンが無反応」):
    /// `return texts;` (a bare JS array) ではなく `return JSON.stringify
    /// (texts);` (プレーンな文字列) を返す — このプロジェクトのツール
    /// チェーンでは `evaluateJavaScript` の戻り値ブリッジが Promise 解決値
    /// に対して壊れていることが Task #58 で確認済み (`fitToWidthScript`の
    /// doc comment参照) で、この抽出 IIFE 自体は Promise を経由しない同期
    /// 呼び出しなので理論上は影響を受けないはずだが、実機フィードバックが
    /// 「HTMLメールの翻訳だけ無反応」と報告している以上、複雑な値の
    /// ブリッジそのものに実機依存の余地がある可能性を排除できない —
    /// 同じファイルの`readDiagScript`/`fitToWidthScript`の`data-otegami-diag`
    /// 属性が採る「JSON文字列として運び、Swift側でデコードする」という
    /// 実証済みの安全な形に統一しておくことで、この抽出だけが疑わしい
    /// 特別扱いのまま残ることを避ける。
    private static let extractScript = """
    \(walkAndWrapFunctionSource)
    (function () {
      var texts = [];
      otegamiWalkAndWrap(function (span, i) { texts[i] = span.getAttribute('data-otegami-original'); });
      return JSON.stringify(texts);
    })();
    """

    private static let showOriginalScript = """
    (function () {
      var spans = document.querySelectorAll('[data-otegami-i]');
      for (var i = 0; i < spans.length; i++) {
        var original = spans[i].getAttribute('data-otegami-original');
        if (original !== null) { spans[i].textContent = original; }
      }
    })();
    """

    private static let showTranslatedScript = """
    (function () {
      var spans = document.querySelectorAll('[data-otegami-i]');
      for (var i = 0; i < spans.length; i++) {
        var translated = spans[i].getAttribute('data-otegami-translated');
        if (translated !== null) { spans[i].textContent = translated; }
      }
    })();
    """

    /// Task #61 diagnostic/failure logging — separate from `diagnosticLogger`
    /// (Task #58, HTML height) since this covers a different feature; kept
    /// permanent (not marked "temporary") since a JS-bridge failure here is
    /// exactly the kind of real-device-only anomaly this project has
    /// repeatedly needed `simctl spawn ... log stream` to diagnose (Task
    /// #58's own writeup). Only ever logs on an actual failure — no
    /// per-success noise.
    private static let translationLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLTranslationDiagnostic")

    /// Collects every visible text node's *current* text, in document
    /// order — the array `MessageView` hands to `MessageTranslator
    /// .translateHTMLTextNodes(messageId:texts:...)`. Read straight from
    /// `data-otegami-original` (not the node's live text, which could
    /// already be showing a translation from an unrelated earlier pass)
    /// so a re-extraction is always the true source text, never a
    /// translation-of-a-translation.
    ///
    /// Task #61 (実機フィードバック「HTMLメールの翻訳ボタンが無反応」):
    /// returns `nil` — not `[]` — when the JS call itself failed
    /// (`evaluateJavaScript` threw, or the result didn't decode as the JSON
    /// array `extractScript` promises) so `MessageView.requestTranslation`
    /// can tell "this message genuinely has no translatable text" (`[]`,
    /// harmless — an image-only mail, say) apart from "extraction broke"
    /// (`nil`) and show a visible failure for the latter instead of quietly
    /// doing nothing, which is what made the original report look like a
    /// dead tap ("無反応") — the translation flow used to press ahead with
    /// an empty `texts` array either way, translating zero paragraphs
    /// "successfully" with no visible effect and no error shown.
    func extractTranslatableTexts() async -> [String]? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(Self.extractScript)
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let texts = try? JSONDecoder().decode([String].self, from: data)
            else {
                Self.translationLogger.error("extractTranslatableTexts: unexpected result shape \(String(describing: result), privacy: .public)")
                return nil
            }
            return texts
        } catch {
            Self.translationLogger.error("extractTranslatableTexts failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Stamps `translations[i]` onto the node at index `i` as
    /// `data-otegami-translated`, WITHOUT changing what's currently visible
    /// — `showTranslated()` is the one that actually flips text on screen,
    /// so a caller that wants both calls this first, then that. Re-derives
    /// the stamped-node list fresh every time (via the same
    /// `otegamiWalkAndWrap` extraction uses) rather than assuming a
    /// previous call's spans still exist, which is what makes this safe to
    /// call again after `HTMLWebViewCoordinator.load(...)` has reloaded the
    /// document from scratch (an image-blocking banner toggled mid-session
    /// wipes every DOM stamp) — the fresh walk reproduces the identical
    /// ordered node list `translations` was aligned against, since both
    /// derive from the same underlying `html` string via the same
    /// deterministic walk. A count mismatch (a stale cached translation
    /// from a differently-shaped document — see `MessageTranslator
    /// .translateHTMLTextNodes`'s doc comment) leaves whatever nodes are in
    /// range stamped and silently ignores the rest, rather than guessing.
    /// Re-runs `HTMLWebViewCoordinator`'s fit-to-width pass afterward —
    /// translated text is rarely the exact same pixel width as the
    /// original, so the scale computed for the original document can be
    /// stale once it's replaced.
    func applyTranslations(_ translations: [String]) async {
        guard let webView, !translations.isEmpty else { return }
        guard let payload = Self.encodeStringArray(translations) else { return }
        let script = "\(Self.walkAndWrapFunctionSource)\n(function (t) { otegamiWalkAndWrap(function (span, i) { if (i >= 0 && i < t.length) { span.setAttribute('data-otegami-translated', t[i]); } }); })(\(payload));"
        _ = try? await webView.evaluateJavaScript(script)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// Restores every stamped node's pre-translation text — a no-op for any
    /// node with nothing stamped (a document that was never translated in
    /// the first place already shows its original text; nothing to do).
    func showOriginal() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(Self.showOriginalScript)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// Flips every stamped node to whatever `applyTranslations` last wrote
    /// for it — a no-op for a node `applyTranslations` was never called for
    /// (nothing translated yet).
    func showTranslated() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(Self.showTranslatedScript)
        Self.applyFitToWidthAfterMutation(to: webView)
    }

    /// `HTMLWebViewCoordinator.applyFitToWidth(to:)` is `fileprivate` to
    /// that type — both types live in this same file, so a thin same-file
    /// forwarder is all a cross-type call needs; no need to widen that
    /// method's own access level just for this one caller.
    private static func applyFitToWidthAfterMutation(to webView: WKWebView) {
        HTMLWebViewCoordinator.applyFitToWidth(to: webView)
    }

    /// `JSONSerialization` rather than hand-rolled string escaping — JSON's
    /// array-of-strings syntax is valid JS syntax verbatim, and
    /// `JSONSerialization` already correctly escapes every character JS
    /// string literals need escaped (quotes, backslashes, newlines, ...),
    /// which is what makes it safe to splice `translations` (real message
    /// text — not this app's own trusted source, so it can contain
    /// anything, including characters that would otherwise break out of a
    /// naively-quoted JS string) directly into a script string at all.
    private static func encodeStringArray(_ strings: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: strings, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#if os(iOS)
import UIKit

struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    let allowsExternalContent: Bool
    let allowsEmbeddedImages: Bool
    let autoAdjustColorsInDarkMode: Bool
    /// Task #71 — see `HTMLMessageView.forceLightBackground`'s doc comment.
    let forceLightBackground: Bool
    /// Task #56 — see `HTMLMessageView.bottomContentInset`'s doc comment.
    let bottomContentInset: CGFloat
    let cidContext: CIDResolutionContext
    /// 1i — see `HTMLMessageView.translationController`'s doc comment.
    let translationController: HTMLTranslationController
    let onOpenLink: (URL) -> Void
    /// Task #58 — see `HTMLWebViewCoordinator.onHeightChange`'s doc comment.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink, onHeightChange: onHeightChange) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
        // Task #58 (根治): this document's own real content height is now
        // reported back (`otegamiHeight` message handler, registered below)
        // and used to size this web view's *actual* frame, up at
        // `ThreadMessageRow` — so this web view no longer needs (or should
        // rely on) its own internal scroll surface. Two independent
        // scrollers used to be nested (this `WKWebView`'s own `UIScrollView`
        // inside `ThreadDetailView`'s outer `ScrollView`), and on this
        // toolchain the outer one always won the pan gesture, making
        // whatever didn't fit in this web view's fixed frame silently
        // unreachable — not just badly measured, genuinely unscrollable.
        // Disabling this one leaves exactly one scroller, which is what
        // actually fixes that (see `docs/design-system.md`'s Task #58 note
        // for the full root-cause writeup).
        webView.scrollView.isScrollEnabled = false
        webView.configuration.userContentController.add(context.coordinator, name: HTMLWebViewCoordinator.heightMessageHandlerName)
        translationController.webView = webView
        webView.navigationDelegate = context.coordinator
        // C7 バグ修正 (リンクがブラウザで開かない) — `HTMLWebViewCoordinator`
        // のdoc comment参照。real-device 固有と報告された不具合の有力な原因
        // の1つが `allowsLinkPreview`(既定 true): 実機の 3D/Haptic Touch が
        // リンクの長押しピーク・プレビューを認識しようとするジェスチャー
        // 認識器と、単純なタップの認識が競合し、タップが `decidePolicyFor`
        // まで届かないことがある — Simulator にはこのハードウェアがないため
        // design-phase-3 時点のシミュレータ検証では再現しなかった、という
        // 説明と整合する。ピーク・プレビュー自体もこのアプリでは使っていな
        // い機能なので、明示的に無効化する。
        webView.allowsLinkPreview = false
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Task #80 (チラつき根絶): hidden until `HTMLWebViewCoordinator
        // .applyFitToWidth(to:)`'s reveal callback fires — see that
        // method's doc comment for why this is the right moment (same
        // luminance-measurement pass this app already runs, not a new
        // mechanism) and why hiding only here (this view's *first* load,
        // not every `reloadIfNeeded` reload) is deliberate.
        webView.alpha = 0
        context.coordinator.load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset,
            cidContext: cidContext, into: webView
        )
    }
}
#elseif os(macOS)
import AppKit

struct HTMLWebViewRepresentable: NSViewRepresentable {
    let html: String
    let allowsExternalContent: Bool
    let allowsEmbeddedImages: Bool
    let autoAdjustColorsInDarkMode: Bool
    /// Task #71 — see `HTMLMessageView.forceLightBackground`'s doc comment.
    let forceLightBackground: Bool
    /// Task #56 — see `HTMLMessageView.bottomContentInset`'s doc comment.
    let bottomContentInset: CGFloat
    let cidContext: CIDResolutionContext
    /// 1i — see `HTMLMessageView.translationController`'s doc comment.
    let translationController: HTMLTranslationController
    let onOpenLink: (URL) -> Void
    /// Task #58 — see `HTMLWebViewCoordinator.onHeightChange`'s doc comment.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink, onHeightChange: onHeightChange) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
        // Task #58 — see the iOS `makeUIView`'s identical comment (this
        // repo's macOS layout doesn't nest `HTMLMessageView` inside its own
        // accordion `ScrollView` the way `ThreadDetailView`'s iOS-shared
        // implementation does today, but registering the same height
        // channel here keeps both platforms on one code path and leaves
        // room for macOS to opt into the same real-height sizing later
        // without another round of WKWebView plumbing).
        webView.configuration.userContentController.add(context.coordinator, name: HTMLWebViewCoordinator.heightMessageHandlerName)
        translationController.webView = webView
        webView.navigationDelegate = context.coordinator
        // C7 バグ修正 — `allowsLinkPreview`はiOS専用のプロパティなので
        // macOSにはない。`target="_blank"`リンクの取りこぼし対策の
        // `uiDelegate`はプラットフォーム共通で必要なので、iOS側と同じく
        // ここでも設定する。
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        // Task #80 — see the iOS `makeUIView`'s identical comment.
        webView.alphaValue = 0
        context.coordinator.load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset,
            cidContext: cidContext, into: webView
        )
    }
}
#endif

/// Compiles (once, cached by `WKContentRuleListStore` under its fixed
/// identifier) and applies/removes the content-blocking rule list, then
/// loads the wrapped HTML.
@MainActor
final class HTMLWebViewCoordinator: NSObject, WKNavigationDelegate {
    /// Blocks every `http(s)://` subresource request. Loading the message
    /// itself via `loadHTMLString(_:baseURL:)` is not itself a network
    /// request, so this only ever blocks things the HTML *references*
    /// (images, iframes, ...), never the message content itself.
    private static let blockAllRemoteResourcesRuleList = """
    [{"trigger": {"url-filter": "^https?://.*"}, "action": {"type": "block"}}]
    """

    private static let ruleListIdentifier = "otegami.blockAllRemoteResources"

    /// M8: the `WKURLSchemeHandler` for `otegami-cid://`, created once
    /// (`WKWebViewConfiguration.setURLSchemeHandler` can only be called
    /// before the web view's first load — it isn't something `load(html:
    /// allowsExternalContent:into:)` could re-register per navigation the
    /// way the content rule list is re-applied). `mailboxPath` in
    /// particular can still be `nil` on the coordinator's very first
    /// `init` in principle (see `HTMLMessageView`'s doc comment for why
    /// that shouldn't actually happen given how `MessageView.load()`
    /// sequences its state), so `updateContext` keeps it current on every
    /// `reloadIfNeeded` regardless.
    let cidHandler: CIDSchemeHandler?

    /// C7: forwarded from `HTMLMessageView.handleLinkTap` — called from
    /// `decidePolicyFor` for any `http(s)://` link tap, after that
    /// navigation has already been cancelled in-place.
    private let onOpenLink: (URL) -> Void

    /// Task #58 (根治): the document's real, full content height (in CSS
    /// px, which this app's viewport makes equal to points) — see
    /// `heightReportingScript`'s doc comment for how it's measured and
    /// posted. `HTMLWebViewRepresentable` forwards whatever `HTMLMessageView`
    /// was given, which threads all the way up to `ThreadMessageRow`
    /// (`ThreadDetailView.swift`) — that's the view that actually owns the
    /// fixed-height budget this document used to be silently clipped to
    /// (`docs/design-system.md`'s Task #58 note has the full root-cause
    /// writeup), so this callback is what lets that budget grow to match
    /// real content instead of guessing a constant.
    private let onHeightChange: (CGFloat) -> Void

    init(cidContext: CIDResolutionContext, onOpenLink: @escaping (URL) -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
        self.cidHandler = CIDSchemeHandler(context: cidContext)
        self.onOpenLink = onOpenLink
        self.onHeightChange = onHeightChange
    }

    private var lastLoadedHTML: String?
    private var lastAllowsExternalContent: Bool?
    private var lastAllowsEmbeddedImages: Bool?
    /// Task #45 — mirrors the two `lastAllows...` flags above: needs to be
    /// tracked separately so `reloadIfNeeded` reloads the document when only
    /// this setting flips (e.g. the user toggles it in Settings while a
    /// message is still open), the same way it already does for the image
    /// settings.
    private var lastAutoAdjustColorsInDarkMode: Bool?
    /// Task #71 — mirrors `lastAutoAdjustColorsInDarkMode` immediately above,
    /// same reasoning.
    private var lastForceLightBackground: Bool?
    /// Task #56 — mirrors the flags above: tracked so `reloadIfNeeded`
    /// reloads (re-injects the bottom spacer, `HTMLDocumentBuilder.wrap`'s
    /// doc comment) when only this changes, e.g. the AI要約/翻訳 floating
    /// buttons appear/disappear for the same open message (a translation
    /// becoming available mid-view is the realistic case).
    private var lastBottomContentInset: CGFloat?

    /// C7 real-device/real-simulator bug fix. Extensive diagnostic
    /// instrumentation (temporary `UserDefaults`-marker tracing —
    /// `docs/verify.md`'s C7 section — from before this fix) proved, on
    /// this project's current toolchain, all of the following at once:
    ///  1. A tap on a plain `<a href="https://...">` link *does* reach the
    ///     `WKWebView`'s native UIKit view hierarchy (confirmed with a
    ///     bare `UITapGestureRecognizer` added directly to the web view —
    ///     it fires at the correct on-screen coordinate).
    ///  2. WebKit *does* act on that tap as a real navigation — a second
    ///     `didFinish` fires after the tap, for content this app never
    ///     asked to load.
    ///  3. Despite (1) and (2), **neither `decidePolicyFor` (this type's
    ///     `WKNavigationDelegate` conformance below) nor
    ///     `createWebViewWith` (`WKUIDelegate`, further below) is ever
    ///     invoked for that navigation** — confirmed by instrumenting both
    ///     with the same tracer and seeing neither log a single call, for
    ///     the entire lifetime of the view including the tap.
    /// In other words: on this toolchain, WKWebView silently navigates a
    /// tapped link in place *without* ever consulting either delegate this
    /// app relies on to intercept it — a genuine platform-level anomaly
    /// (standard `WKNavigationDelegate` usage, not a bug in this app's
    /// delegate implementation), not something fixable by changing what
    /// those delegate methods themselves do. `WKWebView.url` is a plain
    /// KVO-observable property that WebKit updates as part of any
    /// navigation, entirely independent of delegate dispatch — this
    /// observer is a delegate-independent fallback that watches for that
    /// URL becoming an `http(s)://` address (the tell-tale sign of exactly
    /// this stray in-place navigation, since this app never itself loads
    /// anything but `loadHTMLString(_:baseURL: nil)`, whose `url` is never
    /// `http(s)`) and, when it does, immediately stops that navigation and
    /// reloads this message's own content to undo it, then forwards the
    /// tapped URL to `onOpenLink` exactly as `decidePolicyFor` would have.
    /// Harmless on a toolchain where `decidePolicyFor` *does* fire
    /// normally: a properly cancelled navigation never updates `url` to
    /// the external address in the first place, so this observer simply
    /// never has anything to act on there.
    private var strayNavigationObservation: NSKeyValueObservation?

    private func observeStrayNavigations(on webView: WKWebView) {
        guard strayNavigationObservation == nil else { return }
        strayNavigationObservation = webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, change in
            guard let self, let webView, let url = change.newValue ?? nil else { return }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            Task { @MainActor in
                self.recoverFromStrayNavigation(to: url, on: webView)
            }
        }
    }

    private func recoverFromStrayNavigation(to url: URL, on webView: WKWebView) {
        webView.stopLoading()
        if let html = lastLoadedHTML, let allowsExternalContent = lastAllowsExternalContent, let allowsEmbeddedImages = lastAllowsEmbeddedImages {
            load(
                html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
                autoAdjustColorsInDarkMode: lastAutoAdjustColorsInDarkMode ?? HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode,
                forceLightBackground: lastForceLightBackground ?? HTMLDisplaySettingsStore.defaultForceLightBackground,
                bottomContentInset: lastBottomContentInset ?? 0,
                into: webView
            )
        }
        onOpenLink(url)
    }

    func reloadIfNeeded(
        html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool, autoAdjustColorsInDarkMode: Bool,
        forceLightBackground: Bool,
        bottomContentInset: CGFloat, cidContext: CIDResolutionContext, into webView: WKWebView
    ) {
        cidHandler?.updateContext(cidContext)
        guard html != lastLoadedHTML
            || allowsExternalContent != lastAllowsExternalContent
            || allowsEmbeddedImages != lastAllowsEmbeddedImages
            || autoAdjustColorsInDarkMode != lastAutoAdjustColorsInDarkMode
            || forceLightBackground != lastForceLightBackground
            || bottomContentInset != lastBottomContentInset
        else { return }
        load(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
            autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode, forceLightBackground: forceLightBackground,
            bottomContentInset: bottomContentInset, into: webView
        )
    }

    func load(
        html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool, autoAdjustColorsInDarkMode: Bool,
        forceLightBackground: Bool = false,
        bottomContentInset: CGFloat = 0, into webView: WKWebView
    ) {
        observeStrayNavigations(on: webView)
        lastLoadedHTML = html
        lastAllowsExternalContent = allowsExternalContent
        lastAllowsEmbeddedImages = allowsEmbeddedImages
        lastAutoAdjustColorsInDarkMode = autoAdjustColorsInDarkMode
        lastForceLightBackground = forceLightBackground
        lastBottomContentInset = bottomContentInset

        // B5: rewrite cid: references to the otegami-cid:// scheme *only*
        // when embedded images are currently allowed — independent of
        // `allowsExternalContent`/the content rule list below, which only
        // ever matches `^https?://` and so never touches this custom scheme
        // either way (plan: "外部画像ブロックとは独立に動くこと"). When
        // embedded images are off, `cid:` references are left as literal
        // `src="cid:..."` — WebKit has no handler for a bare `cid:` scheme,
        // so it simply fails to load that image (the same "broken image"
        // outcome a blocked remote image already produces), which is the
        // intended "don't auto-show" behavior.
        let cidRewrittenHTML = allowsEmbeddedImages ? CIDURLRewriter.rewrite(html: html) : html
        let document = HTMLDocumentBuilder.wrap(
            bodyHTML: cidRewrittenHTML, autoAdjustColorsInDarkMode: autoAdjustColorsInDarkMode,
            forceLightBackground: forceLightBackground, bottomContentInset: bottomContentInset
        )

        applyContentRuleList(blocked: !allowsExternalContent, to: webView) { [weak webView] in
            guard let webView else { return }
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    private func applyContentRuleList(blocked: Bool, to webView: WKWebView, completion: @escaping () -> Void) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard blocked else {
            completion()
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: Self.blockAllRemoteResourcesRuleList
        ) { ruleList, _ in
            // A compile failure (shouldn't happen for this fixed, valid
            // rule list) just means external content loads unblocked
            // rather than the message failing to render at all.
            if let ruleList {
                controller.add(ruleList)
            }
            completion()
        }
    }

    // MARK: - fit-to-width

    /// `HTMLDocumentBuilder.wrap(bodyHTML:)`'s "fit-to-width" doc comment
    /// explains *why*; this is the *how*. Idempotent (safe to run more than
    /// once against the same, unchanged DOM — resets any previous scale
    /// first), which is what makes it safe for 1i's HTML-preserving
    /// translation (`HTMLTranslationController`) to re-run it after
    /// rewriting text nodes, since a translated string is rarely the exact
    /// same pixel width as its original.
    ///
    /// Measures against `outer.clientWidth` (the actual available content
    /// width inside `body`'s own padding), not
    /// `document.documentElement.clientWidth` (the raw viewport width,
    /// which would overstate the budget by `body`'s left+right padding and
    /// leave a sliver still clipped at the edge).
    ///
    /// 本文が途中で切れる不具合の根本原因と修正 (実機フィードバック):
    /// `didFinish`(ページの`load`イベント) は仕様上「参照されている画像も
    /// 読み込み終わってから発火する」はずだが、`CIDSchemeHandler`(M8の
    /// `cid:`画像解決) は `WKURLSchemeTask` 経由で**非同期に** (添付テーブル
    /// の GRDB 検索、未ダウンロードなら IMAP 経由のオンデマンド取得まで
    /// 発生しうる) レスポンスを返す実装になっており、実機では `didFinish`
    /// がこの非同期解決の完了を待たずに発火することがある — 修正前は
    /// それを見越して「`didFinish` 直後に1回 + 0.3秒後にもう1回」という
    /// 固定ウェイトの決め打ちでカバーしていたが、0.3秒より遅い画像解決
    /// (低速回線・未キャッシュの添付ダウンロード等) では両方とも実際の
    /// レイアウトが確定する前に測定してしまい、その時点の (実際より小さい)
    /// `naturalHeight` を元に `outer.style.height` を確定させてしまって
    /// いた。scale が必要なケース (`naturalWidth > viewportWidth`) では
    /// この `outer.style.height` が明示的な固定値になるため、あとから画像
    /// が読み込まれてページの実際の高さが伸びても反映されず、ページ末尾
    /// (画像より下の段落・ボタン等) が `overflow: hidden` の外側に押し
    /// 出されたまま見えなくなる — 「罫線の下から本文が描画されない」実機
    /// 報告と一致する。
    ///
    /// 修正: `document.images` のうち `complete === false` なもの全てに
    /// ついて `load`/`error` イベント (どちらであっても「この画像の分の
    /// レイアウトは確定した」ことを意味する) を待つ `Promise` を返す
    /// non-async IIFE にした — `evaluateJavaScript` (Swift の `async` 版)
    /// はページが返した `Promise` の解決を実際に待つ (WebKit の標準
    /// 挙動)。画像1枚あたり `imageWaitTimeoutMs` (4秒) のタイムアウトも
    /// 持たせてある — ブロックされたリモート画像・失敗した `cid:` 解決が
    /// 永久に `load`/`error` のどちらも発火しないケースへの安全網
    /// (`WKContentRuleList` でブロックされたリクエストは通常 `error` を
    /// 発火するはずだが、「はず」に全面的に頼らない)。
    private static let imageWaitTimeoutMs = 4000

    /// Task #51: the dark-mode "反転" decision, made here (not statically
    /// in `HTMLDocumentBuilder`) — see `HTMLDocumentBuilder.wrap(bodyHTML:
    /// autoAdjustColorsInDarkMode:)`'s doc comment for why a static
    /// "does the mail declare its own dark support" check alone regressed
    /// (it invert()ed messages with zero author color declarations too,
    /// wrongly flipping their already-correct auto-adapted `CanvasText`
    /// into unreadable dark-on-transparent). Runs as part of the same
    /// `fitToWidthScript` IIFE (after `waitForImages()`, before `fit()`)
    /// rather than as a separate `evaluateJavaScript` call — cheap, keeps
    /// every call site (`didFinish`, the 1.5s safety net,
    /// `HTMLTranslationController`'s post-mutation reapply) automatically
    /// covered without threading a new parameter through all of them, and
    /// `document.getElementById('otegami-fit-outer').hasAttribute
    /// ('data-otegami-invert-check')` (set only when `HTMLDocumentBuilder
    /// .wrap` decided this document is even eligible — setting OFF or the
    /// mail declaring its own dark support both mean the attribute is
    /// absent) makes the whole thing self-contained: no Swift-side state
    /// needs to travel alongside `webView` across those different call
    /// sites. Skipped entirely outside dark mode (`matchMedia`) since the
    /// CSS itself is `@media (prefers-color-scheme: dark)`-scoped anyway —
    /// running the DOM walk in light mode would just be wasted work.
    ///
    /// Measures, in priority order, the first *opaque* (alpha > 0)
    /// `background-color` among: `document.body` itself (a message's own
    /// `<style>body{...}</style>` rule — preserved verbatim by
    /// `HTMLDocumentBuilder.extractHeadStyles` into this document's own
    /// `<head>` — legitimately targets this real `<body>` tag, so this
    /// catches the extremely common "page background" declaration even
    /// though the original `<body ...>` tag's own attributes/inline style
    /// don't survive `extractBodyContent` at all), `#otegami-fit-inner`
    /// (the wrapper itself), then the largest-on-screen-area element
    /// anywhere inside it that sets one explicitly (a "card" `<div>` etc.
    /// — capped to the first 800 elements purely as a cheap safety net
    /// against a pathological document, not expected to matter for real
    /// mail) **and covering at least 30% of `inner`'s own rendered area**
    /// (Task #84 — see `findEffectiveBackground`'s own inline comment for
    /// the real-device case this guards against: a small colored CTA
    /// button being the *only* element with any background at all,
    /// trivially "winning" as the largest candidate despite covering a
    /// sliver of the message). A message with zero color declarations
    /// anywhere (today's regression case) never finds an opaque candidate
    /// at any of the three tiers — this file's own reset already sets
    /// `background: transparent` on `html, body`, and nothing else in the
    /// document overrides it — so `findEffectiveBackground` returns `null`
    /// and `decideDarkInversion` leaves `.otegami-invert-for-dark` off
    /// (the safe default for "couldn't determine").
    ///
    /// Only when an opaque background *is* found and its WCAG relative
    /// luminance is above 0.5 (i.e. it reads as a light background — a
    /// message written light-mode-only) does this add the class. A
    /// handful (`<= 6`) of representative text nodes' `color` are also
    /// sampled as a light corroborating signal (skipped, not blocking,
    /// when text sampling itself comes back empty — a background that's
    /// genuinely measured as light is reason enough on its own to invert).
    ///
    /// **Task #80**: everything above still decides *whether* a message
    /// needs help ("intervene" — `shouldIntervene` in `decideDarkInversion`
    /// below); what changed is *which* remedy gets applied once that's
    /// true. `outer.hasAttribute('data-otegami-prefer-invert')` (set by
    /// `HTMLDocumentBuilder.wrap` only when `autoAdjustColorsInDarkMode` is
    /// `true` — now an opt-in, default `false`) picks classic invert
    /// (`.otegami-invert-for-dark`/`.otegami-invert-active`, unchanged from
    /// Task #51/#56/#71) when present; the new default (attribute absent)
    /// picks "keep light" (`.otegami-keep-light-active`) instead — the
    /// message's own light colors render untouched (no filter, no logo-chip
    /// treatment needed) while a small CSS safety net
    /// (`HTMLDocumentBuilder.wrap`'s `darkModeInvertStyle`, the
    /// `otegami-keep-light-active` rule) forces `html`/`body` to a white
    /// canvas so nothing shows through any gap the message's own styling
    /// doesn't cover. This directly answers the real-device report (video
    /// f012→f015) that the invert path's "flash correct-light, then flip to
    /// inverted-dark" transition, plus its own artifacts (Task #71's white
    /// stripe/logo-sinking), were worse than just leaving a light-designed
    /// message light. A message with no color declarations at all still
    /// never reaches `shouldIntervene = true` (this section's existing
    /// reasoning, unchanged), so it keeps rendering dark-native via
    /// `CanvasText` regardless of this setting either way.
    ///
    /// **Task #98 (実機フィードバック: Google カレンダー招待メール等がダーク
    /// モードでほぼ読めない)**: 背景が最後まで解決しない (`findEffectiveBackground`
    /// が`null`) ケースの`representativeTextLuminance`によるフォールバック
    /// (直前の段落、Task #56) は文書順で見つかった最初の6テキストノードしか
    /// 平均しない — 実際の招待メールは本文の主要ラベル ("会議のリンク"/
    /// "日時"/"ゲスト"、白背景前提の`#5f6368`等の中間グレーを明示指定) に
    /// 届く前に、非表示のプレビュー用テキストや色を明示しない見出しなど
    /// (著者が色を指定していないので `CanvasText` 経由でダークモード中は
    /// 明るく解決される) を複数拾ってしまい、6件の平均が0.5を超えて
    /// 「介入不要」に転ぶことがあった (実測で確認済み)。`explicitDarkText
    /// IsMajority`はこの取りこぼしを拾う追加の証拠 — 6件のサンプリングでは
    /// なく`inner`配下の**全テキストノード**を文字数ベースで集計し、
    /// 「祖先のいずれかが明示的に`color`を指定している」サブツリー配下の
    /// テキストだけを対象に、その実測輝度 (閾値 0.55、
    /// `representativeTextLuminance`の0.5よりわずかに緩い — 白背景前提の
    /// 中間色まで拾うため) が低いものの文字数が可視テキスト全体の過半を
    /// 占めるかどうかを見る。色を一切指定しない (継承のみの) テキストは
    /// 明示指定側にカウントしない — プレーンテキスト風メールを誤って
    /// 白カード化しないための線引き。既存の6サンプル判定 (`shouldIntervene`
    /// が既に`true`) はそのまま優先し、この追加判定は「介入不要」に転んだ
    /// ときの二段目のフォールバックとしてだけ働く。
    ///
    /// **Task #104 (実機フィードバック: Readdle Documents のニュースレター等
    /// が上記 Task #98 の対策後もダークネイティブのまま読めない)**: 直前の
    /// 段落の「明示的に`color`を指定」の判定方法をここで拡張した —
    /// リリース当初 (Task #98) は「祖先のいずれかがインライン`style`で
    /// `color`を指定」だけを見ており、`<style>`ブロックの CSS クラス経由で
    /// 文字色を指定するニュースレター (インライン style を使わず
    /// `.body-text { color: #5f6368; }` のようなクラスセレクタで配色する
    /// テンプレートは珍しくない) を取りこぼしていた。
    /// `collectExplicitColorSelectors`が`document.styleSheets`
    /// (`HTMLDocumentBuilder.wrap`が注入する自前の`<style>`は
    /// `data-otegami-base-style`属性で除外し、メール自身が持っていた
    /// `<style>`ブロックだけを見る) を走査して`color`宣言を持つセレクタを
    /// 集め、`nearestExplicitColorAncestor`が`Element.matches()`で祖先を
    /// マッチさせる — インライン`style`の判定と同じ経路に合流させることで、
    /// どちらの書き方でも同じ実測輝度ベースの判定を通る。詳細は
    /// `docs/design-system.md`のTask #98節 (このTask #104の追記含む) 参照。
    private static let fitToWidthScript = """
    (function () {
      function waitForImages() {
        var pending = Array.prototype.slice.call(document.images).filter(function (img) { return !img.complete; });
        if (pending.length === 0) { return Promise.resolve(); }
        return Promise.all(pending.map(function (img) {
          return new Promise(function (resolve) {
            var settled = false;
            function finish() { if (!settled) { settled = true; resolve(); } }
            img.addEventListener('load', finish, { once: true });
            img.addEventListener('error', finish, { once: true });
            setTimeout(finish, \(imageWaitTimeoutMs));
          });
        }));
      }
      function relativeLuminance(rgb) {
        function channel(c) {
          var normalized = c / 255;
          return normalized <= 0.03928 ? normalized / 12.92 : Math.pow((normalized + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b);
      }
      // Task #112 (実機報告 — ダークモードで実メール本文の暗色文字が沈む
      // 再現続報): `getComputedStyle(...).color`/`.backgroundColor` は
      // ソースが `#333333` (16進) でも `rgb(51, 51, 51)` (関数記法) でも
      // ブラウザ側で常にこの `rgb()`/`rgba()` 直列化に正規化されるため、
      // このパース自体はどちらの記法で著者が書いていても元々同じ結果になる
      // — 「16進しか対応していないのでは」という当初の疑いはここでは
      // 再現しなかった。とはいえ CSS Color 4 のスペース区切り記法
      // (`rgb(51 51 51 / 0.5)`、カンマなし・任意でスラッシュの後にアルファ)
      // をこの正規表現の`split(',')`一本槍では拾えなかった (パース失敗)
      // ため、カンマ区切り・スペース区切りのどちらも受け付けるよう
      // 頑健化しておく。
      function parseOpaqueColor(cssColor) {
        if (!cssColor) { return null; }
        var match = cssColor.match(/rgba?\\(([^)]+)\\)/);
        if (!match) { return null; }
        var alphaSplit = match[1].split('/');
        var parts = alphaSplit[0].split(/[\\s,]+/).filter(function (part) { return part.length > 0; }).map(function (part) { return parseFloat(part); });
        var alpha = alphaSplit.length > 1 ? parseFloat(alphaSplit[1]) : (parts.length > 3 ? parts[3] : 1);
        if (!(alpha > 0)) { return null; }
        return { r: parts[0], g: parts[1], b: parts[2] };
      }
      function opaqueBackgroundOf(el) {
        if (!el) { return null; }
        return parseOpaqueColor(getComputedStyle(el).backgroundColor);
      }
      function findEffectiveBackground(inner) {
        var bodyColor = opaqueBackgroundOf(document.body);
        if (bodyColor) { return bodyColor; }
        var wrapperColor = opaqueBackgroundOf(inner);
        if (wrapperColor) { return wrapperColor; }
        var elements = inner.querySelectorAll('*');
        var limit = Math.min(elements.length, 800);
        var best = null;
        var bestArea = 0;
        for (var i = 0; i < limit; i++) {
          var el = elements[i];
          var color = opaqueBackgroundOf(el);
          if (!color) { continue; }
          var area = el.offsetWidth * el.offsetHeight;
          if (area > bestArea) { bestArea = area; best = color; }
        }
        // Task #84 (real-device report: a Google Calendar invite's HTML —
        // no `body`/wrapper background at all, just a small blue "Google
        // Meet に参加する" CTA button — rendered as washed-out gray-on-black
        // in dark mode instead of getting either remedy). Root cause: that
        // button was the *only* element in the whole document with any
        // background-color at all, so it trivially "won" the loop above as
        // the largest (only) candidate — `findEffectiveBackground` returned
        // its color, `decideDarkInversion` treated that as "the message's
        // real canvas color", and since a button's blue isn't `> 0.5`
        // luminance, concluded "already fine in dark mode" without ever
        // reaching the text-luminance fallback (this function's own doc
        // comment, `representativeTextLuminance`) that would have caught
        // the actually-dark, actually-unreadable gray label text. A CTA
        // button covering a sliver of the message isn't a credible stand-in
        // for its overall page background the way a `body`-level color or a
        // full-width "card" `<div>` is — requiring the candidate to cover a
        // real share of the rendered content (30% of `inner`'s own area)
        // before trusting it fixes this without touching the `body`/wrapper
        // tiers above (those are explicit, unambiguous page-level
        // declarations regardless of size).
        if (best && inner.offsetWidth > 0 && inner.offsetHeight > 0) {
          var innerArea = inner.offsetWidth * inner.offsetHeight;
          if (bestArea < innerArea * 0.3) { return null; }
        }
        return best;
      }
      function representativeTextLuminance(inner) {
        var walker = document.createTreeWalker(inner, NodeFilter.SHOW_TEXT, null);
        var node;
        var total = 0;
        var count = 0;
        while (count < 6 && (node = walker.nextNode())) {
          var text = node.nodeValue;
          if (!text || text.trim().length < 3) { continue; }
          var parentEl = node.parentElement;
          if (!parentEl) { continue; }
          var color = parseOpaqueColor(getComputedStyle(parentEl).color);
          if (!color) { continue; }
          total += relativeLuminance(color);
          count += 1;
        }
        return count > 0 ? total / count : null;
      }
      // Task #98: see `representativeTextLuminance`'s doc comment above
      // `fitToWidthScript` for why the 6-sample average above isn't always
      // enough. `nearestExplicitColorAncestor` walks up from a text node's
      // parent looking for the nearest ancestor (up to and including
      // `boundary`, normally `#otegami-fit-inner`) that declares `color`
      // explicitly — a literal declaration check, not `getComputedStyle`
      // (which always resolves to *some* color, explicit or inherited, and
      // so can't tell the two apart on its own).
      //
      // Task #104 (実機フィードバック: Readdle Documents のニュースレター等、
      // `<style>` ブロックの CSS クラスで文字色を指定するメールが検出漏れし
      // ダークネイティブのまま読めなかった): Task #98 版はインライン `style`
      // の `color` しか見ておらず、`<style>` ブロックのクラスセレクタ経由の
      // 明示指定を見落としていた。`selectors` (`collectExplicitColorSelectors`
      // が集めた、`color` 宣言を持つセレクタ文字列の配列) が渡されたときは
      // それも見る — `Element.matches()` でどのセレクタにもマッチしなければ
      // インライン判定のみだった従来の挙動のまま。
      function nearestExplicitColorAncestor(el, boundary, selectors) {
        var node = el;
        while (node) {
          if (node.style && node.style.color) { return node; }
          if (selectors && selectors.length && elementMatchesAnySelector(node, selectors)) { return node; }
          if (node === boundary) { return null; }
          node = node.parentElement;
        }
        return null;
      }
      // Task #104: `el.matches(selector)` throws on a selector this
      // WebKit build doesn't understand (e.g. a vendor-prefixed pseudo-class
      // some ESP template generator emits) — caught and skipped per-selector
      // so one unsupported selector in a message's `<style>` block doesn't
      // abort the whole scan, consistent with this file's other "don't let
      // one weird input wreck the whole heuristic" choices (e.g.
      // `stripHTMLComments`'s regex-compile fallback).
      function elementMatchesAnySelector(el, selectors) {
        for (var i = 0; i < selectors.length; i++) {
          try {
            if (el.matches(selectors[i])) { return true; }
          } catch (e) { /* unsupported selector syntax — skip it */ }
        }
        return false;
      }
      // Task #104: walks `document.styleSheets` to collect every selector
      // whose rule declares a `color` — this is what lets
      // `nearestExplicitColorAncestor` recognize "explicit color" set via a
      // CSS class in a `<style>` block, not just an inline `style="color:
      // ..."` attribute. Skips any sheet whose owning `<style>`/`<link>`
      // element carries `data-otegami-base-style` (`HTMLDocumentBuilder
      // .wrap`'s own injected `<style>` tags — the base reset, the dark-
      // invert/keep-light styles, `forceLightBackgroundStyle`) so this
      // file's own rules (e.g. `a { color: LinkText; }`) never get mistaken
      // for the *message author's* explicit color intent — only
      // `originalHeadStyles` (the message's own extracted `<style>` blocks,
      // left unmarked) is scanned. External stylesheets can't appear here at
      // all (this app strips remote resources via `WKContentRuleList`
      // before the page ever loads one), so a same-document walk is
      // complete on its own — no CORS-blocked `cssRules` access to worry
      // about for *message* stylesheets (a `try`/`catch` around the access
      // is still cheap insurance). `collectRulesInto` recurses into grouping
      // rules (`@media`/`@supports`/etc, anything exposing its own
      // `.cssRules`) regardless of whether the rule's own condition matches
      // the current environment — a `@media (prefers-color-scheme: dark)`
      // block a newsletter ships alongside its light-mode default still
      // reflects the author's intent to color that text explicitly, so it
      // counts too (deliberately erring toward *more* explicit-color
      // detections here, matching this whole heuristic's existing bias per
      // its Task #98 doc comment above `fitToWidthScript`).
      function collectExplicitColorSelectors() {
        var selectors = [];
        var sheets = document.styleSheets;
        for (var s = 0; s < sheets.length; s++) {
          var sheet = sheets[s];
          var ownerNode = sheet.ownerNode;
          if (ownerNode && ownerNode.hasAttribute && ownerNode.hasAttribute('data-otegami-base-style')) { continue; }
          var rules;
          try { rules = sheet.cssRules; } catch (e) { continue; }
          if (rules) { collectRulesInto(rules, selectors); }
        }
        return selectors;
      }
      function collectRulesInto(rules, selectors) {
        for (var i = 0; i < rules.length; i++) {
          var rule = rules[i];
          if (typeof rule.selectorText === 'string' && rule.style && rule.style.color) {
            selectors.push(rule.selectorText);
          } else if (rule.cssRules) {
            collectRulesInto(rule.cssRules, selectors);
          }
        }
      }
      // Task #98: character-count based (not a fixed sample of 6 nodes) —
      // walks every text node under `inner`, and for each one that falls
      // under an explicitly `color`-declared ancestor, measures that
      // ancestor's actual rendered color (`getComputedStyle` *is* used here,
      // just to resolve the real rgb() value once a node has already
      // qualified as "explicitly colored" — this is the "measuring" half,
      // separate from the "is it explicit" question `nearestExplicit
      // ColorAncestor` answers on its own). Text with no explicitly colored
      // ancestor at all (pure inheritance — e.g. a color-less heading, or a
      // hidden preheader line) is counted toward the visible-text total but
      // never toward the "explicit dark" bucket, which is exactly what keeps
      // a genuinely colorless plain-text-style message from tripping this
      // (its explicit-dark share stays at 0%, never a majority). Capped at
      // 4000 visited text nodes purely as a cheap safety net against a
      // pathological document, matching this file's other such caps (`findEffectiveBackground`'s 800-element cap).
      //
      // Task #104: `selectors` is computed once per call (not per text
      // node) via `collectExplicitColorSelectors` and threaded through to
      // `nearestExplicitColorAncestor` — cheap relative to the 4000-node cap
      // above it, and keeps the stylesheet walk out of the hot per-node loop.
      // Task #112 (実機報告続報 — 実メールで再現): プリヘッダの隠しダミー
      // テキスト (`color:transparent; visibility:hidden; font-size:0px`
      // 等、メール配信ツールが受信箱プレビュー文言を制御するために埋め込む
      // 定番パターン — 実際の readdle.eml の例では不可視の結合文字を
      // 大量に含む数百文字級のダミー行だった) が、可視本文と区別なく
      // `explicitDarkTextIsMajority` の分母 (`totalLength`) に算入されて
      // いた。可視本文がどれだけ暗色主体でも、この巨大な不可視テキストが
      // 分母を水増しして過半数判定 (`> totalLength / 2`) を割ってしまい
      // うる — 実機で再現した「本文が沈む」の一因。`display:none` は
      // 継承されないため祖先チェーンを歩いて確認し、`visibility`/
      // `font-size`/文字色の不透明度は継承されるので直近の親だけで判定
      // すれば十分 (`opacity` は継承されないので同じ祖先チェーンで見る)。
      function isVisuallyHiddenText(parentEl, boundary) {
        var node = parentEl;
        while (node) {
          var ancestorStyle = getComputedStyle(node);
          if (ancestorStyle.display === 'none') { return true; }
          var opacity = parseFloat(ancestorStyle.opacity);
          if (!isNaN(opacity) && opacity <= 0) { return true; }
          if (node === boundary) { break; }
          node = node.parentElement;
        }
        var style = getComputedStyle(parentEl);
        if (style.visibility === 'hidden') { return true; }
        var fontSize = parseFloat(style.fontSize);
        if (!isNaN(fontSize) && fontSize <= 0) { return true; }
        if (parseOpaqueColor(style.color) === null) { return true; }
        return false;
      }
      function explicitDarkTextIsMajority(inner) {
        var selectors = collectExplicitColorSelectors();
        var walker = document.createTreeWalker(inner, NodeFilter.SHOW_TEXT, null);
        var node;
        var visited = 0;
        var totalLength = 0;
        var explicitDarkLength = 0;
        while (visited < 4000 && (node = walker.nextNode())) {
          visited += 1;
          var text = node.nodeValue;
          if (!text) { continue; }
          var trimmed = text.trim();
          if (trimmed.length === 0) { continue; }
          var parentEl = node.parentElement;
          if (!parentEl) { continue; }
          if (isVisuallyHiddenText(parentEl, inner)) { continue; }
          totalLength += trimmed.length;
          var colorEl = nearestExplicitColorAncestor(parentEl, inner, selectors);
          if (!colorEl) { continue; }
          var color = parseOpaqueColor(getComputedStyle(parentEl).color);
          if (!color) { continue; }
          // 0.55: slightly looser than `representativeTextLuminance`'s 0.5
          // — this is meant to also catch white-background-assuming
          // mid-grays (`#5f6368`前後、Google 系テンプレート頻出) that read
          // fine on white but wash out on a dark canvas, not just clearly
          // "dark" text. Starting point per Task #98's spec; adjust here if
          // real-world verification (`docs/design-system.md`のTask #98節)
          // finds it too aggressive or not aggressive enough.
          if (relativeLuminance(color) < 0.55) {
            explicitDarkLength += trimmed.length;
          }
        }
        return totalLength > 0 && explicitDarkLength > totalLength / 2;
      }
      function decideDarkInversion() {
        var outer = document.getElementById('otegami-fit-outer');
        var inner = document.getElementById('otegami-fit-inner');
        if (!outer || !inner || !outer.hasAttribute('data-otegami-invert-check')) { return; }
        if (!window.matchMedia || !window.matchMedia('(prefers-color-scheme: dark)').matches) { return; }
        // Task #80: whether this document, if left untouched, would look
        // broken in dark mode — the measurement itself is unchanged from
        // Task #51/#56 (see this function's doc comment above `fitToWidthScript`
        // for the full history). What's new is `preferInvert`: which of the
        // two remedies below actually gets applied once `shouldIntervene`
        // is true.
        var preferInvert = outer.hasAttribute('data-otegami-prefer-invert');
        var background = findEffectiveBackground(inner);
        var shouldIntervene = false;
        if (background) {
          var backgroundLuminance = relativeLuminance(background);
          if (backgroundLuminance > 0.5) {
            var textLuminance = representativeTextLuminance(inner);
            shouldIntervene = textLuminance === null || textLuminance < backgroundLuminance;
            // Task #112 (実機報告続報 — 明るい背景を持つ実メールでも本文が
            // 沈む再現): `representativeTextLuminance` は文書順で最初に
            // 見つかった非空白テキストノード最大6件の平均でしかない。
            // readdle.eml のような「上部にヒーロー見出し (白文字・写真背景)
            // → その後に本文段落 (#333333 系の暗色文字)」という構成の
            // メールでは、その6件の大半または全部がヒーロー側の明るい文字
            // に偏り、後続の暗色本文が一度もサンプリングされないまま
            // 「介入不要」に確定してしまっていた — Task #98/#104 で追加した
            // `explicitDarkTextIsMajority` (可視テキスト全体を文字数ベースで
            // 走査する、こちらの方が頑健) はこれまで背景が見つからない
            // (`else`側) ケースのフォールバックとしてしか呼ばれておらず、
            // 背景ありのこの分岐には一度も届いていなかった — Task #104 の
            // 修正が実際には多くの実メール (背景色を持つのが普通) で
            // 効いていなかった根本原因。6サンプル平均が「介入不要」と
            // 出た場合のみ、同じ全文走査をここでもフォールバックとして
            // 試す。
            if (!shouldIntervene) {
              shouldIntervene = explicitDarkTextIsMajority(inner);
            }
          }
        } else {
          // Task #56 (実機フィードバック: TestFlight通知メール — 背景色を
          // 一切指定せず、文字色だけ #444 系の濃色で明示指定しているメール
          // がダークモードで暗地に暗文字になり読めなかった): 背景が最後まで
          // 解決しない (=`findEffectiveBackground`がnullを返す) からといって
          // 「介入不要」で確定させず、実測した代表的な文字色の輝度が低い
          // (暗い) ときだけ追加で介入する。判定の鍵は「文字色を明示指定して
          // いないメール (32番フィクスチャ) では `color: CanvasText`
          // (このファイル自身のCSSリセット) がダークモード中は既に明るい色
          // へ自動解決されている」という事実 — `getComputedStyle(...).color`
          // で実測すれば、CanvasText由来の明るい文字色と、著者が明示指定した
          // 暗い文字色は輝度の実測値だけで区別でき、どちらのケースかを別途
          // 覚えておく仕組みは要らない (32番フィクスチャがこの分岐に入って
          // しまわないことは、WKWebViewでの実測で確認済み — ダークモード中の
          // CanvasTextの輝度は1.0、著者明示の#444は0.058)。背景がそもそも
          // 無い (透明) メールを反転しても、透明ピクセルはCSS `filter:
          // invert()`でもアルファ非対象のため透明のまま (アプリのダーク
          // 背景がそのまま透けて見える) — 効果は文字色 (と、img/videoは
          // 二重反転で打ち消し済みの通り) にしか出ない。ライト維持
          // (Task #80 の新既定) の側は、このケースでも`html`/`body`の
          // 背景を白へ強制するCSSが効くので、透明のままにはならない。
          var textLuminance = representativeTextLuminance(inner);
          shouldIntervene = textLuminance !== null && textLuminance < 0.5;
          // Task #98: only tried as a second-pass fallback when the 6-sample
          // average above didn't already call for intervention — see
          // `explicitDarkTextIsMajority`'s doc comment for why that average
          // can miss a message whose readable-on-white body text doesn't
          // happen to be among the first 6 text nodes in document order.
          if (!shouldIntervene) {
            shouldIntervene = explicitDarkTextIsMajority(inner);
          }
        }
        var shouldInvert = shouldIntervene && preferInvert;
        var shouldKeepLight = shouldIntervene && !preferInvert;
        inner.classList.toggle('otegami-invert-for-dark', shouldInvert);
        // 実機フィードバック (MakerWorld比較 — 右端の白帯・セクション間の
        // 色ムラ): `html.otegami-invert-active`は反転を実際に決めたときだけ
        // 付き、`body`/`html`自身の背景を強制的に透明化するCSS (上の
        // `<style>`) を有効にする。`document.body`自身の背景が「有効な
        // 背景」の発見源だった場合、その色を`#otegami-fit-inner`自身に
        // 移し替える — こうしておかないと、`body`側を透明化した途端に
        // ページ全体の「キャンバス色」そのものが消えてアプリの暗い背景が
        // そのまま透けるだけになり、`#otegami-fit-inner`が変わらず反転
        // フィルタを持っていても対象の色そのものが無くなってしまう。
        // 反転しないと決まった場合は、以前の呼び出し (1iの翻訳後再適用等)
        // で移し替えた値が残っていれば元に戻す。
        document.documentElement.classList.toggle('otegami-invert-active', shouldInvert);
        if (shouldInvert) {
          var bodyOwnBackground = opaqueBackgroundOf(document.body);
          if (bodyOwnBackground && !inner.style.backgroundColor) {
            inner.style.backgroundColor = getComputedStyle(document.body).backgroundColor;
          }
        } else {
          inner.style.backgroundColor = '';
        }
        // Task #80 (新既定): ライト維持は画像・ロゴに一切手を加えない
        // (反転していないので、色を打ち消す必要も白チップを敷く必要も
        // ない) — `html`自身のクラス切り替えだけで済む。
        document.documentElement.classList.toggle('otegami-keep-light-active', shouldKeepLight);
        decideLogoChips(inner, shouldInvert);
      }
      /* 実機フィードバック (MakerWorldロゴが暗背景に沈む): 反転対象の画像の
         うち、内在サイズが小さい (ロゴ/アイコン相当) ものにだけ、読める
         ようにするための白系チップ背景を敷くクラスを付け外しする —
         付与条件のCSS本体は`HTMLDocumentBuilder.wrap`側の`<style>`コメント
         参照。写真本体は大抵もっと大きいサイズで来るため、この閾値
         (200px以下) だけでも実用上ほとんど誤爆しない、という現実的な
         割り切り。 */
      function decideLogoChips(inner, shouldInvert) {
        var images = inner.querySelectorAll('img');
        for (var i = 0; i < images.length; i++) {
          var img = images[i];
          var isLogoSized = shouldInvert && img.naturalWidth > 0 && img.naturalWidth <= 200 && img.naturalHeight > 0 && img.naturalHeight <= 200;
          img.classList.toggle('otegami-invert-logo-chip', isLogoSized);
        }
      }
      function fit() {
        var outer = document.getElementById('otegami-fit-outer');
        var inner = document.getElementById('otegami-fit-inner');
        if (!outer || !inner) { return { otegamiDiagError: 'missing-outer-or-inner' }; }
        inner.style.transform = 'none';
        inner.style.transformOrigin = '';
        inner.style.width = '';
        outer.style.width = '';
        outer.style.height = '';
        var viewportWidth = outer.clientWidth;
        var naturalWidth = Math.max(inner.scrollWidth, inner.offsetWidth);
        var naturalHeight = Math.max(inner.scrollHeight, inner.offsetHeight);
        // Task #58 diagnostic instrumentation (temporary — removed once the
        // root cause is found): every candidate height signal at the moment
        // `fit()` runs, so a real-device repro can be told apart from "scale
        // path never even ran" vs. "scale path ran and picked a too-small
        // height" vs. "no scale needed but something *else* clips the
        // WKWebView's own frame".
        var diag = {
          otegamiDiagViewportWidth: viewportWidth,
          otegamiDiagNaturalWidth: naturalWidth,
          otegamiDiagNaturalHeight: naturalHeight,
          otegamiDiagInnerScrollHeight: inner.scrollHeight,
          otegamiDiagInnerOffsetHeight: inner.offsetHeight,
          otegamiDiagOuterScrollHeight: outer.scrollHeight,
          otegamiDiagOuterClientHeight: outer.clientHeight,
          otegamiDiagBodyScrollHeight: document.body.scrollHeight,
          otegamiDiagDocElScrollHeight: document.documentElement.scrollHeight,
          otegamiDiagWindowInnerHeight: window.innerHeight,
          otegamiDiagWindowInnerWidth: window.innerWidth,
          otegamiDiagScaled: false
        };
        if (!viewportWidth || naturalWidth <= viewportWidth + 1) { return diag; }
        var scale = viewportWidth / naturalWidth;
        inner.style.width = naturalWidth + 'px';
        inner.style.transformOrigin = 'top left';
        inner.style.transform = 'scale(' + scale + ')';
        outer.style.width = viewportWidth + 'px';
        outer.style.height = Math.ceil(naturalHeight * scale) + 'px';
        diag.otegamiDiagScaled = true;
        diag.otegamiDiagScale = scale;
        diag.otegamiDiagOuterHeightSet = Math.ceil(naturalHeight * scale);
        return diag;
      }
      // Task #58 (根治): the actual fix — report this document's real
      // content height back to Swift via the `otegamiHeight` message
      // handler, every time it might have changed. `postHeight` alone
      // (called once, right after `fit()`) covers the common case; the
      // `ResizeObserver` below additionally catches later changes this same
      // script doesn't otherwise revisit — 1i's translation overlay
      // rewriting text nodes (rarely the same pixel height as the original)
      // is the realistic one, but this is deliberately general rather than
      // re-deriving the exact set of callers that might change layout.
      // `data-otegami-height-observer` guards against attaching a second
      // observer on a later `applyFitToWidth` call against the same
      // still-alive document (the 1.5s safety net, or 1i's post-mutation
      // reapply) — `WKWebView.loadHTMLString` always produces a brand-new
      // `document`, so a fresh load never sees this attribute already set.
      //
      // Task #59 (「本文下の空白が過剰」): this used to report
      // `Math.max(document.documentElement.scrollHeight,
      // document.body.scrollHeight)` — the *whole document's* height,
      // which includes `#otegami-bottom-inset-spacer` (`body`'s sibling to
      // `#otegami-fit-outer`, injected only when `bottomContentInset > 0` —
      // see `HTMLDocumentBuilder.wrap`'s doc comment). That was deliberate
      // at the time (Task #58's doc comment above, now superseded):
      // Swift's frame budget had no other way to know the spacer existed.
      // But `HTMLMessageView`'s `bottomContentInset` is always `0` now
      // (Task #59 moved the "leave room for the floating buttons"
      // reservation to `ThreadDetailView`'s own outer `ScrollView`, applied
      // exactly once instead of once per message body — see
      // `MessageView.content`'s doc comment on its HTML branch), so in
      // practice this rarely differs today — but reporting the *whole
      // document* was always measuring the wrong thing conceptually, and
      // silently reintroduces a double-counted blank space the moment any
      // future caller passes a non-zero `bottomContentInset` again. Measure
      // `#otegami-fit-outer` itself instead — the fit-to-width scaffold
      // `fit()` (above) already sizes explicitly to the real, post-scale
      // content box (`outer.style.height`/`outer.style.width` when scaled;
      // its natural laid-out size otherwise) and is a strict sibling of the
      // spacer, never a container for it — so its own
      // `getBoundingClientRect().height` is exactly the core content height,
      // with no spacer (or anything else `body` might ever grow to include)
      // mixed in. Falls back to the old whole-document measurement only if
      // `#otegami-fit-outer` is somehow missing (shouldn't happen — `fit()`
      // above already returns early with a diagnostic error in that case —
      // but this function has no reason to crash over it).
      // Task #64 (根治: 実機報告「HTML本文の最終行が半分欠ける」): walks the
      // "last child" chain from `root` (normally `#otegami-fit-inner`),
      // comparing each level's own rendered bottom edge and keeping the
      // largest one seen. `outer.getBoundingClientRect().height` alone (the
      // previous, Task #58 measurement) trusts `outer`'s own laid-out box —
      // which on this toolchain was observed to sometimes come up a few
      // dozen points short of where the *last line of real content* actually
      // paints (a trailing child's own bottom margin not fully reflected in
      // its ancestor's auto height is the leading suspect, though a WebKit-
      // level layout/paint discrepancy on this specific toolchain can't be
      // ruled out either — this fix doesn't depend on pinning down which).
      // Walking `lastElementChild` is cheap (bounded by DOM depth, not
      // breadth) and `Math.max` at each step is a defensive measure against
      // a last-in-markup child that isn't also the visually lowest one
      // (e.g. an absolutely-positioned or floated element later in the
      // document) — this only ever *increases* the reported height,
      // matching the reported symptom (content cut short), never decreases
      // it below what a correct measurement would already have given.
      function deepestLastBottom(root) {
        var bottom = root.getBoundingClientRect().bottom;
        var el = root.lastElementChild;
        while (el) {
          var rect = el.getBoundingClientRect();
          if (rect.bottom > bottom) { bottom = rect.bottom; }
          el = el.lastElementChild;
        }
        return bottom;
      }
      function postHeight() {
        var outer = document.getElementById('otegami-fit-outer');
        var height;
        if (outer) {
          var outerRect = outer.getBoundingClientRect();
          var inner = document.getElementById('otegami-fit-inner');
          // Task #64: the larger of (a) `outer`'s own measured bottom edge
          // (the previous, sole signal) and (b) the deepest-last-child walk
          // from `inner` — see `deepestLastBottom`'s doc comment. `+ 4`
          // (beyond the `Math.ceil` rounding this already had) is a small,
          // fixed safety margin for exactly this kind of sub-pixel/rounding
          // shortfall — cheap insurance against a one- or two-point clip
          // that would otherwise still shave the very bottom of the last
          // line, and small enough that it reads as "a hair of breathing
          // room", not a new "空き帯が出る" regression of its own (the
          // `reservedBottomInset` fix right above this file's own doc
          // comment is what actually matters for that report; this `+4` is
          // two orders of magnitude smaller).
          var contentBottom = inner ? deepestLastBottom(inner) : outerRect.bottom;
          var bottom = Math.max(outerRect.bottom, contentBottom);
          height = Math.ceil(bottom - outerRect.top) + 4;
        } else {
          height = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight);
        }
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.otegamiHeight) {
          window.webkit.messageHandlers.otegamiHeight.postMessage(height);
        }
      }
      function ensureHeightObserver() {
        if (document.documentElement.hasAttribute('data-otegami-height-observer')) { return; }
        document.documentElement.setAttribute('data-otegami-height-observer', '1');
        if (typeof ResizeObserver === 'undefined') { return; }
        var scheduled = false;
        var observer = new ResizeObserver(function () {
          if (scheduled) { return; }
          scheduled = true;
          requestAnimationFrame(function () { scheduled = false; postHeight(); });
        });
        observer.observe(document.documentElement);
      }
      return waitForImages().then(function () {
        decideDarkInversion();
        // Task #58 diagnostic instrumentation (temporary): stash the
        // measurement into a DOM attribute instead of returning it —
        // `evaluateJavaScript` (both the closure-completion-handler overload
        // *and* the `async` one) fails with WKErrorDomain Code=5
        // "JavaScript execution returned a result of an unsupported type"
        // for *any* value resolved via this script's Promise chain, on this
        // toolchain/simulator — confirmed with both overloads, and even for
        // a trivial JSON string. A later, wholly separate, plain synchronous
        // `evaluateJavaScript` call (no Promise involved) reads this
        // attribute back and *does* bridge successfully — the same shape
        // `HTMLTranslationController.extractTranslatableTexts()`'s working
        // synchronous IIFE already relies on elsewhere in this file — so the
        // bug is specific to bridging a Promise-resolved value, not to
        // complex values in general.
        document.documentElement.setAttribute('data-otegami-diag', JSON.stringify(fit()));
        postHeight();
        ensureHeightObserver();
      });
    })();
    """

    /// Task #58 diagnostic instrumentation (temporary): reads back whatever
    /// `fitToWidthScript` stashed into `data-otegami-diag` — see that
    /// script's doc comment for why this indirection (rather than just
    /// returning the value from `fitToWidthScript` itself) is needed on this
    /// toolchain. Plain and synchronous (no `Promise`), which is what makes
    /// this one actually bridge back through `evaluateJavaScript`.
    private static let readDiagScript = "document.documentElement.getAttribute('data-otegami-diag');"

    /// Task #58 diagnostic instrumentation (temporary): logs whatever
    /// `readDiagScript` reads back via `Logger` so a `simctl spawn ... log
    /// show` capture during a real-device-style repro shows the exact
    /// numbers `fit()` measured — see `fitToWidthScript`'s doc comment for
    /// what each field means. Removed once Task #58's root cause is
    /// confirmed and fixed.
    private static let diagnosticLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLHeightDiagnostic")

    /// Task #58 (根治): the `WKScriptMessageHandler` name `fitToWidthScript`'s
    /// `postHeight()` posts to — registered on `webView.configuration
    /// .userContentController` by both `HTMLWebViewRepresentable.makeUIView`/
    /// `makeNSView`. A message handler is a separate, independent channel
    /// from `evaluateJavaScript`'s own return-value bridging (the thing
    /// that's broken for Promise-resolved values on this toolchain — see
    /// `fitToWidthScript`'s doc comment) — confirmed reliable in this same
    /// investigation, which is why the actual fix uses it instead of trying
    /// to work around the return-value bug.
    static let heightMessageHandlerName = "otegamiHeight"

    fileprivate static func applyFitToWidth(to webView: WKWebView) {
        // Task #80 (チラつき根絶): `fitToWidthScript` is an IIFE that
        // returns a `Promise` (`waitForImages().then(...)`, doc comment
        // above `fitToWidthScript` covers why) — `evaluateJavaScript(_:
        // completionHandler:)` genuinely waits for that promise to settle
        // before invoking its completion handler, exactly the behavior this
        // reveal needs: by the time this closure runs, `decideDarkInversion()`
        // has already decided "keep light" / "invert" / "do nothing" *and*
        // `fit()`/`postHeight()` have already run, so revealing here can
        // never show a frame that's still mid-decision. The completion
        // handler still fires (with an error) even though bridging the
        // resolved value itself is broken on this toolchain (this same
        // method's diagnostic `Task` below documents that bug) — this
        // reveal only cares that the closure *ran*, never about `error` or
        // the (discarded) result, so that bug doesn't affect it.
        webView.evaluateJavaScript(fitToWidthScript) { [weak webView] _, _ in
            guard let webView else { return }
            revealIfNeeded(webView)
        }
        // Task #58 diagnostic instrumentation (temporary) — see
        // `readDiagScript`'s doc comment. A short fixed delay (not a retry
        // loop) is good enough here: this whole call is diagnostics-only,
        // triggered from a controlled repro, not something that needs to be
        // robust against arbitrary timing the way the real fit-to-width path
        // does.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            do {
                let result = try await webView.evaluateJavaScript(readDiagScript)
                diagnosticLogger.notice("fitToWidth diag: \(String(describing: result), privacy: .public); webView.bounds=\(String(describing: webView.bounds), privacy: .public); webView.frame=\(String(describing: webView.frame), privacy: .public)")
            } catch {
                diagnosticLogger.error("fitToWidth diag read failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Task #80 (チラつき根絶): reveals `webView` (`HTMLWebViewRepresentable
    /// .makeUIView`/`makeNSView` sets `alpha`/`alphaValue = 0` right after
    /// creating it) with a short fade — called every time `applyFitToWidth`'s
    /// promise settles (initial `didFinish`, the 1.5s safety net, and 1i's
    /// post-mutation reapply via `HTMLTranslationController`), not just
    /// once: the `alpha < 1` guard makes every call after the first a cheap,
    /// harmless no-op, so there's no need to track "have we revealed yet"
    /// as separate state. Also called from `didFail`/`didFailProvisionalNavigation`
    /// below as a safety net for the case `didFinish` never fires at all
    /// (a real navigation failure) — this view must never stay permanently
    /// invisible.
    private static func revealIfNeeded(_ webView: WKWebView) {
        #if os(iOS)
        guard webView.alpha < 1 else { return }
        UIView.animate(withDuration: 0.15) { webView.alpha = 1 }
        #elseif os(macOS)
        guard webView.alphaValue < 1 else { return }
        webView.animator().alphaValue = 1
        #endif
    }

    /// `WKNavigationDelegate`'s "load finished" callback — fires once per
    /// `loadHTMLString(_:baseURL:)` call (`load(html:...)` above), the only
    /// kind of navigation this app's own code ever initiates (a stray tapped-
    /// link navigation never reaches `didFinish` as a *successful* main-
    /// frame load in the way that matters here, since `decidePolicyFor`
    /// cancels it first). A single call is enough now that `fitToWidthScript`
    /// itself awaits every still-loading `<img>` before measuring (see its
    /// doc comment) — the previous "run once immediately, run again after a
    /// blind 0.3s" pair was papering over exactly that race without actually
    /// closing it. One more delayed call is kept purely as a cheap safety
    /// net for layout settling unrelated to image loads (e.g. web fonts,
    /// though this app doesn't currently inject any) — not expected to
    /// change the result in the common case.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.applyFitToWidth(to: webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak webView] in
            guard let webView else { return }
            Self.applyFitToWidth(to: webView)
        }
    }

    /// Task #80 (チラつき根絶) safety net: `applyFitToWidth`'s reveal only
    /// ever fires once `didFinish` actually happens — a genuine navigation
    /// failure (rare for this app's own trusted `loadHTMLString`, but not
    /// impossible) would otherwise leave the web view permanently hidden at
    /// `alpha`/`alphaValue == 0` with no further callback ever arriving to
    /// undo that. Revealing here regardless of what actually failed to load
    /// is the right call — showing whatever partial/blank content resulted
    /// is strictly better than an invisible message view a user can't tell
    /// apart from "still loading" forever.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.revealIfNeeded(webView)
    }

    /// Task #80 — see `didFail(navigation:withError:)` just above; same
    /// reasoning, the other WebKit failure callback shape.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.revealIfNeeded(webView)
    }

    /// Decides every navigation this web view ever sees — main frame and
    /// subframe alike. **Deliberately does not branch on
    /// `navigationAction.navigationType`, and never allows a main-frame
    /// navigation through this method at all** — two real-simulator
    /// findings building C7 forced both departures from a more "obvious"
    /// implementation:
    ///
    /// 1. The original implementation allowed exactly `.other`-typed
    ///    navigations, on the assumption that's what the trusted initial
    ///    `loadHTMLString(_:baseURL:)` call is classified as. A synthesized
    ///    tap on a plain `<a href="https://...">` link turned out to *also*
    ///    reach this method with a main-frame navigation that got allowed
    ///    through — confirmed by screenshot: the tapped link's page loaded
    ///    in place inside this same `WKWebView`.
    /// 2. Tracking "is a programmatic load outstanding" with a flag set
    ///    right before every `loadHTMLString` call (an earlier attempt at
    ///    fixing this) didn't help either, and pointed at the real
    ///    explanation: `loadHTMLString(_:baseURL:)` apparently **never
    ///    reaches `decidePolicyFor` at all** in this WebKit version — it's
    ///    not a real `URLRequest`-backed navigation, so there's nothing for
    ///    the navigation-policy pipeline to decide. The flag was therefore
    ///    never consumed by the load it was meant to guard, and sat `true`
    ///    until the *next* navigation — the link tap — consumed it instead
    ///    and got waved through as if it were the trusted load.
    ///
    /// Given `loadHTMLString` itself never shows up here, the correct rule
    /// is simply: **no main-frame navigation this method ever sees is the
    /// initial render** — every one is something else (a link tap, a
    /// redirect, ...) and gets cancelled unconditionally, forwarding
    /// `http`/`https` targets to `onOpenLink` (C7's browser choice).
    ///
    /// Subframe navigations (`targetFrame?.isMainFrame == false` — e.g. an
    /// `<iframe src>`'s own declarative load) are allowed through
    /// unconditionally: whether that resource actually loads is entirely
    /// gated by the `WKContentRuleList` (`applyContentRuleList`, keyed to
    /// `allowsExternalContent`) at the network level, independent of this
    /// method — same "外部画像ブロックとは独立に動く" design already documented
    /// for `cid:` images. JavaScript stays disabled webview-wide
    /// (`allowsContentJavaScript = false` on `defaultWebpagePreferences`)
    /// regardless of any of this, so an allowed subframe navigation still
    /// can't execute script.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            onOpenLink(url)
        }
    }
}

/// Task #58 (根治): receives the real content height `fitToWidthScript`'s
/// `postHeight()` posts to `HTMLWebViewCoordinator.heightMessageHandlerName`.
/// `message.body` is whatever JSON-compatible value `postMessage` was
/// called with — a plain JS number bridges to `NSNumber` here (unlike the
/// Promise-return-value bridging bug `fitToWidthScript`'s doc comment
/// documents; this is an entirely different WebKit code path and isn't
/// affected by it).
extension HTMLWebViewCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.heightMessageHandlerName, let height = (message.body as? NSNumber)?.doubleValue, height.isFinite, height > 0 else { return }
        onHeightChange(CGFloat(height))
    }
}

extension HTMLWebViewCoordinator: WKUIDelegate {
    /// C7 バグ修正 (リンクがブラウザで開かない):
    /// `target="_blank"`／`rel="noopener"`のような「新しいウィンドウ/タブで
    /// 開く」リンクは、`navigationAction.targetFrame`が`nil`になる —
    /// `decidePolicyFor`の`isMainFrame`判定は`navigationAction.targetFrame?
    /// .isMainFrame ?? true`なので理屈の上ではこの`nil`ケースも「メイン
    /// フレーム扱い」でキャンセルされ`onOpenLink`に回るはずだが、この
    /// WebKitバージョン/実機でその通りに動く保証はない —
    /// `loadHTMLString`が`decidePolicyFor`に一切現れないという、この
    /// ファイルの別の実測済みの驚き (同メソッドのdoc comment) が示すとおり、
    /// このAPIの実際の挙動は文書化された仕様と食い違うことがある。
    /// `WKUIDelegate`を一切実装していなかった (=`webView.uiDelegate`が
    /// `nil`のまま) 場合、新しいウィンドウを要求するナビゲーションが
    /// `decidePolicyFor`を素通りしてここへ来ると、行き先がなく黙って
    /// 何も起きない — メールの「アプリで見る」「配信停止はこちら」等、
    /// 実際のメールに頻出する`target="_blank"`リンクがまさにこのパターン。
    /// このメソッド自体は新しい`WKWebView`を一切作らず (常に`nil`を返す)、
    /// 対象URLを`decidePolicyFor`と全く同じ経路 (`onOpenLink`) に渡すだけ —
    /// 「新しいウィンドウでHTMLを表示する」ためのUI自体をこのアプリは持たない
    /// (リンクは常にブラウザ側で開く) ので、これで十分。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            onOpenLink(url)
        }
        return nil
    }
}
