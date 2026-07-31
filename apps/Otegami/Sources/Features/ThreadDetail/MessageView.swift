import Foundation
import SwiftUI
import QuickLook
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import GRDB
import OtegamiTranslation
import OtegamiTranslationApple
import TranslationEngine
import os

/// Single-message reading view (M2's "ThreadDetail"; real multi-message
/// thread collapsing lands in M4). Shows the header, then the body: if
/// `message.bodyState` is already `.fetched`, reads straight from
/// `messageBody` (works offline); otherwise fetches it over IMAP via
/// `SyncCoordinator.fetchBody`, showing a spinner meanwhile.
///
/// Takes `messageId` rather than an already-loaded `MessageRecord`: the id
/// is what `MessageListView`'s `List(selection:)` binding (and `RootView`'s
/// "last opened message" restoration) naturally deal in, and re-reading
/// the row here means this view always reflects the current database state
/// (e.g. a flag change from another source) rather than a snapshot passed
/// in at selection time.
struct MessageView: View {
    @Environment(AppEnvironment.self) var environment
    /// Which account to authenticate against for a lazy body fetch —
    /// derived from `message.mailboxId` for everything else (M4: a message
    /// embedded in `ThreadDetailView` doesn't necessarily belong to
    /// whichever mailbox the sidebar has selected, e.g. the unified inbox
    /// or a thread that spans mailboxes), so this is the one piece of
    /// context a caller must still supply.
    let accountId: String
    let messageId: Int64
    /// Task #59 (「本文下の空白が過剰」): the height `ThreadMessageRow`
    /// wants `content`'s HTML branch given explicitly — `measuredHTMLContentHeight`,
    /// its own `@State` this view's `onHTMLContentHeightChange` (below)
    /// last reported, handed straight back down. `nil` (the default, and
    /// always true for a plain-text message, which never reports one)
    /// means `content` keeps its old `maxHeight: .infinity` behavior,
    /// relying on whatever fixed frame the caller imposes on this whole
    /// view instead (`ThreadMessageRow`'s `expandedHeight` fallback). Once
    /// non-`nil`, `content` sizes to exactly this value and this view stops
    /// needing an externally-imposed total height at all — see `body`'s
    /// `content` call and `ThreadMessageRow.body`'s `.frame(height:)` for
    /// the two sides of this "WebView gets its exact measured height, every
    /// other element sizes itself, `VStack` sums them" arrangement.
    var contentHeight: CGFloat?
    /// Task #58 (根治): reports an HTML message's real, full content height
    /// once `HTMLMessageView`'s `WKWebView` measures it — `ThreadMessageRow`
    /// (`ThreadDetailView.swift`) is the actual caller, and uses this to
    /// size the fixed-height budget it gives this whole view to match real
    /// content instead of a constant that used to silently clip taller
    /// messages. A no-op default so this stays source-compatible for
    /// anything that doesn't care (nothing else currently constructs this
    /// view, but there's no reason to force every future call site to
    /// thread this through). Meaningless for a plain-text message — see
    /// `content`'s HTML branch below for the only place this is ever
    /// actually invoked.
    var onHTMLContentHeightChange: (CGFloat) -> Void = { _ in }
    /// Task #59 (フローティングボタンを画面下部に固定), Task #88 (フッター
    /// ツールバーへ移設): reports the live `MessageDetailAIFeaturesState`
    /// this view populates (`aiState` below) up to `ThreadDetailView`, which
    /// forwards it straight into `MessageDetailFooterToolbar`'s
    /// `aiFeaturesState` parameter — non-`nil` while this view is on screen
    /// (`onAppear`), `nil` once it's torn down (`onDisappear`, e.g. the
    /// accordion collapses this row). See `MessageDetailAIFeaturesState`'s
    /// doc comment for why the buttons themselves had to move out of this
    /// view's own `overlay` in the first place. Same no-op default /
    /// "nothing else currently constructs this view" reasoning as
    /// `onHTMLContentHeightChange` above.
    var onAIFeaturesStateChange: (MessageDetailAIFeaturesState?) -> Void = { _ in }
    /// Task #149 (実機報告「スレッド表示で要約/翻訳ボタンが一瞬有効→無効に
    /// 戻る」): whether *this* instance is the one `ThreadDetailView.
    /// expandedAIFeaturesState` (and therefore the footer toolbar) should
    /// currently be reflecting — `ThreadMessageRow`/`ThreadDetailView.
    /// messageRow(for:containerSize:)` compute this as `expandedMessageId ==
    /// 自 messageId`, mirroring `isExpanded` exactly. Root cause: the
    /// accordion is a strict "one `MessageView` at a time" model in theory,
    /// but in practice several instances can be alive simultaneously for a
    /// brief window — the newly-expanding row's fresh `MessageView`, the
    /// just-collapsed row's own instance lingering mid-`withAnimation`
    /// removal (SwiftUI doesn't call `onDisappear` until that animation
    /// settles, yet its `.task`/`.onChange` machinery keeps running the
    /// whole time), and Task #147's `observeBodyRecordChanges()` loop on
    /// that same lingering instance possibly delivering one more body
    /// update before it's actually torn down. All of them used to call the
    /// exact same unconditional `onAIFeaturesStateChange` closure
    /// (`{ expandedAIFeaturesState = $0 }`), so whichever one happened to
    /// run *last* won — commonly the stale collapsing instance's
    /// `onDisappear` (`nil`) or #147 delivery (its own, wrong-message
    /// `aiState`), landing *after* the newly-expanded instance had already
    /// reported correctly, which is exactly "一瞬有効→無効" (briefly
    /// correct, then clobbered).
    ///
    /// This flag is this view's own first line of defense: every write into
    /// `onAIFeaturesStateChange` below is gated on it, so a non-target
    /// instance simply never calls out at all (only touches its own local
    /// `aiState`, harmless since nothing reads it while non-target). It's
    /// deliberately *not* the only defense, though — see `ThreadDetailView.
    /// messageRow(for:containerSize:)`'s `onAIFeaturesStateChange` closure
    /// doc comment for why a `let` flag frozen at this instance's
    /// construction time can't, by itself, catch a residual instance that
    /// was still the target *when it was created* but no longer is by the
    /// time it actually calls out; that closure adds a second, live check
    /// against `ThreadDetailView`'s own current `expandedMessageId` that
    /// closes that gap regardless of timing. Defaults to `true` — the only
    /// call site (`ThreadMessageRow.body`) always passes an explicit value,
    /// but a permissive default keeps this source-compatible with the same
    /// "nothing else currently constructs this view" reasoning as
    /// `onHTMLContentHeightChange`/`onAIFeaturesStateChange` just above.
    var isToolbarTarget = true

    /// B5 — see `ListDisplaySettingsStore.showAvatarInDetailKey`'s doc
    /// comment on why this is read directly via `@AppStorage`.
    @AppStorage(ListDisplaySettingsStore.showAvatarInDetailKey) private var showAvatarInDetail = ListDisplaySettingsStore.defaultShowAvatarInDetail

    // MARK: - HTML/text display (A9)

    /// A9-2 「常にテキストで表示」 — see `HTMLDisplaySettingsStore`'s doc comment.
    /// This is only the *default*; `manualPreferPlainText` (below) lets a
    /// single open message override it in either direction via the toggle
    /// button next to `HTMLBadge`.
    @AppStorage(HTMLDisplaySettingsStore.alwaysShowPlainTextKey) private var alwaysShowPlainText = HTMLDisplaySettingsStore.defaultAlwaysShowPlainText
    /// `nil` until the toggle button (`toggleHTMLTextButton`) is tapped for
    /// *this* message — reset in `load()` so switching to a different
    /// message never carries a previous message's manual choice forward.
    @State var manualPreferPlainText: Bool?
    /// Task #71「メールの背景を常に白に」— see `HTMLDisplaySettingsStore
    /// .forceLightBackgroundKey`'s doc comment. Forwarded to `HTMLMessageView`
    /// as-is (that view bakes it into the loaded document's own CSS); the
    /// plain-text branches below (`content`) apply the SwiftUI-side
    /// equivalent themselves (`otegamiForceLightBackground(_:)`).
    @AppStorage(HTMLDisplaySettingsStore.forceLightBackgroundKey) private var forceLightBackground = HTMLDisplaySettingsStore.defaultForceLightBackground

    // MARK: - C7 link handling (plain-text body)

    /// "メール内リンクを開くブラウザ" applies to a plain-text body's linkified
    /// `http(s)://` runs too, not just `HTMLMessageView` — see
    /// `LinkBrowserSettingsStore`'s doc comment. SwiftUI's default `Text`
    /// link behavior already matches "デフォルトブラウザ" with no override
    /// needed at all (both platforms), so this only overrides `\.openURL`
    /// when the setting is "アプリ内ブラウザ" (iOS only — `HTMLMessageView
    /// .handleLinkTap`'s doc comment covers why macOS has no equivalent).
    @AppStorage(LinkBrowserSettingsStore.openInAppBrowserKey) private var openInAppBrowser = LinkBrowserSettingsStore.defaultOpenInAppBrowser
    #if os(iOS)
    @State private var presentedSafariURL: IdentifiableURL?
    #endif

