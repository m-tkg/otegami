import SwiftUI
import WebKit
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine
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

    @Environment(AppEnvironment.self) private var environment
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

    init(html: String, accountId: String, messageId: Int64, mailboxPath: String?) {
        self.html = html
        self.accountId = accountId
        self.messageId = messageId
        self.mailboxPath = mailboxPath
        _allowsExternalContent = State(initialValue: UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowRemoteImagesKey))
        _allowsEmbeddedImages = State(initialValue: UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowEmbeddedImagesKey))
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
                cidContext: CIDResolutionContext(
                    environment: environment, accountId: accountId, messageId: messageId, mailboxPath: mailboxPath
                ),
                onOpenLink: handleLinkTap
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
    static func wrap(bodyHTML: String) -> String {
        let innerBody = extractBodyContent(from: bodyHTML)
        let originalHeadStyles = extractHeadStyles(from: bodyHTML)
        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=yes">
        <meta charset="utf-8">
        <style>
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
          * { max-width: 100% !important; box-sizing: border-box; }
          img, video, table, iframe { max-width: 100% !important; height: auto !important; }
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
        </style>
        \(originalHeadStyles)
        </head>
        <body>\(innerBody)</body>
        </html>
        """
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

#if os(iOS)
import UIKit

struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    let allowsExternalContent: Bool
    let allowsEmbeddedImages: Bool
    let cidContext: CIDResolutionContext
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
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
        context.coordinator.load(html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
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
    let cidContext: CIDResolutionContext
    let onOpenLink: (URL) -> Void

    func makeCoordinator() -> HTMLWebViewCoordinator { HTMLWebViewCoordinator(cidContext: cidContext, onOpenLink: onOpenLink) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeWebViewConfiguration(cidHandler: context.coordinator.cidHandler))
        webView.navigationDelegate = context.coordinator
        // C7 バグ修正 — `allowsLinkPreview`はiOS専用のプロパティなので
        // macOSにはない。`target="_blank"`リンクの取りこぼし対策の
        // `uiDelegate`はプラットフォーム共通で必要なので、iOS側と同じく
        // ここでも設定する。
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.load(html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.reloadIfNeeded(
            html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages,
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

    init(cidContext: CIDResolutionContext, onOpenLink: @escaping (URL) -> Void) {
        self.cidHandler = CIDSchemeHandler(context: cidContext)
        self.onOpenLink = onOpenLink
    }

    private var lastLoadedHTML: String?
    private var lastAllowsExternalContent: Bool?
    private var lastAllowsEmbeddedImages: Bool?

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
            load(html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages, into: webView)
        }
        onOpenLink(url)
    }

    func reloadIfNeeded(
        html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool,
        cidContext: CIDResolutionContext, into webView: WKWebView
    ) {
        cidHandler?.updateContext(cidContext)
        guard html != lastLoadedHTML
            || allowsExternalContent != lastAllowsExternalContent
            || allowsEmbeddedImages != lastAllowsEmbeddedImages
        else { return }
        load(html: html, allowsExternalContent: allowsExternalContent, allowsEmbeddedImages: allowsEmbeddedImages, into: webView)
    }

    func load(html: String, allowsExternalContent: Bool, allowsEmbeddedImages: Bool, into webView: WKWebView) {
        observeStrayNavigations(on: webView)
        lastLoadedHTML = html
        lastAllowsExternalContent = allowsExternalContent
        lastAllowsEmbeddedImages = allowsEmbeddedImages

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
        let document = HTMLDocumentBuilder.wrap(bodyHTML: cidRewrittenHTML)

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
