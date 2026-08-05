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
    /// 送信者別のリモート画像許可 (`SenderImageAllowlistStore`) の判定キー。
    /// `MessageRecord.fromAddresses` の先頭アドレス。`nil` (メッセージ
    /// レコード未ロード等) なら送信者別の許可・「常に表示」メニュー項目とも
    /// 無効になるだけで、従来のバナー挙動はそのまま。
    let senderAddress: String?
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
    /// Task #207 (ユーザー要望「(平文httpの画像を)許可する方針でいいが、
    /// 確認ダイアログは出してほしい」): `allowsExternalContent`(B6、
    /// リモート画像全般の可否) とは独立した、平文`http`だけの追加ゲート。
    /// `allowsExternalContent`が false の間はそもそもリモート画像全部が
    /// ブロックされておりこのフラグは無関係 (下の`shouldOfferPlaintextHTTP
    /// Images`参照) — `allowsExternalContent`が true になって初めて意味を
    /// 持つ。他の2つの画像フラグと同じ「メッセージを開くたびに`init`で
    /// 現在の設定を読み直す」パターンだが、こちらは`ImageSettingsStore
    /// .plaintextHTTPImagePolicyKey`が`.alwaysAllow`の場合だけ`true`で
    /// 始まる (既定`.ask`では常に`false`で始まり、確認ダイアログで
    /// 明示的に許可されるまでブロックのまま)。
    @State private var allowsPlaintextHTTPImages: Bool
    /// Task #207: 上の`allowsPlaintextHTTPImages`の初期値を決めるのに使った
    /// のと同じ設定値 — バナー/ダイアログを出すかどうかの分岐
    /// (`shouldOfferPlaintextHTTPImages`) にも必要なので保持しておく
    /// (`.alwaysBlock`はバナーごと出さない、`.alwaysAllow`は最初から
    /// ブロックされていないのでバナーの出番がない)。
    @State private var plaintextHTTPImagePolicy: PlaintextHTTPImagePolicy
    /// Task #207: 「保護されていない画像を確認」バナーをタップしたときだけ
    /// `true`になる (`.alert(isPresented:)`)。
    @State private var showPlaintextHTTPImagesAlert = false
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
        senderAddress: String? = nil,
        bottomContentInset: CGFloat = 0,
        translatedTexts: [String]? = nil, showOriginalText: Bool = false,
        onTranslationControllerReady: @escaping (HTMLTranslationController?) -> Void = { _ in },
        onHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.html = html
        self.accountId = accountId
        self.messageId = messageId
        self.mailboxPath = mailboxPath
        self.senderAddress = senderAddress
        self.bottomContentInset = bottomContentInset
        self.translatedTexts = translatedTexts
        self.showOriginalText = showOriginalText
        self.onTranslationControllerReady = onTranslationControllerReady
        self.onHeightChange = onHeightChange
        // 送信者別許可 (`SenderImageAllowlistStore`) は B5/B6 設定より優先 —
        // 「この送信者の画像を常に表示」を選んだ相手からのメールは、
        // グローバル設定がオフでも最初から画像 (埋め込み・リモートとも) を
        // 表示する (両方に効く理由は `allowSenderAlwaysMenuItem` の
        // doc comment 参照)。
        let senderAllowed = senderAddress.map { SenderImageAllowlistStore.contains($0) } ?? false
        _allowsExternalContent = State(initialValue: senderAllowed || UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowRemoteImagesKey))
        _allowsEmbeddedImages = State(initialValue: senderAllowed || UserDefaults.standard.bool(forKey: ImageSettingsStore.autoShowEmbeddedImagesKey))
        let plaintextHTTPImagePolicyRaw = UserDefaults.standard.string(forKey: ImageSettingsStore.plaintextHTTPImagePolicyKey)
        let plaintextHTTPImagePolicy = plaintextHTTPImagePolicyRaw.flatMap(PlaintextHTTPImagePolicy.init(rawValue:)) ?? ImageSettingsStore.defaultPlaintextHTTPImagePolicy
        _plaintextHTTPImagePolicy = State(initialValue: plaintextHTTPImagePolicy)
        _allowsPlaintextHTTPImages = State(initialValue: plaintextHTTPImagePolicy == .alwaysAllow)
        _autoAdjustColorsInDarkMode = State(initialValue: UserDefaults.standard.bool(forKey: HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey))
        _forceLightBackground = State(initialValue: UserDefaults.standard.bool(forKey: HTMLDisplaySettingsStore.forceLightBackgroundKey))
    }

    private var hasExternalContent: Bool {
        HTMLExternalResourceScanner.containsExternalResource(html: html)
    }

    private var hasEmbeddedContent: Bool {
        CIDURLRewriter.containsCIDReference(html: html)
    }

    /// Task #207: `HTMLExternalResourceScanner.containsPlaintextHTTPImage`
    /// のdoc comment参照 — `hasExternalContent`(上、`href`も含む広い判定)
    /// とは別の、画像限定・httpのみの狭い判定。
    private var hasPlaintextHTTPContent: Bool {
        HTMLExternalResourceScanner.containsPlaintextHTTPImage(html: html)
    }

    /// Task #207: 「保護されていない画像を確認」バナー (下の
    /// `plaintextHTTPImagesBanner`) を出すかどうか。`allowsExternalContent`
    /// が false の間は既存の`imagesBanner`(「画像を表示」) がリモート画像
    /// 全部を覆っており、平文httpだけを個別に案内する意味が無い (むしろ
    /// 二重にバナーが並んで紛らわしい) ので対象外。`.alwaysBlock`は
    /// 「常に拒否」を選んだ人への配慮 — 毎回バナーで催促し続けない
    /// (`PlaintextHTTPImagePolicy`のdoc comment参照)。
    private var shouldOfferPlaintextHTTPImages: Bool {
        hasPlaintextHTTPContent
            && allowsExternalContent
            && !allowsPlaintextHTTPImages
            && plaintextHTTPImagePolicy != .alwaysBlock
    }

    /// Task #207: 既存の`imagesBanner`(下) とは意図的に別立てのバナー —
    /// 埋め込み/リモートの2択`Menu`にこれを混ぜると「安全でない接続の
    /// 警告」という異なる重みの選択肢が並んでしまい紛れる。タップしても
    /// 即座には許可せず、`.alert`(下の`body`) を開くだけ — 「確認ダイア
    /// ログを出してほしい」というユーザー要望どおり、実際の許可は
    /// ダイアログでの明示的な「読み込む」操作を経由する。
    @ViewBuilder
    private var plaintextHTTPImagesBanner: some View {
        if shouldOfferPlaintextHTTPImages {
            Button {
                showPlaintextHTTPImagesAlert = true
            } label: {
                Label("保護されていない画像を確認", systemImage: "exclamationmark.shield")
            }
            .buttonStyle(.bordered)
            .tint(OtegamiColor.destructive)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showPlaintextHTTPImagesBanner")
        }
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
            bothImagesBlockedBanner
        } else if isEmbeddedImagesBlocked {
            embeddedImagesBlockedBanner
        } else if isExternalImagesBlocked {
            externalImagesBlockedBanner
        }
    }

    private var bothImagesBlockedBanner: some View {
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
            allowSenderAlwaysMenuItem
        } label: {
            Label("画像を表示", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityIdentifier("messageDetail.showImagesBanner")
    }

    /// 実機報告「『この送信者の画像を常に表示』が見当たらない」対応: 既定
    /// 設定 (埋め込み=オフ / リモート=自動読み込みオン) では実機で普段
    /// 出るバナーはこちら (埋め込みのみブロック) なのに、初版は
    /// リモート側の分岐だけを Menu 化していて、この分岐は従来の即時表示
    /// ボタンのままだった。送信者別許可は埋め込み・リモートの区別なく
    /// 「この送信者の画像」全般に効く仕様 (`allowSenderAlwaysMenuItem`)
    /// なので、この分岐も同じ2択 Menu にする。`senderAddress` が取れない
    /// メールは従来どおり即時表示ボタン。
    @ViewBuilder
    private var embeddedImagesBlockedBanner: some View {
        if senderAddress != nil {
            Menu {
                Button {
                    allowsEmbeddedImages = true
                } label: {
                    Label("このメールの画像を表示", systemImage: "photo")
                }
                .accessibilityIdentifier("messageDetail.imagesBanner.showEmbeddedOnce")
                allowSenderAlwaysMenuItem
            } label: {
                Label("埋め込み画像を表示", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showEmbeddedImagesBanner")
        } else {
            Button {
                allowsEmbeddedImages = true
            } label: {
                Label("埋め込み画像を表示", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showEmbeddedImagesBanner")
        }
    }

    /// ユーザー要望「『この送信者の画像は必ず開く』みたいな選択ができる
    /// ように」: 送信者アドレスが分かるメールでは、従来の即時表示ボタンを
    /// Menu に置き換えて「このメールだけ」と「この送信者は常に」の2択に
    /// する。識別子は従来のボタンと同じ `messageDetail.showImagesBanner`
    /// を維持 (XCUITest は `exists` 確認のみ — `OtegamiM8CIDImageUITests`)。
    /// `senderAddress` が取れないメールでは従来どおり即時表示ボタンのまま。
    @ViewBuilder
    private var externalImagesBlockedBanner: some View {
        if senderAddress != nil {
            Menu {
                Button {
                    allowsExternalContent = true
                } label: {
                    Label("このメールの画像を表示", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("messageDetail.imagesBanner.showRemoteOnce")
                allowSenderAlwaysMenuItem
            } label: {
                Label("画像を表示", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 4)
            .accessibilityIdentifier("messageDetail.showImagesBanner")
        } else {
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

    /// 「この送信者の画像を常に表示」— `SenderImageAllowlistStore` に登録
    /// して以降このアドレスからのメールは画像 (埋め込み・リモートとも) を
    /// 自動表示する。埋め込みも含めるのは、許可の単位が「この送信者」で
    /// あって画像の取得経路ではないため — ユーザーが送信者を信頼する意思
    /// 表示をしたのに cid: 添付だけ毎回ブロックされ続けるのは意図に反する。
    /// 解除は設定 →「メールビューア」→「画像」の許可リストから
    /// (`MailViewerSettingsView`)。`senderAddress` が無ければ項目ごと出さない。
    @ViewBuilder
    private var allowSenderAlwaysMenuItem: some View {
        if let senderAddress {
            Button {
                SenderImageAllowlistStore.add(senderAddress)
                allowsExternalContent = true
                allowsEmbeddedImages = true
            } label: {
                Label("この送信者の画像を常に表示", systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityIdentifier("messageDetail.imagesBanner.allowSenderAlways")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imagesBanner

            plaintextHTTPImagesBanner

            HTMLWebViewRepresentable(
                html: html,
                allowsExternalContent: allowsExternalContent,
                allowsEmbeddedImages: allowsEmbeddedImages,
                allowsPlaintextHTTPImages: allowsPlaintextHTTPImages,
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
        // Task #207 (ユーザー要望「『http の画像があるけどいい?』的な確認
        // ダイアログは出してほしい」): Task #190 が「一括操作の実行前確認」
        // を`.confirmationDialog`(iPad/macOSでポップオーバー化する) から
        // `.alert`(常に画面中央のモーダル) へ差し替えた方針に揃える —
        // 平文httpの画像読み込みも「経路上で改竄されうる」という安全性に
        // 関わる確認である点は同じで、吹き出しよりも中央モーダルの方が
        // 見落としにくい。許可の範囲は既存の「画像を表示」バナー
        // (`allowsExternalContent`/`allowsEmbeddedImages`) と同じ「この
        // メールだけ、このアプリセッション中」— このビューの`@State`は
        // メッセージを開くたびに`init`から作り直されるので、別のメールを
        // 開く/アプリを再起動すると自然に既定(`plaintextHTTPImagePolicy`)
        // に戻る。
        .alert(
            "保護されていない接続の画像を読み込みますか？",
            isPresented: $showPlaintextHTTPImagesAlert
        ) {
            Button("読み込む") { allowsPlaintextHTTPImages = true }
                .accessibilityIdentifier("messageDetail.plaintextHTTPImagesAlert.load")
            Button("キャンセル", role: .cancel) {}
                .accessibilityIdentifier("messageDetail.plaintextHTTPImagesAlert.cancel")
        } message: {
            Text("このメールには暗号化されていない接続 (http) で読み込む画像が含まれています。通信内容は経路上で書き換えられる可能性があります。")
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

/// `HTMLMessageView`'s `.task(id:)` re-application key — see its call site's
/// doc comment. A plain `Equatable` struct (not `Hashable`; `.task(id:)`
/// only requires `Equatable`) so SwiftUI can tell "the translation display
/// state genuinely changed" apart from "this view just re-rendered for an
/// unrelated reason" without restarting the task on every body evaluation.
private struct HTMLTranslationDisplayKey: Equatable {
    let showOriginal: Bool
    let translatedTexts: [String]?
}