    @State var message: MessageRecord?
    @State var bodyRecord: MessageBodyRecord?
    /// M8: the mailbox path `message` lives in — resolved once during
    /// `load()` (same `MailboxRecord` lookup `fetchBodyOverNetwork` already
    /// does for the body itself) and kept around so the attachment section
    /// and `HTMLMessageView`'s cid image resolver don't each need to
    /// re-derive it.
    @State var mailboxPath: String?
    /// Task #151 (「アーカイブ済みの可視化」): whether `message` currently
    /// lives in a mailbox that counts as archived — see `ThreadQuery
    /// .isMessageArchived(messageId:db:)`'s doc comment for the exact
    /// predicate. Loaded once in `load()` alongside `mailboxPath` (both are
    /// derived from the same `message.mailboxId`), and forwarded to
    /// `header(for:)`/`MessageHeaderCompactView`.
    @State var isArchived = false
    @State var isLoading = false
    @State var errorMessage: String?
    @State var attachments: [AttachmentRecord] = []
    /// Task #94: owns the calendar-invite card's own state (ICS download/
    /// parse result, RSVP send-in-flight) independently of
    /// `CalendarInviteSectionView`'s own lifecycle — see
    /// `CalendarInviteLoader`'s doc comment for why that matters.
    @State var calendarInviteLoader = CalendarInviteLoader()
    /// M8: which attachment (by id) is currently being downloaded on-demand
    /// — drives that row's spinner. A `Set` rather than a single optional
    /// id since a user could plausibly tap two attachment rows in quick
    /// succession.
    @State var fetchingAttachmentIds: Set<Int64> = []
    /// M8, per-card since Task #76: keyed by attachment id so a fetch
    /// failure shows on the specific `AttachmentCardRow` that failed rather
    /// than one shared message below the whole list (see
    /// `attachmentSection`'s doc comment).
    @State var attachmentErrorMessages: [Int64: String] = [:]
    /// M8: the attachment currently shown in the `.quickLookPreview` sheet
    /// — `nil` means no preview is presented.
    @State var previewURL: URL?

    // MARK: - Translation (design-phase-3, 1i)

    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール): `syncAIFeaturesState()`'s `showsTranslationButton`
    /// gate has three independent conditions (`bodyRecord != nil`,
    /// `shouldShowTranslationBar`, かつての `htmlControllerReadyIfNeeded`)
    /// and, before this task, none of their individual values were ever
    /// logged — a report of "ボタンが出ない" gave no way to tell *which*
    /// condition was actually false without attaching a debugger. Every call
    /// to `syncAIFeaturesState()` now logs all three (plus the inputs that
    /// feed them: `detectedLanguage`/`isHTMLMessage`/`isShowingHTML`) at
    /// `.debug` — cheap enough to leave on permanently (this runs on every
    /// message open and every AI-features-toggle flip, not just on failure),
    /// and `log stream --predicate 'category == "TranslationGate"'` turns a
    /// "ボタンが出ない" report into an immediate answer instead of a guess.
    private static let translationGateLogger = Logger(subsystem: "com.mtkg.otegami", category: "TranslationGate")

    /// Task #90: real-device follow-up to the Task #62 fix — a report that
    /// summaries could still read like a recap of quoted reply history
    /// ("まだ、要約において過去の引用のみが要約されてたりする") is otherwise
    /// undiagnosable after the fact, since `QuoteStripper`'s split happens
    /// silently and only its *output* (the combined summary source string)
    /// is visible anywhere else. `sourceTextForSummary()` logs, per call,
    /// how many characters landed on each side of the split and which
    /// named marker pattern (`QuoteStripper.SeparatedText.detectedMarker`)
    /// made the cut — "did splitting even fire, and on what" is the first
    /// question any follow-up investigation needs answered from Console.
    private static let summaryInputLogger = Logger(subsystem: "com.mtkg.otegami", category: "SummaryInput")

    /// Task #138 追加報告 (実機「要約ボタンが押せない時がある」):
    /// `translationGateLogger`と同じ理由の`showsSummaryButton`専用ログ — 元の
    /// `aiState.showsSummaryButton = bodyRecord != nil && aiFeaturesEnabled`
    /// には診断ログが一切無く、「押せない」報告から`bodyRecord`が`nil`のまま
    /// なのか`aiFeaturesEnabled`が`false`なのかを切り分ける手段が無かった。
    /// `log stream --predicate 'category == "SummaryGate"'`で
    /// `syncAIFeaturesState()`ごとの状態を追える。
    private static let summaryGateLogger = Logger(subsystem: "com.mtkg.otegami", category: "SummaryGate")

    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) var autoTranslateEnglish = TranslationSettingsStore.defaultAutoTranslateEnglish
    /// I「設定画面の再構成」→「メールビューア」の「AI 機能の on/off (翻訳・要約を
    /// まとめて)」— see `AIFeaturesSettingsStore`'s doc comment. Master
    /// switch for both `TranslationBar` (`shouldShowTranslationBar`) and
    /// `AISummaryBar` (`body`'s `if aiFeaturesEnabled` below).
    @AppStorage(AIFeaturesSettingsStore.enabledKey) var aiFeaturesEnabled = AIFeaturesSettingsStore.defaultEnabled

    // MARK: - AI要約 (表示・操作改善バッチ)

    @State private var summaryTask: Task<Void, Never>?
    /// Task #55: whether the summary sheet (`summarySheet`) is presented —
    /// opened by `aiState.onShowSummary` (called from
    /// `MessageDetailFooterToolbar`'s `summarizeButton` since Task #88),
    /// closed by its own toolbar button or the sheet's own swipe-to-dismiss.
    /// Stays local (not folded into `aiState`) — a `.sheet` presents at the
    /// window root regardless of where in the view tree it's declared, so
    /// this doesn't need to travel up to `ThreadDetailView` the way the
    /// summarize/translate buttons' own live state did (Task #59).
    @State private var isShowingSummarySheet = false
    /// Task #59 (フローティングボタンを画面下部に固定): `summaryState`/
    /// `translationState`/`translationShowOriginal` used to be separate
    /// `@State` here — folded into one `@Observable` handle so
    /// `ThreadDetailView`'s own top-level `overlay` (outside the scrollable
    /// content — see `MessageDetailAIFeaturesState`'s doc comment for why)
    /// can read and drive them too. This view still owns every mutation
    /// (`requestSummary`/`requestTranslation` below); `aiState` is purely
    /// the shared storage both sides read/write.
    @State var aiState = MessageDetailAIFeaturesState()
    /// `TranslatedBodyView.originalOverrides` — per-paragraph long-press
    /// state, reset alongside everything else in `load()`.
    @State var translationParagraphOverrides: Set<Int> = []
    @State var translateTask: Task<Void, Never>?
    /// 1i「HTMLメールもレイアウトを保持したまま翻訳」— the live handle
    /// `HTMLMessageView` reports via `onTranslationControllerReady`,
    /// non-`nil` only while an `HTMLMessageView` for *this* message is
    /// actually mounted. `requestTranslation(message:)`'s HTML branch reads
    /// this to collect the document's text nodes; `nil` there (view torn
    /// down mid-flight, or this message isn't HTML) just means "nothing to
    /// translate right now" rather than a crash.
    @State var htmlTranslationController: HTMLTranslationController?

    /// Task #138 (実機報告: 言語判定に依らず翻訳ボタンを常時有効にしてほしい
    /// — ユーザー指示による仕様変更): 以前はここで`message?.detectedLanguage`
    /// (「英語メールらしいか」)と`LocalizationSettingsStore
    /// .effectiveLanguageCode`(「アプリの表示言語」)の両方を条件にしていた
    /// (`isEnglishMessage`という別のプロパティも存在した)が、design-phase-3
    /// 以降 #90/#128 と繰り返し「英語メールなのに翻訳ボタンが出ない/押せ
    /// ない」実機報告が続いた根本原因が「言語判定そのものの信頼性」だった
    /// ため、表示条件からその判定を完全に取り除いた。今は
    /// `aiFeaturesEnabled`(I「AI 機能の on/off」)と本文が確定していること
    /// (`syncAIFeaturesState()`の`hasBody`)だけがゲート — 言語に関係なく
    /// 常に押せる。実際の翻訳自体は英語→日本語の一方向専用のまま
    /// (`requestTranslation`)なので、日本語メールで押しても実質無意味な
    /// 結果にはなるが、「ボタンが出ない/押せない」という誤診断可能性を
    /// 完全に潰すことを優先した。自動翻訳の起動条件
    /// (`kickoffTranslationIfNeeded`の「確信 en のみ」ガード)は誤爆防止と
    /// して意図的に維持している — 変更されるのは*ボタンの表示/有効*条件
    /// だけ。
    private var shouldShowTranslationBar: Bool {
        aiFeaturesEnabled
    }

    /// 1i「HTMLメールもレイアウトを保持したまま翻訳」— `content`'s HTML branch
    /// hands this straight to `HTMLMessageView.translatedTexts`. `nil`
    /// whenever there's nothing translated to overlay (bar hidden, no
    /// translation requested yet, still in flight, or failed) — matches
    /// `TranslatedBodyView`'s own gating in the plain-text branch below it,
    /// just expressed as an array instead of a view swap.
    private var htmlTranslatedTexts: [String]? {
        guard shouldShowTranslationBar, case .translated(let record) = aiState.translationState else { return nil }
        return record.paragraphs.map(\.translated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                header(for: message)
                    .padding()
                // Task #66 (カレンダー招待メール対応): shown above the plain
                // attachment list when this message carries a `text/
                // calendar` (or `.ics`) part — a calendar invite's whole
                // point is the event itself, not "here's a file", so it
                // gets its own prominent card rather than being just
                // another row in `attachmentSection` below.
                if let calendarInviteAttachment, let mailboxPath {
                    CalendarInviteSectionView(
                        accountId: accountId,
                        messageId: messageId,
                        messageUID: message.uid,
                        mailboxPath: mailboxPath,
                        calendarAttachment: calendarInviteAttachment,
                        loader: calendarInviteLoader
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                if !attachments.isEmpty {
                    attachmentSection
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                Divider()
            }
            // HTML bodies scroll internally (inside `HTMLMessageView`'s own
            // `WKWebView`) and need the remaining space handed to them
            // directly; plain-text bodies get their own `ScrollView` below
            // instead of wrapping the header in one too, so a long HTML
            // message never ends up nested inside two independent
            // scrollers.
            //
            // Task #59: `contentHeight` non-`nil` (a real HTML measurement
            // has arrived) sizes `content` to that exact height instead of
            // `maxHeight: .infinity` — see `contentHeight`'s own doc
            // comment for why: this view's total height then becomes
            // "header/attachments/divider's own intrinsic sizes + this
            // exact value", summed by the `VStack` itself, rather than a
            // guessed constant added on top of it one level up
            // (`ThreadMessageRow`'s removed `nonHTMLChromeAllowance`).
            //
            // Task #64 (根治: HTML翻訳ボタンが「本文の準備がまだ完了して
            // いません」で恒常的に失敗する): this used to be `if let
            // contentHeight { content.frame(...) } else { content.frame
            // (...) }` — two separate `if`/`else` branches wrapping the
            // *same* `content`. SwiftUI's `_ConditionalContent` treats an
            // `if`/`else`'s two branches as structurally distinct views
            // (`TrueContent`/`FalseContent`), even when both sides happen
            // to build the identical child — so the very first time
            // `contentHeight` flips from `nil` to a real value (which
            // happens for essentially every HTML message, moments after its
            // `WKWebView` finishes its own initial fit-to-width height
            // measurement — `HTMLWebViewCoordinator.onHeightChange`), this
            // branch switch tore down the whole `content` subtree —
            // including `HTMLMessageView`'s `WKWebView` and its
            // `HTMLTranslationController` — and mounted a brand-new one in
            // its place. The old subtree's `.onDisappear` (`HTMLMessageView
            // .body`'s `onTranslationControllerReady(nil)`) could then fire
            // *after* the new subtree's `.onAppear` reported its own fresh
            // controller, permanently leaving `htmlTranslationController`
            // `nil` — exactly the persistent (not just a one-frame race)
            // "本文の準備がまだ完了していません" failure a real-device report
            // hit on every retry, since nothing ever re-triggers another
            // `onAppear` once the view has settled into that one stable
            // branch. Fixed by never switching branches at all: a single
            // `content` call whose two `.frame` modifiers individually go
            // from "unconstrained" to "exact value" as `contentHeight`
            // changes — `.frame(height:)` already treats `nil` as "impose no
            // height constraint", the same effect the removed `else` branch
            // had, so this is behavior-preserving for both states while
            // keeping `content` at one single, stable identity throughout.
            //
            // Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」):
            // this exact `.frame` pair used to be applied right here, to
            // `content` as a whole. It moved down into `content`'s own HTML
            // branch (applied to just `HTMLMessageView`, not the whole
            // branch) so a quote-split HTML message's `QuoteHistorySectionView`
            // card below the `WKWebView` gets its own natural height added
            // on top, instead of being squeezed inside the web view's exact
            // measured height. This was already a no-op for every other
            // branch (`contentHeight` is only ever non-`nil` while an HTML
            // branch is mounted — `onHTMLContentHeightChange` is the only
            // writer), so removing it here changes nothing for the plain-
            // text/translated/empty/loading/error branches.
            content
        }
        .sheet(isPresented: $isShowingSummarySheet) {
            summarySheet
        }
        .accessibilityIdentifier("messageDetail.scrollView")
        // Task #59 (実機フィードバック「要約/翻訳のフローティングアイコンが
        // HTML本文と一緒にスクロールしてしまう、常に左下固定にしてほしい」):
        // Task #55 originally rendered these two buttons as this view's own
        // `.overlay(alignment: .bottomLeading)` — that worked while this
        // view's frame roughly matched the visible viewport, but Task #58's
        // fix (measuring the real HTML content height and sizing this row
        // to fit it, so `ThreadDetailView`'s own outer `ScrollView` becomes
        // the *only* scroller) means an expanded HTML message's frame is now
        // routinely much taller than the screen — an `.overlay` anchored to
        // *that* frame's bottom-leading corner sits wherever the message's
        // real content ends, which is usually scrolled far out of view, not
        // at the visible screen's bottom-leading corner the way a floating
        // button is supposed to. `MessageDetailAIFeaturesState` (`aiState`)
        // is this view's fix: it still owns every button behavior
        // (`requestSummary`/`requestTranslation`, both below), but hands the
        // live, `@Observable` state up to whichever ancestor actually wants
        // to render the buttons from it — originally `ThreadDetailView`'s
        // own top-level `overlay` (outside its `ScrollView`, exactly the way
        // `MailScreenView.floatingSearchButton`/`FolderListSheet
        // .floatingSettingsButton` stay pinned to the screen regardless of
        // scroll position); Task #88 moved the *renderer* to
        // `MessageDetailFooterToolbar`'s `summarizeButton`/`translateButton`
        // instead (フローティングボタン自体を廃止しツールバーへ統合), but
        // the hoisting mechanism itself — this view stays the one true owner
        // of every mutation, an ancestor merely reads/calls through the
        // shared handle — is unchanged, still needed for the exact same
        // "this row can be much taller than the viewport" reason. `onAppear`/
        // `onDisappear` (not `.task(id: messageId)`) because this needs to
        // fire exactly when this view enters/leaves the tree (the accordion
        // collapsing this row tears it down entirely — `ThreadMessageRow`'s
        // `if isExpanded` — which is also when the ancestor should stop
        // reflecting these buttons), matching the existing
        // `onTranslationControllerReady` handoff `HTMLMessageView` already
        // uses for the same reason.
        // Task #96 (実機報告: 本文読み込み完了前に一覧へ戻ると既読にならない):
        // fires the instant this view mounts — a thread row's expand or a
        // direct push, either way completely independent of `.task(id:
        // messageId)`'s own cancellable lifecycle below — so an early pop
        // back to the list mid-body-fetch no longer means `\Seen` never
        // gets applied. See `markAsReadIfNeeded()`'s doc comment.
        .onAppear {
            // Task #149: see `isToolbarTarget`'s doc comment — a non-target
            // instance never reports itself to the shared toolbar state at
            // all, appear or not.
            if isToolbarTarget { onAIFeaturesStateChange(aiState) }
            markAsReadIfNeeded()
        }
        .onDisappear {
            if isToolbarTarget { onAIFeaturesStateChange(nil) }
        }
        // Task #149 (2): the accordion switching to a new target message
        // reconstructs `MessageView` fresh (see `isToolbarTarget`'s doc
        // comment — it's always `true` from the moment a target instance is
        // first constructed), so in practice this fires only for the
        // pathological case a future change might introduce (an existing
        // instance's target status flipping without a full remount) — kept
        // anyway as the explicit "becoming target re-syncs immediately"
        // rule the fix calls for, rather than relying on it being currently
        // unreachable.
        .onChange(of: isToolbarTarget) { _, isTarget in
            guard isTarget else { return }
            syncAIFeaturesState()
            onAIFeaturesStateChange(aiState)
        }
        // Task #59: keeps the buttons' visibility live if the user toggles
        // I「AI 機能の on/off」while this message is open — see
        // `syncAIFeaturesState()`'s doc comment.
        .onChange(of: aiFeaturesEnabled) { _, _ in syncAIFeaturesState() }
        // 表示・操作改善バッチ「ヘッダにメール件名を表示しない」: this view is
        // always embedded inside `ThreadDetailView` (never pushed on its
        // own) — a `.navigationTitle` here would repeat the subject in the
        // nav bar and, being the more deeply nested view, would win over
        // `ThreadDetailView`'s own generic title. 画面構造改修バッチ (Task
        // #33, 2) 以降、`header(for:)`(`MessageHeaderCompactView`)自体も
        // 件名を出さなくなった (そのdoc comment参照) — 件名はこの画面に到達
        // する前の一覧/スレッド選択画面と、フッターツールバーの「情報」にのみ
        // 出る。
        .task(id: messageId) { await load() }
        // Task #147 (実機報告「本文の後着で要約/翻訳ボタンが有効化されない」):
        // `load()`とは別の、もう1本の`.task(id: messageId)` — 同じidキー
        // なので、メッセージが切り替わる/この`MessageView`自体が破棄される
        // (`ThreadMessageRow`の`if isExpanded` — #136のアコーディオンで
        // 折りたたまれる) たびに`load()`と同時に確実にキャンセルされる。
        // `observeBodyRecordChanges()`のdoc comment参照 — `load()`が
        // 開いた時点の一回きりの取得で終わるのに対し、こちらは表示中ずっと
        // `messageBody`行を監視し続け、後から (バックグラウンドプリフェッチ
        // 等で) 届いた本文にも反応する。
        .task(id: messageId) { await observeBodyRecordChanges() }
        // M8: QuickLook, shared across platforms via SwiftUI's own
        // modifier rather than a `QLPreviewController`/`QLPreviewPanel`
        // wrapper per platform — see `openAttachment(_:)`'s doc comment.
        .quickLookPreview($previewURL)
        #if os(iOS)
        // C7: only overrides SwiftUI's default link-opening behavior when
        // "アプリ内ブラウザ" is selected — `.systemAction` below falls straight
        // back to that default (デフォルトブラウザ) otherwise, so this never
        // needs its own `else` branch.
        .environment(\.openURL, OpenURLAction { url in
            guard openInAppBrowser else { return .systemAction }
            // Task #166 (SEC-A, F17): `url` here can be anything
            // `NSDataDetector` linkified out of an untrusted plain-text
            // body — not just http(s) links, but e.g. a bare email
            // address turned into a `mailto:` URL. `SFSafariViewController`
            // (`SafariViewRepresentable`) is documented to require http/
            // https and throws on `init` otherwise, so passing it a
            // `mailto:`/anything-else URL was a guaranteed crash on tap —
            // a single attacker-controlled body line away. Mirror
            // `HTMLMessageView.handleLinkTap`'s existing http/https-only
            // gate: anything else falls through to `.systemAction`, which
            // hands it to the system (e.g. `mailto:` opens the user's
            // default mail composer instead of a browser sheet). See
            // `InAppBrowserURLPolicy`'s doc comment for why the check
            // itself lives in `OtegamiCore` instead of inline here.
            guard InAppBrowserURLPolicy.isSupported(url) else {
                return .systemAction
            }
            presentedSafariURL = IdentifiableURL(url: url)
            return .handled
        })
        .sheet(item: $presentedSafariURL) { item in
            SafariViewRepresentable(url: item.url)
                .ignoresSafeArea()
        }
        #endif
    }

    // MARK: - Task #55/#59/#88: AI要約/翻訳 (フッターツールバー起点)

    /// Task #59 (実機フィードバック「フローティングアイコンを左下固定に」)、
    /// Task #88 (フッターツールバーへ移設): keeps `aiState` — the handle
    /// `MessageDetailFooterToolbar`'s `summarizeButton`/`translateButton`
    /// actually render from (via `ThreadDetailView`'s forwarding, outside
    /// this view's own, now potentially very tall post-Task #58, frame) — in
    /// sync with this view's show/hide conditions and button actions. Both
    /// conditions are unchanged since Task #55's original
    /// `floatingActionButtons`:
    /// - 要約: shown whenever I「AI 機能の on/off」(`aiFeaturesEnabled`) is
    ///   on, language-independent (a summary is useful even for a Japanese
    ///   mail).
    /// - 翻訳: `shouldShowTranslationBar` (Task #138 以降、言語判定なしで
    ///   AI 機能が on であれば常に表示 — そのプロパティのdoc comment参照)。
    ///
    /// Called from `load()` once `message` is known (so the two closures
    /// below always have a real message to act on) and from `body`'s
    /// `.onChange(of: aiFeaturesEnabled)` — the settings toggle used to take
    /// effect immediately because the old `floatingActionButtons` read
    /// `aiFeaturesEnabled` directly on every body evaluation; this keeps
    /// that same live behavior now that `aiState`, not this view's own
    /// body, is what the footer toolbar actually renders from.
    func syncAIFeaturesState() {
        // Task #149 (3): a non-target instance (`isToolbarTarget`'s doc
        // comment) never mutates `aiState` at all here — not just "mutates
        // it but doesn't forward it" — so a residual/racing instance's #147
        // `observeBodyRecordChanges()` delivery (this method's other call
        // site, `applyObservedBodyRecordIfNeeded`) can't even leave stale
        // button-visibility state sitting in its own `aiState` for some
        // later code path to accidentally pick up. Still logs (at both
        // gate loggers, with `skipped` in place of the usual field dump) so
        // a real occurrence of exactly this race remains visible in
        // `log stream` instead of just silently doing nothing.
        guard isToolbarTarget else {
            Self.summaryGateLogger.notice("syncAIFeaturesState: messageId=\(messageId, privacy: .public) skipped (non-target)")
            Self.translationGateLogger.notice("syncAIFeaturesState: messageId=\(messageId, privacy: .public) skipped (non-target)")
            return
        }
        // Task #64 (実機フィードバック「本文読み込み完了までフローティング
        // ボタンを出さないでほしい」): gates on `bodyRecord != nil` — the
        // message's body has actually finished loading — rather than the
        // previous `message != nil`. `message` is set (`load()`'s
        // `message = loadedMessage`) *before* a not-yet-fetched body's
        // network round-trip even starts, so gating on it alone let the
        // buttons appear while `content` was still showing the "本文を取得
        // しています…" spinner. Gating on `bodyRecord` instead means both
        // buttons stay hidden through the fetch and, if it fails with
        // nothing cached locally either (`load()`'s `catch` branch, no
        // `syncAIFeaturesState()` call at all when there's no `bodyRecord`
        // to show), stay hidden — this call simply never runs again in that
        // case, so whatever this last computed (hidden, from the initial
        // reset) is what persists. Also incidentally fixes a narrower edge
        // case: `.onChange(of: aiFeaturesEnabled)` below calls this same
        // method directly, and could previously flash the buttons on for a
        // split second if the AI-features setting were toggled while a body
        // fetch was still in flight (`message` already set, `bodyRecord`
        // not yet).
        // Task #138 追加報告 (実機「要約ボタンが押せない時がある」): 元は
        // `bodyRecord != nil` だけがゲートだった — 本文取得が失敗した
        // (`load()`の`catch`分岐、`bodyRecord`は`nil`のまま`errorMessage`が
        // 立つ)場合、このメソッドはその後二度と呼ばれず、ボタンは永久に
        // 非表示のまま固定されていた(このdoc comment冒頭のTask #64の説明が
        // まさにその構造そのもの)。`errorMessage != nil`も"settled"(読み込み
        // 試行が完了した)状態として扱うことで、取得失敗後もボタン自体は
        // 出るようにし、タップ時の再試行に賭けられるようにした
        // (`requestSummary(message:)`の`fetchBodyForSummaryRetryIfNeeded`
        // 参照)。翻訳ボタンの言語判定撤去 (`shouldShowTranslationBar`の
        // doc comment) と同じ「ボタンを隠して誤診断させるより、押せる
        // ようにして失敗時はその場でエラーを見せる」方針。
        let hasSettledBodyState = bodyRecord != nil || errorMessage != nil
        aiState.showsSummaryButton = hasSettledBodyState && aiFeaturesEnabled
        Self.summaryGateLogger.notice("""
        syncAIFeaturesState: messageId=\(messageId, privacy: .public) isToolbarTarget=\(isToolbarTarget, privacy: .public) \
        hasBody=\(bodyRecord != nil, privacy: .public) hasError=\(errorMessage != nil, privacy: .public) \
        aiFeaturesEnabled=\(aiFeaturesEnabled, privacy: .public) \
        showsSummaryButton=\(aiState.showsSummaryButton, privacy: .public)
        """)
        // Task #64 (根治の一環、「ボタンが出ている＝翻訳可能を保証」) had this
        // also require `htmlTranslationController != nil` for an HTML
        // message shown as HTML — reasoning that showing the button before
        // the controller connects would let a tap hit `requestTranslation`'s
        // nil-guard and fail. Task #128 (実機報告「英語メールなのに翻訳ボタン
        // が押せない」— Okta のサインオン通知メール) found the flip side of
        // that tradeoff: if the controller *never* connects for some
        // message's particular HTML (a fresh #61/#64-shaped hole, or simply
        // a slow-to-appear `HTMLMessageView`), this gate hides the button
        // permanently, with no visible failure at all — indistinguishable
        // from "not an English message" from the user's side, and
        // undiagnosable without exactly this method's own state. Rather than
        // keep hiding the button on that gamble, `requestTranslation` below
        // now falls back to the plain-text translation path (`sourceTextForTranslation()`,
        // which doesn't touch `WKWebView` at all) whenever the controller
        // turns out to still be `nil` at tap time — so the button can safely
        // show as soon as the body's ready, same as the summary button just
        // above, and a stuck controller costs only the HTML-layout-preserving
        // presentation (1i), not translation itself.
        let htmlControllerReadyIfNeeded = !isHTMLMessage || !isShowingHTML || htmlTranslationController != nil
        let hasBody = bodyRecord != nil
        aiState.showsTranslationButton = hasBody && shouldShowTranslationBar
        aiState.isTranslationAvailable = environment.isTranslationAvailable
        // Task #159: separate from `isTranslationAvailable` above now that
        // translation (`AppleTranslationService`) and summarization
        // (`FoundationModelsTranslationService`) are two different engines
        // with two different availability stories — see
        // `AppEnvironment.isSummarizationAvailable`'s doc comment.
        aiState.isSummarizationAvailable = environment.isSummarizationAvailable
        // Task #128 (a): the three conditions the old `showsTranslationButton`
        // gate combined, logged individually — see `translationGateLogger`'s
        // doc comment for why every call logs, not just failures. Task #134:
        // `.debug` → `.notice` — a43c07e's #128 instrumentation was still
        // `.debug` and, per `docs/verify.md`'s new note, `.debug`/`.info`
        // never survive into a `log collect` archive (the same #105/#122
        // trap, hit a third time here).
        Self.translationGateLogger.notice("""
        syncAIFeaturesState: messageId=\(messageId, privacy: .public) isToolbarTarget=\(isToolbarTarget, privacy: .public) \
        hasBody=\(hasBody, privacy: .public) \
        shouldShowTranslationBar=\(shouldShowTranslationBar, privacy: .public) \
        htmlControllerReadyIfNeeded=\(htmlControllerReadyIfNeeded, privacy: .public) \
        showsTranslationButton=\(aiState.showsTranslationButton, privacy: .public) \
        detectedLanguage=\(message?.detectedLanguage ?? "nil", privacy: .public) \
        isHTMLMessage=\(isHTMLMessage, privacy: .public) isShowingHTML=\(isShowingHTML, privacy: .public) \
        htmlTranslationControllerConnected=\(htmlTranslationController != nil, privacy: .public)
        """)
        aiState.onSummarize = { [self] in
            guard let message else { return }
            requestSummary(message: message)
        }
        aiState.onShowSummary = { [self] in isShowingSummarySheet = true }
        aiState.onTranslate = { [self] in
            guard let message else { return }
            requestTranslation(message: message)
        }
    }

    /// Task #55: where a generated summary is actually shown — a sheet
    /// (`aiState.onShowSummary`, called from `MessageDetailFooterToolbar`'s
    /// `summarizeButton` since Task #88) rather than the old bar's inline
    /// text, since a small toolbar icon has no room of its own to grow text
    /// into either. Handles all four `MessageSummaryState` cases so it reads
    /// sensibly regardless of when it's opened (including mid-generation,
    /// if a user re-opens it right after tapping the button).
    private var summarySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: OtegamiSpacing.md) {
                    switch aiState.summaryState {
                    case .none:
                        EmptyView()
                    case .summarizing:
                        HStack {
                            Spacer(minLength: 0)
                            ProgressView()
                                .accessibilityIdentifier("messageDetail.summarySheet.loading")
                            Spacer(minLength: 0)
                        }
                        .padding(.top, OtegamiSpacing.xl)
                    case .summarized(let text):
                        SummaryText(text: text)
                            .accessibilityIdentifier("messageDetail.summarySheet.text")
                    case .failed(let failureMessage):
                        // `AISummaryBar`の旧footnoteと同じ理由で非ローカライズ
                        // (実行時の値を含むため) — `TranslationFloatingButton
                        // .footnote`のdoc comment参照。
                        Text("要約に失敗しました: \(failureMessage)")
                            .font(OtegamiFont.subheadline())
                            .foregroundStyle(OtegamiColor.destructive)
                            .accessibilityIdentifier("messageDetail.summarySheet.footnote")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("AI要約")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { isShowingSummarySheet = false }
                        .accessibilityIdentifier("messageDetail.summarySheet.closeButton")
                }
                // Task #148 (「詳しく要約」): 「再生成」を`Menu`化し、通常の
                // 再生成 (現行、sentenceCount既定=2) に加えて「詳しく要約」
                // (■要約パートをsentenceCount=10相当で、`detailed: true`)
                // を選べるようにした。モード自体は保持しない — この`Menu`
                // は常に同じ2択を毎回提示するだけで、直前にどちらを選んだ
                // かを覚えて次回のデフォルトを変えたりはしない (指示どおり)。
                ToolbarItem(placement: .confirmationAction) {
                    if aiState.summaryState.isSummarizing {
                        ProgressView()
                    } else if let message {
                        Menu {
                            Button("再生成") { requestSummary(message: message) }
                                .accessibilityIdentifier("messageDetail.summarySheet.regenerateButton")
                            Button("詳しく要約") { requestSummary(message: message, detailed: true) }
                                .accessibilityIdentifier("messageDetail.summarySheet.regenerateDetailedButton")
                        } label: {
                            Label("再生成", systemImage: "arrow.clockwise")
                                .labelStyle(.titleOnly)
                        }
                        .accessibilityIdentifier("messageDetail.summarySheet.regenerateMenu")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 画面構造改修バッチ (Task #33, 2): 圧縮ヘッダ本体は
    /// `MessageHeaderCompactView`に切り出した — このメソッドはその呼び出しに
    /// 必要な値を集めるだけの薄いラッパー。
    private func header(for message: MessageRecord) -> some View {
        MessageHeaderCompactView(
            message: message,
            accountId: accountId,
            accountLabelColorKey: environment.accounts.first(where: { $0.id == accountId })?.labelColorKey,
            showAvatar: showAvatarInDetail,
            isHTMLMessage: isHTMLMessage,
            isShowingHTML: isShowingHTML,
            onToggleHTMLText: { manualPreferPlainText = isShowingHTML },
            isArchived: isArchived
        )
    }

    /// A9-1/A9-4: whether `bodyRecord` has an HTML part with genuinely
    /// visible content — the badge and the HTML/text toggle button both
    /// gate on this, regardless of which rendering is currently chosen.
    ///
    /// Not just "is `html` a non-empty string": a message with no real body
    /// at all (`18-empty-body.eml`'s fixture, confirmed by an actual
    /// simulator run) still comes back from MailCore2's `htmlBodyRendering()`
    /// as a non-empty (but tag-only, no visible text or media) HTML
    /// document — treating that as "an HTML message" would show the "HTML"
    /// badge and a genuinely blank `WKWebView` instead of A9-4's "本文なし"
    /// placeholder. `HTMLTextExtractor` finding no text is *not* enough on
    /// its own to call the HTML empty, though — an image-only HTML message
    /// (no text, but a real `<img>` to show) is legitimate HTML content, so
    /// this only treats HTML as empty when it has neither extractable text
    /// nor any `<img` tag.
    var isHTMLMessage: Bool {
        guard let html = bodyRecord?.html, !html.isEmpty else { return false }
        if HTMLTextExtractor.plainText(fromHTML: html).isEmpty, !html.localizedCaseInsensitiveContains("<img") {
            return false
        }
        return true
    }

    /// A9-2: the effective choice between the HTML (`WKWebView`) and
    /// text rendering for *this* message right now — `manualPreferPlainText`
    /// (set by the toggle button) wins when present, otherwise falls back to
    /// the "常にテキストで表示" setting's default. Always `true` (irrelevant)
    /// for a non-HTML message; callers only consult this after already
    /// checking `isHTMLMessage`/`bodyRecord.html`.
    var isShowingHTML: Bool {
        !(manualPreferPlainText ?? alwaysShowPlainText)
    }

    /// A9-2: the text rendering an HTML message falls back to when
    /// `isShowingHTML` is `false` — the message's own `text/plain` part if
    /// it has one (a real author-provided plain-text alternative), otherwise
    /// `HTMLTextExtractor`'s output from the HTML (same extractor
    /// `ComposerView`'s reply-quoting and the translation source already
    /// use, so this doesn't introduce a second HTML-to-text implementation).
    private func plainTextFallback(for bodyRecord: MessageBodyRecord) -> String? {
        if let plainText = bodyRecord.plainText, !plainText.isEmpty { return plainText }
        if let html = bodyRecord.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }

    // MARK: - Quote history (Task #123)

    /// Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列
    /// 表示」): the new-text/quoted-history split for `content`'s plain-text
    /// branch, `nil` whenever there's nothing to split off (no body yet, no
    /// genuine `text/plain` part, or `QuoteStripper` found no quote marker
    /// at all).
    ///
    /// Deliberately scoped to `!isHTMLMessage` — an HTML message's own
    /// `bodyRecord.plainText` (when it even has one) is a client-provided
    /// *alternative* rendering, not guaranteed to carry the same `>` quote
    /// structure the HTML side does, and Task #123's brief explicitly scopes
    /// the full per-message card to plain-text mail ("まずプレーンテキスト
    /// メールを対象") — an HTML message (including one manually toggled to
    /// its text view via `manualPreferPlainText`) keeps showing its full,
    /// unsplit plain-text fallback here; the lighter HTML-side fold is the
    /// follow-up `docs/design-system.md`'s Task #123 section notes.
    ///
    /// Reuses the exact same `isReply`-gated split `sourceTextForSummary()`
    /// already computes for AI summarization (see that method's own Task
    /// #90 doc comment for why `message?.inReplyTo` gates the looser
    /// `replyOnlyPlainTextQuoteMarkerPatterns`) — same input, same trust
    /// level, just a different consumer (display instead of a summarization
    /// prompt).
    private var plainTextQuoteHistorySplit: QuoteStripper.SeparatedText? {
        guard !isHTMLMessage, let bodyRecord, let plainText = bodyRecord.plainText, !plainText.isEmpty else { return nil }
        let isReply = message?.inReplyTo != nil
        let split = QuoteStripper.separatingQuotedText(fromPlainText: plainText, isReply: isReply)
        guard !split.quotedText.isEmpty else { return nil }
        return split
    }

    /// The text `content`'s plain-text branch actually renders as the main
    /// body: `plainTextQuoteHistorySplit`'s new-text half (trimmed) when a
    /// quote history was split off — the quoted half moves into
    /// `QuoteHistorySectionView`'s own card instead — otherwise `plainText`
    /// untouched (no quote history found, so nothing changes from this
    /// feature's pre-Task-#123 behavior).
    private func plainTextBodyDisplayText(for plainText: String) -> String {
        guard let split = plainTextQuoteHistorySplit else { return plainText }
        let trimmed = split.newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? plainText : trimmed
    }

    /// Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」— #123の
    /// 折りたたみはプレーンテキスト表示限定だったが、実際のGmailはほぼ全部
    /// HTML付きでHTML表示が優先されるため実機で機能しなかった):
    /// `content`のHTML分岐版 — `bodyRecord.html`で新/旧 new/quoted に分割
    /// する。`plainTextQuoteHistorySplit`と違い`isHTMLMessage`を要求する側
    /// (こちらが真、あちらが偽)なので相互排他。`nil`は「分割できなかった
    /// (マーカーなし、または新規部分が短すぎるフォールバック)」— その場合
    /// `content`は従来どおり`bodyRecord.html`全体を`HTMLMessageView`に
    /// そのまま渡す(挙動不変)。
    ///
    /// Task #138 (キャッシュ済み本文の救済、`sourceTextForSummary()`と
    /// 同じ動機): `QuoteStripper.separatingQuotedHTML(html:plainText:
    /// isReply:)`を使う — `html`の構造的マーカー(`blockquote`/
    /// `gmail_quote`など)を先に試し、見つからなければ`bodyRecord.plainText`
    /// のマーカーへフォールバックする。`sourceTextForSummary()`の
    /// 「plainを先に」とは*あえて順序を逆*にしている — その関数の doc
    /// comment(`QuoteStripper.separatingQuotedHTML(html:plainText:
    /// isReply:)`側)参照: `html`が健全な(#134以降に取得された)ふつうの
    /// メッセージでタグ保持の`newHTML`短縮を毎回捨てる回帰を避けるため。
    private var htmlQuoteHistorySplit: QuoteStripper.SeparatedHTML? {
        guard isHTMLMessage, let html = bodyRecord?.html, !html.isEmpty else { return nil }
        let isReply = message?.inReplyTo != nil
        return QuoteStripper.separatingQuotedHTML(html: html, plainText: bodyRecord?.plainText, isReply: isReply)
    }

    /// `htmlQuoteHistorySplit`が見つかった時に`QuoteHistorySectionView`へ
    /// 渡す平文 — 実装方針(#133のタスク仕様)通り、入力の優先順位は:
    /// 1. `bodyRecord.plainText`があれば、そちらを`QuoteStripper`のプレーン
    ///    分割 (`plainTextQuoteHistorySplit`と同じ`isReply`ゲート) にかけた
    ///    `quotedText` — HTMLタグのノイズが無く`QuoteHistoryParser`の帰属行
    ///    パターンに素直に一致する(実物`yoyaku.eml`で検証済み:
    ///    detectedMarker=japaneseSaidWroteAddressEnd、新規117字/引用1777字)。
    /// 2. `bodyRecord.plainText`が無い(またはそちらの分割が空だった)場合は
    ///    `htmlQuoteHistorySplit.quotedHTML`を`HTMLTextExtractor`で平文化した
    ///    ものにフォールバック。
    /// どちらの経路で得たテキストも`QuoteHistoryParser.parse`が帰属行を
    /// 一つも確信を持って検出できなければ`.unparsed`(生テキストのまま
    /// カード表示)に自然にフォールバックする — `QuoteHistorySectionView`
    /// 自身の既存契約どおり、ここでは何もしない。
    private var htmlQuoteHistoryQuotedText: String? {
        guard let htmlSplit = htmlQuoteHistorySplit else { return nil }
        if let plainText = bodyRecord?.plainText, !plainText.isEmpty {
            let isReply = message?.inReplyTo != nil
            let plainSplit = QuoteStripper.separatingQuotedText(fromPlainText: plainText, isReply: isReply)
            if !plainSplit.quotedText.isEmpty {
                return plainSplit.quotedText
            }
        }
        let extracted = HTMLTextExtractor.plainText(fromHTML: htmlSplit.quotedHTML)
        return extracted.isEmpty ? nil : extracted
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("本文を取得しています…")
                        .accessibilityIdentifier("messageDetail.loadingIndicator")
                    Spacer()
                }
                Spacer()
            }
        } else if let bodyRecord {
            // A9-2: an HTML message only actually renders `HTMLMessageView`
            // when `isShowingHTML` — the "常にテキストで表示" setting or this
            // message's own toggle button can route it through the plain-
            // text branch below instead, using `plainTextFallback(for:)`
            // (the message's real `text/plain` part if it has one, else
            // `HTMLTextExtractor`'s output) exactly the way a message with
            // no HTML part at all already does.
            //
            // 1i「HTMLメールもレイアウトを保持したまま翻訳」: an HTML message
            // never swaps over to `TranslatedBodyView` (that would lose the
            // whole DOM — images, tables, layout) — instead `HTMLMessageView`
            // itself overlays `htmlTranslatedTexts` onto the loaded
            // document's own text nodes in place, so this branch always
            // renders `HTMLMessageView` regardless of translation state.
            if isHTMLMessage, isShowingHTML, let html = bodyRecord.html {
                // Task #133 (実機報告「引用折りたたみがHTMLメールで効か
                // ない」): `htmlQuoteHistorySplit`が取れた場合、`WKWebView`
                // には新規部分のHTML(`newHTML`)だけを渡し、引用履歴は下の
                // `QuoteHistorySectionView`のネイティブカードへ切り出す —
                // プレーンテキスト分岐(#123)と同じトグル+カードのハイブリッド
                // 表示。分割できなかった場合(`nil`)は`html`をそのまま渡す
                // 従来どおりの挙動(回帰なし)。`htmlQuoteHistorySplit`は
                // `bodyRecord.html`が確定した時点から不変(WKWebView自身の
                // 非同期な高さ報告等、後から変わる値には一切依存しない)ので、
                // この`VStack`自体が毎回同じ構造で安定 — Task #64が修正した
                // 「`contentHeight`のif/elseで`HTMLMessageView`ごと再マウント
                // される」問題を再導入しない。
                VStack(alignment: .leading, spacing: 0) {
                    HTMLMessageView(
                        html: htmlQuoteHistorySplit?.newHTML ?? html, accountId: accountId, messageId: messageId, mailboxPath: mailboxPath,
                        // Task #59 (「本文下の空白が過剰」): this used to pass
                        // `floatingButtonsReservedBottomInset` here so the
                        // *loaded document itself* reserved room for the
                        // floating buttons at the end of its own scroll —
                        // Task #56's original reasoning, back when this
                        // `WKWebView` still scrolled internally. Task #58
                        // turned `ThreadDetailView`'s outer `ScrollView` into
                        // the only scroller (this view's frame is now sized
                        // to the real measured content height, not the
                        // viewport), and Task #59 moved the floating buttons
                        // themselves out to that same outer level — so the
                        // "don't render behind the buttons" reservation only
                        // needs to happen *once*, at that single outer
                        // scroller, not once per body branch here too (the
                        // two used to add together, which was most of the
                        // "空白が過剰" bug: this document's own bottom
                        // spacer *plus* the outer row's `+180pt` chrome
                        // allowance). See `ThreadDetailView`'s own
                        // `.contentMargins(.bottom:)` for where the single
                        // reservation now lives, computed from
                        // `expandedAIFeaturesState`.
                        bottomContentInset: 0,
                        translatedTexts: htmlTranslatedTexts, showOriginalText: aiState.translationShowOriginal,
                        // Task #64 (根治の一環): re-syncs `aiState.showsTranslationButton`
                        // right when the controller connects/disconnects, not
                        // just at `load()` time — see `syncAIFeaturesState()`'s
                        // updated gating for why a connected controller is now
                        // part of "翻訳ボタンを見せてよいか" for an HTML message,
                        // so the button's actual visibility stays honest with
                        // whether tapping it would work.
                        onTranslationControllerReady: { controller in
                            htmlTranslationController = controller
                            syncAIFeaturesState()
                        },
                        onHeightChange: onHTMLContentHeightChange
                    )
                    .accessibilityIdentifier("messageDetail.htmlBody")
                    // Task #133: this exact-height framing used to sit on
                    // `content` as a whole (`body`'s own modifier chain,
                    // Task #64's "never branch the modifier chain" fix) —
                    // moved down to just `HTMLMessageView` itself now that
                    // this branch can render more than one child
                    // (`QuoteHistorySectionView`'s card below needs its own
                    // natural height, not squeezed into the WKWebView's
                    // exact measured height). `content` itself keeps being
                    // one single, unconditional call from `body` either way
                    // — only what's *inside* this one HTML branch grew —
                    // so Task #64's identity-stability fix isn't reintroduced.
                    .frame(maxWidth: .infinity, maxHeight: contentHeight == nil ? .infinity : nil, alignment: .topLeading)
                    .frame(height: contentHeight)
                    if let quotedText = htmlQuoteHistoryQuotedText {
                        QuoteHistorySectionView(quotedText: quotedText)
                            .padding()
                    }
                }
            } else if shouldShowTranslationBar, !aiState.translationShowOriginal, case .translated(let record) = aiState.translationState {
                // 1i: "訳文" showing and a translation actually cached, for a
                // *plain-text* body — the per-paragraph long-press original
                // toggle only makes sense here (the HTML branch above
                // handles its own translated display entirely inside the
                // web view instead). Every other state (still translating,
                // failed, "原文" selected, or not an English message at all)
                // falls through to the plain-text rendering below untouched.
                // Task #59: `bottomContentInset: 0` — see the HTML branch's
                // doc comment above; the same single-reservation-at-the-
                // outer-scroller reasoning applies here.
                TranslatedBodyView(
                    paragraphs: record.paragraphs,
                    originalOverrides: $translationParagraphOverrides,
                    bottomContentInset: 0
                )
                .otegamiForceLightBackground(forceLightBackground)
            } else if let plainText = plainTextFallback(for: bodyRecord) {
                // Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して
                // 時系列表示」): when `plainTextQuoteHistorySplit` finds a
                // quote to split off, only the new-reply half renders here
                // — the quoted half moves into `QuoteHistorySectionView`'s
                // own toggleable card below instead of staying inline as
                // one undifferentiated wall of `>` text. A message with no
                // quote history (the common case) is unaffected:
                // `plainTextBodyDisplayText(for:)` falls straight back to
                // `plainText` untouched.
                ScrollView {
                    VStack(alignment: .leading, spacing: OtegamiSpacing.lg) {
                        linkifiedText(plainTextBodyDisplayText(for: plainText))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("messageDetail.plainTextBody")
                        if let split = plainTextQuoteHistorySplit {
                            QuoteHistorySectionView(quotedText: split.quotedText)
                        }
                    }
                    .padding()
                }
                .otegamiForceLightBackground(forceLightBackground)
                // Task #59: no longer reserves bottom space here — see the
                // HTML branch's doc comment above (`ThreadDetailView`'s own
                // outer `ScrollView` is the single place this reservation
                // happens now).
            } else {
                // A9-4: shown whenever there is genuinely no body content at
                // all (no HTML, no `text/plain`, and — for an HTML message
                // switched to text — no extractable text either) — a light,
                // clearly-secondary label rather than leaving the space
                // blank, per the design system's `inkTertiary` token
                // ("薄いテキスト（無効/キャプション寄り）").
                Text("本文なし")
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.inkTertiary)
                    .padding()
                    .accessibilityIdentifier("messageDetail.emptyBody")
            }
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding()
                .accessibilityIdentifier("messageDetail.errorMessage")
        }
    }

    // MARK: - Plain-text link detection

    /// Builds a `Text` with any `http(s)://` links in `text` rendered as
    /// tappable links (plan: "SwiftUI Text（等幅でなく通常書体、リンク検出）").
    private func linkifiedText(_ text: String) -> Text {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Text(attributed)
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: attributed)
            else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].underlineStyle = .single
        }
        return Text(attributed)
    }

    // MARK: - AI要約 (表示・操作改善バッチ)

    func resetSummaryState() {
        summaryTask?.cancel()
        summaryTask = nil
        aiState.summaryState = .none
        // Task #55: `load()` calls this on every message switch (this view
        // is reused across messages via `.task(id: messageId)`, not
        // recreated) — an open summary sheet left showing the *previous*
        // message's summary while its content silently swapped underneath
        // would be confusing, so close it along with resetting the state it
        // displays.
        isShowingSummarySheet = false
    }

    /// `requestSummary`専用のソーステキスト — `sourceTextForTranslation()`と
    /// 同じ「HTML本文は`HTMLTextExtractor`で平文化」経路を辿るが、その前に
    /// `QuoteStripper`で本文を「新規部分」と「引用されている過去のやり
    /// 取り」に分離する (Task #46: 「返信がたくさん繰り返されて過去の文章
    /// がたくさんある時、そこは要約の対象外にして欲しい」、Task #62での
    /// フォローアップ「まだ過去の返信などの引用の内容を要約してるっぽい。
    /// 完全には無視しなくていいけど、そういう流れがある上で、どういう
    /// メールなのかを要約するようにして欲しい」)。
    ///
    /// Task #134 (根治): #62〜#132 は`QuoteStripper.separatingQuotedText`で
    /// 分離した引用部分の*内容*を、ラベル付き・文字数上限付き・時系列順
    /// (#97)でモデルへ渡し続けていた — それでも実機で引用内容の要約への
    /// 混入が再発した (`docs/translation.md`の#132節)。ここで渡していた
    /// のがまさに漏れの原因だったため、`SummaryInputBuilder.build`には
    /// もう引用の*内容*を渡さない — `separated.quotedText`が空かどうか
    /// (`hasQuotedContext`)だけを伝え、実際の引用テキストは
    /// `HTMLTextExtractor`にかけることすらしない (以前はここでも処理
    /// していたが、内容を使わない以上不要)。引用が無い場合は従来通り
    /// 単一テキストのまま渡る (`SummaryInputBuilder.build`の
    /// `hasQuotedContext == false`分岐)。詳細は`SummaryInputBuilder`の
    /// doc comment参照。
    ///
    /// `sourceTextForTranslation()`を直接書き換えず専用メソッドに分けたのは、
    /// あのメソッドは翻訳とも共有されており、翻訳・本文表示は引用を含めた
    /// 全文のまま扱う必要がある (`QuoteStripper`のdoc comment参照) ため —
    /// 要約だけがこの追加ステップを踏む。
    ///
    /// Task #90: `message?.inReplyTo`の有無を`QuoteStripper`の`isReply`に
    /// 渡す — In-Reply-To/Referencesがあり「このメールは返信である」と
    /// 分かっている場合のみ、`QuoteStripper.replyOnlyPlainTextQuoteMarker
    /// Patterns`(「wrote:」を欠いた「On ... <address>」行、Sent/To/Subject
    /// ブロックを伴わない裸の「From: ... <address>」行など)を有効化する。
    /// これらは返信だと確定していない本文では旅程表の「From: 東京」等と
    /// 誤検知しうるため、ヘッダで裏付けが取れた時だけ使う。
    private func sourceTextForSummary() -> String? {
        guard let bodyRecord else { return nil }
        let plainText = bodyRecord.plainText
        let html = bodyRecord.html
        guard plainText != nil || html != nil else { return nil }
        let isReply = message?.inReplyTo != nil
        // Task #134: 実機でのみ`bodyRecord.plainText`がmailcore2の
        // `plainTextBodyRendering()`(HTML優先タグ剥がし)経由になり、Mac
        // 上の再現とは異なる形状になっていた疑いがある(#132の実機不再現の
        // 原因調査)。
        //
        // Task #138 (キャッシュ済み本文の救済): 実機で`source=plain
        // quotedTextLength=0 detectedMarker=none`(分離できず全文がそのまま
        // モデルへ渡る)ケースが確認された — #134より前にキャッシュされた
        // 行の`plainText`は上記の合成レンダリング由来で、`plainText
        // QuoteMarkerPatterns`と確実には一致しない形をしていることがある。
        // `plainText`をまず試し、マーカーが見つからない時だけ(独立に
        // キャッシュされ、この問題の影響を受けない)`html`でも試す —
        // どちらが実際に採用されたかを`sourceKind`としてログへ残す
        // (`QuoteStripper.separatingQuotedText(plainText:html:isReply:)`の
        // doc comment参照。ロジックはそちらと同じだが、ログ用に採用元を
        // ここで直接追う)。
        let plainSplit: QuoteStripper.SeparatedText? = plainText.flatMap { text in
            guard !text.isEmpty else { return nil }
            return QuoteStripper.separatingQuotedText(fromPlainText: text, isReply: isReply)
        }
        let separated: QuoteStripper.SeparatedText?
        let sourceKind: String
        if let plainSplit, plainSplit.detectedMarker != nil {
            separated = plainSplit
            sourceKind = "plain"
        } else if let html, !html.isEmpty, case let htmlSplit = QuoteStripper.separatingQuotedText(fromHTML: html), htmlSplit.detectedMarker != nil {
            separated = htmlSplit
            sourceKind = plainSplit == nil ? "html" : "html-fallback"
        } else {
            separated = plainSplit ?? (html.flatMap { markup in markup.isEmpty ? nil : QuoteStripper.separatingQuotedText(fromHTML: markup) })
            sourceKind = plainSplit != nil ? "plain" : (html != nil ? "html" : "none")
        }
        // `plainText`/`html`が両方とも非`nil`だが空文字列だった場合だけ、
        // ここで`separated`が`nil`になりうる(上のガードは`nil`か否かしか
        // 見ていない)。
        guard let separated else { return nil }
        // Task #134: #105/#122/#128で3度踏んだ罠(`.debug`/`.info`は`log
        // collect`のアーカイブに残らない — `docs/verify.md`参照)を避け、
        // 切り分け用ログは`.notice`で書く。
        Self.summaryInputLogger.notice("sourceTextForSummary: messageId=\(messageId, privacy: .public) source=\(sourceKind, privacy: .public) isReply=\(isReply, privacy: .public) newTextLength=\(separated.newText.count, privacy: .public) quotedTextLength=\(separated.quotedText.count, privacy: .public) detectedMarker=\(separated.detectedMarker ?? "none", privacy: .public)")
        // `sourceTextForTranslation()`と同じ安全網: `QuoteStripper`のHTML
        // 経路はすでに`HTMLTextExtractor`を通しているが、プレーンテキスト
        // 側は生のマークアップが混じっていた場合に備えてもう一度通す
        // (no-opになるのが通常ケース)。
        let newText = HTMLTextExtractor.plainText(fromHTML: separated.newText)
        guard !newText.isEmpty else { return nil }
        return SummaryInputBuilder.build(newText: newText, hasQuotedContext: !separated.quotedText.isEmpty)
    }

    /// Task #148: `summarySheet`の「再生成」Menuの2択が渡す`sentenceCount`
    /// (■要約パートのみに効く — `FoundationModelsTranslationService
    /// .summarizeInstructions`のdoc comment参照)。通常側は`summarizeLongText`
    /// 自身のデフォルト(2)と同じ値をここでも明示しておく — 「詳しく要約」の
    /// `detailedSummarySentenceCount`と対で並べておいた方が、この2つが
    /// 対応する2択であることがコード上でも分かりやすいため。`10`は
    /// `summarizeInstructions`側の`detailedSentenceCountThreshold`(6)を
    /// 超える値 — 詳細版向けの文言分岐が確実に効く。
    private static let standardSummarySentenceCount = 2
    private static let detailedSummarySentenceCount = 10

    /// `AISummaryBar`の「要約」/「再生成」ボタンの行き先 — ソーステキストは
    /// `sourceTextForSummary()`(`sourceTextForTranslation()`に`QuoteStripper`
    /// を足したもの、そのdoc comment参照)。翻訳と違って結果を永続キャッシュ
    /// しない (`MessageTranslator`のような専用のキャッシュ層を要約のためだけ
    /// に新設するのは、このバッチの範囲に対して過大と判断した — 同じメッセ
    /// ージを開き直すたびに再生成になるが、要約はボタンを押した時だけ動く
    /// 手動機能なので許容範囲) — 出力言語は
    /// `LocalizationSettingsStore.effectiveLanguageCode`に合わせる (英語
    /// 表示なら英語要約、それ以外は日本語要約)。`summarize`ではなく
    /// `summarizeLongText`を呼ぶ — 長文メールが8192トークンのコンテキスト
    /// 上限を超えて失敗する翻訳と同じ問題を要約も踏みうるため
    /// (`TranslationChunker`のdoc comment参照)、事前分割+map-reduceで
    /// 安全な長さに保つ。
    ///
    /// Task #148 (「詳しく要約」): `detailed`は`summarySheet`のMenuの2番目
    /// の選択肢からのみ`true`で渡る。この`Bool`自体はどこにも永続化しない
    /// (指示どおり「モードは保持しない」) — 次にこのメッセージを開いた
    /// ときや、次に「再生成」を押したときは常に既定 (通常) から始まる。
    private func requestSummary(message: MessageRecord, detailed: Bool = false) {
        guard summaryTask == nil else { return }
        aiState.summaryState = .summarizing
        let translator = environment.translationService
        let targetLanguage: TranslationLanguage = LocalizationSettingsStore.effectiveLanguageCode == "en" ? .english : .japanese
        let sentenceCount = detailed ? Self.detailedSummarySentenceCount : Self.standardSummarySentenceCount
        summaryTask = Task {
            // Task #138 追加報告: `showsSummaryButton`は本文取得が失敗した
            // 状態(`bodyRecord == nil`, `errorMessage != nil`)でも出る
            // (`syncAIFeaturesState()`のdoc comment参照) — その状態でタップ
            // された時は、要約を諦める前にもう一度だけ本文取得を試みる。
            if bodyRecord == nil {
                await retryBodyFetchForSummary(message: message)
            }
            guard !Task.isCancelled else { return }
            guard let sourceText = sourceTextForSummary() else {
                aiState.summaryState = .failed("本文を取得できませんでした。しばらくしてからもう一度お試しください。")
                summaryTask = nil
                return
            }
            do {
                let result = try await translator.summarizeLongText(sourceText, targetLanguage: targetLanguage, sentenceCount: sentenceCount)
                guard !Task.isCancelled else { return }
                aiState.summaryState = .summarized(result)
            } catch {
                guard !Task.isCancelled else { return }
                // `.userFacingMessage`（`TranslationServiceError`のケースが
                // 判別できる時のみ）— 生の`"\(error)"`(Swiftのenum dump、
                // 例: `failed(message: "...")`)をそのまま表示していたのを
                // 修正 (実機での「AI要約が壊れている」報告の一因)。
                if let serviceError = error as? TranslationServiceError {
                    aiState.summaryState = .failed(serviceError.userFacingMessage)
                } else {
                    aiState.summaryState = .failed(error.localizedDescription)
                }
            }
            summaryTask = nil
        }
    }

    /// `requestSummary(message:)`が`bodyRecord == nil`(取得失敗済み、または
    /// まだ一度も取得していない)のままタップされた時の一度きりの再試行 —
    /// `load()`の`fetchBodyOverNetwork`失敗分岐と同じ経路を辿るが、成功時に
    /// `bodyRecord`/`errorMessage`/`aiState`(`syncAIFeaturesState()`経由で
    /// `showsTranslationButton`も)をこの場で更新する点が違う: `load()`の
    /// 完了を待たず、要約ボタンをタップした瞬間に即座に反映したいため。
    /// 失敗時は何もしない — 呼び出し元の`guard let sourceText =
    /// sourceTextForSummary()`が`nil`のまま拾って`.failed`にする。
    private func retryBodyFetchForSummary(message: MessageRecord) async {
        do {
            try await fetchBodyOverNetwork(message: message)
            guard let fetched = try await fetchBodyRecord(messageId: messageId) else { return }
            bodyRecord = fetched
            errorMessage = nil
            markAsReadIfNeeded()
            syncAIFeaturesState()
        } catch {
            // ベストエフォート — 失敗はそのまま`sourceTextForSummary() ==
            // nil`として上の呼び出し元に伝わる。
        }
    }
}

/// Task #71「メールの背景を常に白に」: the plain-text-rendering side of the
/// setting — `content`'s HTML branch bakes the equivalent directly into the
/// loaded document's own CSS (`HTMLDocumentBuilder.wrap`'s
/// `forceLightBackgroundStyle`), since a `WKWebView`'s rendering is governed
/// by that document's CSS `color-scheme`/`prefers-color-scheme`, not by
/// SwiftUI's environment. Plain text (and its translated variant,
/// `TranslatedBodyView`) has no such document to inject CSS into — it's
/// ordinary SwiftUI `Text`, whose `.primary`/`OtegamiColor` semantic colors
/// resolve per the environment's `colorScheme` instead. `.colorScheme(.light)`
/// is the standard SwiftUI tool for "force this subtree to resolve semantic
/// colors as light, regardless of the system/app-wide appearance"; paired
/// with an explicit white background (nothing in these two branches paints
/// one on its own — they rely on whatever's behind them, normally
/// `OtegamiColor.background`, dark in dark mode) so "白背景+濃色文字" holds
/// even though nothing here declares an *explicit* text color the way the
/// HTML branch's CSS does.
private extension View {
    @ViewBuilder
    func otegamiForceLightBackground(_ enabled: Bool) -> some View {
        if enabled {
            self
                .colorScheme(.light)
                .background(Color.white)
        } else {
            self
        }
    }
}
