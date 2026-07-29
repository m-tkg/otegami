import Foundation
import SwiftUI
import QuickLook
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import GRDB
import OtegamiTranslation
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
    @Environment(AppEnvironment.self) private var environment
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
    @State private var manualPreferPlainText: Bool?
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

    @State private var message: MessageRecord?
    @State private var bodyRecord: MessageBodyRecord?
    /// M8: the mailbox path `message` lives in — resolved once during
    /// `load()` (same `MailboxRecord` lookup `fetchBodyOverNetwork` already
    /// does for the body itself) and kept around so the attachment section
    /// and `HTMLMessageView`'s cid image resolver don't each need to
    /// re-derive it.
    @State private var mailboxPath: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var attachments: [AttachmentRecord] = []
    /// Task #94: owns the calendar-invite card's own state (ICS download/
    /// parse result, RSVP send-in-flight) independently of
    /// `CalendarInviteSectionView`'s own lifecycle — see
    /// `CalendarInviteLoader`'s doc comment for why that matters.
    @State private var calendarInviteLoader = CalendarInviteLoader()
    /// M8: which attachment (by id) is currently being downloaded on-demand
    /// — drives that row's spinner. A `Set` rather than a single optional
    /// id since a user could plausibly tap two attachment rows in quick
    /// succession.
    @State private var fetchingAttachmentIds: Set<Int64> = []
    /// M8, per-card since Task #76: keyed by attachment id so a fetch
    /// failure shows on the specific `AttachmentCardRow` that failed rather
    /// than one shared message below the whole list (see
    /// `attachmentSection`'s doc comment).
    @State private var attachmentErrorMessages: [Int64: String] = [:]
    /// M8: the attachment currently shown in the `.quickLookPreview` sheet
    /// — `nil` means no preview is presented.
    @State private var previewURL: URL?

    // MARK: - Translation (design-phase-3, 1i)

    /// Task #64 (根治): distinguishes "the HTML web view's translation
    /// controller was never connected (a wiring bug)" from
    /// `HTMLTranslationController`'s own `translationLogger` (`HTMLMessageView
    /// .swift`), which only ever logs a *connected* controller's own
    /// extraction/JS-bridge failures — the two loggers cover disjoint
    /// failure modes on purpose, so a real occurrence of either is
    /// unambiguous in `log stream` output.
    private static let translationWiringLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLTranslationDiagnostic")

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

    @AppStorage(TranslationSettingsStore.autoTranslateEnglishKey) private var autoTranslateEnglish = TranslationSettingsStore.defaultAutoTranslateEnglish
    /// I「設定画面の再構成」→「メールビューア」の「AI 機能の on/off (翻訳・要約を
    /// まとめて)」— see `AIFeaturesSettingsStore`'s doc comment. Master
    /// switch for both `TranslationBar` (`shouldShowTranslationBar`) and
    /// `AISummaryBar` (`body`'s `if aiFeaturesEnabled` below).
    @AppStorage(AIFeaturesSettingsStore.enabledKey) private var aiFeaturesEnabled = AIFeaturesSettingsStore.defaultEnabled

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
    @State private var aiState = MessageDetailAIFeaturesState()
    /// `TranslatedBodyView.originalOverrides` — per-paragraph long-press
    /// state, reset alongside everything else in `load()`.
    @State private var translationParagraphOverrides: Set<Int> = []
    @State private var translateTask: Task<Void, Never>?
    /// 1i「HTMLメールもレイアウトを保持したまま翻訳」— the live handle
    /// `HTMLMessageView` reports via `onTranslationControllerReady`,
    /// non-`nil` only while an `HTMLMessageView` for *this* message is
    /// actually mounted. `requestTranslation(message:)`'s HTML branch reads
    /// this to collect the document's text nodes; `nil` there (view torn
    /// down mid-flight, or this message isn't HTML) just means "nothing to
    /// translate right now" rather than a crash.
    @State private var htmlTranslationController: HTMLTranslationController?

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
    private func syncAIFeaturesState() {
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
            onToggleHTMLText: { manualPreferPlainText = isShowingHTML }
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
    private var isHTMLMessage: Bool {
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
    private var isShowingHTML: Bool {
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

    // MARK: - Attachments (M8)

    /// Inline (`cid:`-referenced) parts are excluded — those render inside
    /// `HTMLMessageView`'s body itself (via the `otegami-cid://` scheme
    /// handler), so listing them again here as a separate downloadable row
    /// would be confusing/redundant. Task #84: recognized calendar-invite
    /// technical parts (the unnamed `text/calendar` alternative, the
    /// `invite.ics`-style attachment) are excluded too, same rationale as
    /// Gmail/Spark — `CalendarInviteSectionView` above already shows the
    /// event as a card, so re-listing its raw MIME carrier(s) as plain
    /// "here's a file" rows would just be confusing technical noise, not
    /// useful to the user. Only genuine "here's a file" parts show up in
    /// this list.
    private var listableAttachments: [AttachmentRecord] {
        attachments.filter { !$0.isInline && !Self.isCalendarInvitePart($0) }
    }

    /// Task #66/#84: the MIME part driving `CalendarInviteSectionView`
    /// above. A real Google Calendar invite carries the event as *two*
    /// separate parts — an unnamed `text/calendar; method=REQUEST` part
    /// (nested as a third sibling of `multipart/alternative`'s `text/plain`/
    /// `text/html`, not the `multipart/mixed`-level sibling the original
    /// fixture modeled) plus a separately named `application/ics`
    /// (`invite.ics`) attachment — so either alone finding a match isn't
    /// enough; `CalendarInviteAttachmentMatching.primaryInvitePart` picks
    /// whichever single one should feed the card, in preference order (see
    /// its own doc comment). Still listed in `attachmentSection` too before
    /// Task #84 (now hidden via `listableAttachments` above) — this
    /// computed property is purely "does an invite card exist", not about
    /// what else is visible below it.
    private var calendarInviteAttachment: AttachmentRecord? {
        CalendarInviteAttachmentMatching.primaryInvitePart(
            among: attachments,
            mimeType: { $0.mimeType },
            mimeSubtype: { $0.mimeSubtype },
            filename: { $0.filename }
        )
    }

    private static func isCalendarInvitePart(_ attachment: AttachmentRecord) -> Bool {
        CalendarInviteAttachmentMatching.isInvitePart(
            mimeType: attachment.mimeType, mimeSubtype: attachment.mimeSubtype, filename: attachment.filename
        )
    }

    /// Task #76 (Spark 参考画像を基にしたカード表示への刷新):
    /// 「添付ファイル N 個」ヘッダ + `AttachmentCardRow` のカード列。行の
    /// 中身は `AttachmentCardRow` (別ファイル) に切り出し済み — CLAUDE.md の
    /// 「`ForEach`の中身は独立した`View`型に切り出す」というCI型チェック
    /// タイムアウト対策のルール参照。エラーはカードごと
    /// (`attachmentErrorMessages[id]`) に持つよう変更 — 以前は
    /// リスト全体の下に1つだけ表示していたが (`missingCredentialAwareErrorMessage`
    /// が返す「(Google認証が原因の可能性)」的な文言も含め)、複数の添付が
    /// ある時にどれの取得が失敗したのか分からなくなるため、失敗した
    /// カード自身にエラー文言を出す設計に変更した。
    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            Text("添付ファイル \(listableAttachments.count) 個")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
                .accessibilityIdentifier("messageDetail.attachmentsHeader")
            ForEach(listableAttachments) { attachment in
                let attachmentId = attachment.id ?? 0
                AttachmentCardRow(
                    attachment: attachment,
                    isDownloading: fetchingAttachmentIds.contains(attachmentId),
                    errorMessage: attachmentErrorMessages[attachmentId],
                    onTap: { Task { await openAttachment(attachment) } }
                )
            }
        }
        .accessibilityIdentifier("messageDetail.attachments")
    }

    /// Tapping an attachment row: already-downloaded (`localPath` points at
    /// a file that still exists) opens QuickLook immediately; otherwise
    /// fetches it first (with `fetchingAttachmentIds` driving that row's
    /// spinner — plan: "タップ → 未取得ならスピナー付き取得 → QuickLook プレビュー"),
    /// then opens it. `.quickLookPreview($previewURL)` (SwiftUI's own
    /// modifier, available on both iOS and macOS since it was introduced)
    /// is used over a hand-rolled `QLPreviewController`/`QLPreviewPanel`
    /// wrapper per platform — simpler, and it's exactly the single-URL case
    /// this view needs (one attachment previewed at a time, no "next/
    /// previous" browsing across the whole attachment list).
    private func openAttachment(_ attachment: AttachmentRecord) async {
        guard let attachmentId = attachment.id else { return }
        attachmentErrorMessages[attachmentId] = nil

        if let localPath = attachment.localPath, FileManager.default.fileExists(atPath: localPath) {
            previewURL = URL(fileURLWithPath: localPath)
            return
        }
        guard !fetchingAttachmentIds.contains(attachmentId) else { return }

        fetchingAttachmentIds.insert(attachmentId)
        defer { fetchingAttachmentIds.remove(attachmentId) }

        do {
            let updated = try await fetchAttachmentOverNetwork(attachment)
            if let index = attachments.firstIndex(where: { $0.id == attachmentId }) {
                attachments[index] = updated
            }
            if let localPath = updated.localPath {
                previewURL = URL(fileURLWithPath: localPath)
            } else {
                attachmentErrorMessages[attachmentId] = "添付ファイルの取得に失敗しました。"
            }
        } catch {
            attachmentErrorMessages[attachmentId] = await missingCredentialAwareErrorMessage(prefix: "添付ファイルの取得に失敗しました", underlyingError: error)
        }
    }

    private func fetchAttachmentOverNetwork(_ attachment: AttachmentRecord) async throws -> AttachmentRecord {
        guard let message, let mailboxPath else { throw MailTransportError.notConnected }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            // Bug fix: this used to discard whatever `auth(for:)` actually
            // threw and replace it with a fixed "資格情報が見つかりません",
            // which meant a Keychain read failure, an expired OAuth
            // refresh token, and "no GOOGLE_OAUTH_CLIENT_ID configured"
            // all showed the exact same message — indistinguishable from
            // the user-visible side, and useless for diagnosing a real
            // report against it. Preserving `error`'s own description
            // (`AuthResolutionError`/`TokenStoreError` are both named
            // enums, and `KeychainCredentialStore.KeychainError` already
            // has a real `CustomStringConvertible` description) keeps this
            // still wrapped as a `MailTransportError.authenticationFailed`
            // (so existing call sites that only branch on the error *case*
            // keep working) while no longer hiding *why*.
            throw MailTransportError.authenticationFailed(underlyingDescription: "\(error)")
        }
        return try await environment.syncCoordinator.fetchAttachment(
            attachment, messageUID: message.uid, mailboxPath: mailboxPath, account: account, auth: auth
        )
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

    // MARK: - Loading

    /// UITest-only reproduction hook for a real-device bug report: a
    /// `.password` account whose Keychain item genuinely goes missing (not
    /// the M11 "just synced from iCloud, hasn't caught up yet" case) used
    /// to fail body-fetch with an opaque, hardcoded error message and no
    /// account-level banner anywhere — see `AppEnvironment.auth(for:)`'s
    /// `.password` branch and this file's `fetchBodyOverNetwork`/
    /// `fetchAttachmentOverNetwork` doc comments for the actual fixes.
    /// XCUITest can't otherwise force this precondition (there's no UI
    /// action that deletes a Keychain item out from under a working
    /// account), so this mirrors `ComposerView
    /// .attachUITestFixtureIfRequested`'s pattern: a no-op unless a
    /// specific launch-environment flag is set, in which case it deletes
    /// this message's own account's stored password right before `load()`
    /// would otherwise use it — reproducing the exact failure a real
    /// device hit, deterministically, on demand.
    ///
    /// Also resets *this* message's `bodyState`/cached `messageBody` row —
    /// confirmed by an actual test run necessary: `SyncEngine.BodyFetcher
    /// .prefetchRecent` already caches recently-synced messages' bodies in
    /// the background, so a message opened soon after account setup can
    /// already have `bodyState == .fetched` by the time this test taps it,
    /// which makes `load()` take the "read straight from the local
    /// `messageBody` row" branch and never call `fetchBodyOverNetwork`/
    /// `auth(for:)` again at all — the credential deletion above would
    /// otherwise go unnoticed, not because the bug is fixed but because
    /// this particular message never re-authenticates in the first place.
    private func deleteCredentialIfUITestRequested() async {
        guard ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DELETE_CREDENTIAL"] == "1" else { return }
        try? environment.credentialStore.deletePassword(forAccountId: accountId)
        let messageId = messageId
        try? await environment.database.dbWriter.write { db in
            guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return }
            record.bodyState = .notFetched
            try record.update(db)
            try MessageBodyRecord.deleteOne(db, key: messageId)
        }
    }

    private func load() async {
        errorMessage = nil
        bodyRecord = nil
        message = nil
        mailboxPath = nil
        attachments = []
        attachmentErrorMessages = [:]
        previewURL = nil
        manualPreferPlainText = nil
        calendarInviteLoader.reset()
        resetTranslationState()
        resetSummaryState()
        // Task #59: hides both floating buttons immediately while this
        // message (re-)loads — `syncAIFeaturesState()`'s `message != nil`
        // guard is what actually does that; every exit path below that sets
        // a real `message` calls this again once `aiFeaturesEnabled`/
        // `shouldShowTranslationBar` have something meaningful to read.
        syncAIFeaturesState()
        await deleteCredentialIfUITestRequested()

        guard let loadedMessage = try? await environment.database.dbWriter.read({ db in
            try MessageRecord.fetchOne(db, key: messageId)
        }) else {
            errorMessage = "メッセージが見つかりません。"
            return
        }
        message = loadedMessage
        mailboxPath = try? await environment.database.dbWriter.read { db in
            try MailboxRecord.fetchOne(db, key: loadedMessage.mailboxId)?.path
        }
        attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []

        if loadedMessage.bodyState == .fetched, let existing = try? await fetchBodyRecord(messageId: messageId) {
            bodyRecord = existing
            let backfilledMessage = await backfillDetectedLanguageIfNeeded(message: loadedMessage, body: existing)
            markAsReadIfNeeded()
            // Task #59: after `backfillDetectedLanguageIfNeeded`, not
            // before — `shouldShowTranslationBar` reads `message
            // .detectedLanguage`, which that call may have just filled in.
            syncAIFeaturesState()
            kickoffTranslationIfNeeded(message: backfilledMessage)
            loadCalendarInviteIfNeeded(messageUID: loadedMessage.uid)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetchBodyOverNetwork(message: loadedMessage)
            bodyRecord = try await fetchBodyRecord(messageId: messageId)
            // M2's body fetch also replaces `attachment` rows for this
            // message (`BodyFetcher.fetchBody`) — re-read so a message
            // opened for the first time shows its attachment list too, not
            // just the (empty, pre-fetch) snapshot read above.
            attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []
            // design-phase-3: `SyncEngine.BodyFetcher` also sets
            // `detectedLanguage` as part of this same fetch — `loadedMessage`
            // predates it (read *before* the fetch even started). Task #138
            // dropped the translation *bar*'s own dependency on this field
            // (`shouldShowTranslationBar`'s doc comment), but
            // `kickoffTranslationIfNeeded(message:)` below still gates
            // auto-translate on a *confirmed* `detectedLanguage == "en"`, so
            // the freshly re-read row (not the stale `loadedMessage`) still
            // matters here — a message opened for the first time (the
            // common case: body not fetched yet) would otherwise never
            // auto-translate on its first open.
            let refreshed = (try? await environment.database.dbWriter.read { db in
                try MessageRecord.fetchOne(db, key: messageId)
            }) ?? loadedMessage
            message = refreshed
            markAsReadIfNeeded()
            syncAIFeaturesState()
            kickoffTranslationIfNeeded(message: refreshed)
            loadCalendarInviteIfNeeded(messageUID: refreshed.uid)
        } catch {
            // Offline (or any other network failure): fall back to
            // whatever's already in the local database — a `.fetching`
            // message left mid-flight by a previous attempt can still have
            // no row yet, in which case there's genuinely nothing to show.
            if let existing = try? await fetchBodyRecord(messageId: messageId) {
                bodyRecord = existing
                markAsReadIfNeeded()
                syncAIFeaturesState()
                kickoffTranslationIfNeeded(message: loadedMessage)
                loadCalendarInviteIfNeeded(messageUID: loadedMessage.uid)
            } else {
                errorMessage = await missingCredentialAwareErrorMessage(prefix: "本文の取得に失敗しました", underlyingError: error)
            }
        }
    }

    /// Task #147 (実機報告「本文の後着で要約/翻訳ボタンが有効化されない」):
    /// `load()`は開いた時点の一回きりの取得で完結する — その後にローカル
    /// DBへ届いた本文 (`SyncEngine`のバックグラウンドプリフェッチが書き
    /// 込むケース、または`load()`自身の`fetchBodyOverNetwork`と競合して
    /// いた別経路が後から完了するケース) を`load()`自身は二度と観測しない
    /// ため、`bodyRecord`が`nil`のまま`syncAIFeaturesState()`が再実行されず
    /// 要約/翻訳ボタンがアプリ再起動まで有効化されなかった。
    ///
    /// `messageBody`行への`ValueObservation`を張って、この`MessageView`が
    /// 画面上にある間 (`.task(id: messageId)`— `ThreadDetailView`のアコー
    /// ディオンで折りたたまれれば`load()`と一緒に破棄される、#136のアコー
    /// ディオンとの整合) ずっと監視し続ける。`CalendarInviteLoader`(#94) が
    /// 選んだ「独立した`@Observable`クラス、view lifecycle 非依存」という
    /// 形までは踏襲していない — こちらは`bodyRecord`という既存の`@State`
    /// (と、それに連動する`content`の表示切り替え・`syncAIFeaturesState()`
    /// 等の既存メソッド群) をそのまま使い回す方が、新しい並行の状態保持先
    /// を作るより小さな変更で済むため。「届いた値を実際に反映する価値が
    /// あるか」の判定だけは`MessageBodyObservationGate`(`SyncEngine`) に
    /// 切り出してあり、SwiftUIのview lifecycleから独立してテストできる —
    /// `MessageReadMarker`(#96) と同じ「app targetのprivateメソッドから
    /// 純粋ロジックだけ`SyncEngine`へ抜き出す」方針。
    private func observeBodyRecordChanges() async {
        let observation = ValueObservation.tracking { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                await applyObservedBodyRecordIfNeeded(fetched)
            }
        } catch {
            // ベストエフォート — この監視自体が失敗しても`load()`が既に
            // 表示している内容 (取得済み本文、または「取得中」/エラー) は
            // そのまま残る。
        }
    }

    /// `observeBodyRecordChanges()`の1配信ごとの反映 — `MessageBodyObservationGate
    /// .shouldApply(current:incoming:)`が`false`を返す間 (本文行がまだ無い、
    /// または前回と実質同じ内容の再配信) は何もしない。`true`のときだけ
    /// `bodyRecord`を更新し、`load()`が「本文がその場で取得できた」ときに
    /// 辿るのと同じ後段パイプライン (言語検出の補完・既読化・AI機能ボタンの
    /// 状態同期・自動翻訳キックオフ) を再実行する — いずれも既存の冪等な
    /// ガード付きメソッド (`markSeen`の「既に`\Seen`か」、`requestTranslation`
    /// の「`translateTask == nil`か」等) なので、`load()`自身の初回反映と
    /// このタイミングが重なっても二重の副作用にはならない。
    private func applyObservedBodyRecordIfNeeded(_ fetched: MessageBodyRecord?) async {
        guard MessageBodyObservationGate.shouldApply(current: bodyRecord, incoming: fetched) else { return }
        guard let fetched else { return }
        bodyRecord = fetched
        // Task #64 (実機報告「まだ読み込み中のように見える」)と同じ理由 —
        // 本文がこの観測経由で埋まったなら、`load()`のネットワーク取得が
        // 失敗して立てた古い`errorMessage`はもう実情に合わない。
        errorMessage = nil
        guard let currentMessage = message else {
            // `message`(メタデータ行)自体がまだ読めていない極端な競合状態
            // — `syncAIFeaturesState()`は`bodyRecord`の更新だけでも安全に
            // 呼べる (`hasSettledBodyState`のガード参照) が、`kickoffTranslationIfNeeded`
            // 等`MessageRecord`が要る後段はここでは呼べないので、次に`load()`
            // か別の配信が`message`を埋めるまで待つ。
            syncAIFeaturesState()
            return
        }
        // Task #147のスコープは要約/翻訳ボタンの有効化 + 本文表示の更新まで
        // — `attachments`/カレンダー招待カードはこの観測 (`messageBody`
        // テーブルのみ追跡) では更新されない別状態のままなので、
        // `loadCalendarInviteIfNeeded`はここでは呼ばない (呼んでも古い
        // (空の可能性がある)`attachments`しか見えず実質no-opなだけで、
        // 「動いているように見えて実は何もしていない」誤解を生むだけ)。
        let backfilled = await backfillDetectedLanguageIfNeeded(message: currentMessage, body: fetched)
        markAsReadIfNeeded()
        syncAIFeaturesState()
        kickoffTranslationIfNeeded(message: backfilled)
    }

    /// Task #94: kicks off (or logs the absence of) the calendar-invite
    /// card's load, using whichever `attachments` this call happens after —
    /// every call site above re-reads `attachments` from the database
    /// immediately before calling this, so `calendarInviteAttachment`
    /// (computed from that same `@State`) reflects the message's current,
    /// real attachment rows. `CalendarInviteLoader.load` itself is a no-op
    /// if this attachment is already loaded/loading, so calling this more
    /// than once per message (offline fallback + a later successful retry,
    /// for instance) is harmless.
    private func loadCalendarInviteIfNeeded(messageUID: Int64) {
        let candidate = calendarInviteAttachment
        CalendarInviteLoader.logRecognition(messageId: messageId, attachments: attachments, primary: candidate)
        guard let candidate, let mailboxPath else { return }
        calendarInviteLoader.load(
            attachment: candidate,
            messageId: messageId,
            messageUID: messageUID,
            mailboxPath: mailboxPath,
            accountId: accountId,
            environment: environment
        )
    }

    /// Real-device bug report (`docs/icloud-sync.md`'s "重複挿入バグ"):
    /// opening a message on a cloud-inserted `.password` account with no
    /// Keychain credential on this device yet used to fail with an opaque
    /// `"本文の取得に失敗しました: authenticationFailed: missingCredential"` — every
    /// word of which is either meaningless to a non-technical user or, in
    /// the case of "authenticationFailed", actively misleading (it reads
    /// like a wrong password, not "this device doesn't have a password to
    /// try at all"). `AppEnvironment.auth(for:)` already flips
    /// `AccountRecord.needsReauth` the moment this happens (both for this
    /// M11 case and for a `.password` account whose Keychain item genuinely
    /// went missing), so this re-reads the account row fresh (not the
    /// `environment.accounts` cache, whose `ValueObservation` update isn't
    /// guaranteed to have landed by the instant this catch block runs) and
    /// swaps in an actionable message — the same "資格情報を待っています" /
    /// "再接続" condition `AccountsSettingsView` already shows a banner and
    /// button for — instead of leaking the raw error. Falls back to the raw
    /// error for every other failure (offline, server error, ...), where
    /// there's no single fix to point at.
    private func missingCredentialAwareErrorMessage(prefix: String, underlyingError: Error) async -> String {
        let refreshedAccount = try? await environment.database.dbWriter.read { db in
            try AccountRecord.fetchOne(db, key: accountId)
        }
        guard refreshedAccount?.needsReauth == true, refreshedAccount?.authType == .password else {
            return "\(prefix): \(underlyingError)"
        }
        return "\(prefix): この端末にはこのアカウントの資格情報がありません。設定 → アカウントの「再接続」からパスワードを確認してください。"
    }

    private func fetchBodyRecord(messageId: Int64) async throws -> MessageBodyRecord? {
        try await environment.database.dbWriter.read { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
    }

    private func fetchAttachmentRecords(messageId: Int64) async throws -> [AttachmentRecord] {
        try await environment.database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
        }
    }

    private func fetchBodyOverNetwork(message: MessageRecord) async throws {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            // Bug fix: this used to discard whatever `auth(for:)` actually
            // threw and replace it with a fixed "資格情報が見つかりません",
            // which meant a Keychain read failure, an expired OAuth
            // refresh token, and "no GOOGLE_OAUTH_CLIENT_ID configured"
            // all showed the exact same message — indistinguishable from
            // the user-visible side, and useless for diagnosing a real
            // report against it. Preserving `error`'s own description
            // (`AuthResolutionError`/`TokenStoreError` are both named
            // enums, and `KeychainCredentialStore.KeychainError` already
            // has a real `CustomStringConvertible` description) keeps this
            // still wrapped as a `MailTransportError.authenticationFailed`
            // (so existing call sites that only branch on the error *case*
            // keep working) while no longer hiding *why*.
            throw MailTransportError.authenticationFailed(underlyingDescription: "\(error)")
        }
        guard let mailboxPath else {
            throw MailTransportError.mailboxNotFound(path: "")
        }
        try await environment.syncCoordinator.fetchBody(
            for: message,
            mailboxPath: mailboxPath,
            account: account,
            auth: auth
        )
    }

    /// Reflects `\Seen` in the local database immediately, then enqueues
    /// the absolute flag state for `OpQueueProcessor` to mirror to the
    /// server (M3) and makes a best-effort replay attempt right away —
    /// harmless if offline, the op just waits for the next successful
    /// connection (foreground IDLE reconnect, pull-to-refresh, ...).
    ///
    /// Task #96: the actual DB write/enqueue now lives in `SyncEngine
    /// .MessageReadMarker.markSeen` (testable without SwiftUI at all) —
    /// this just wraps it in the same "own unstructured `Task { }`, best-
    /// effort replay after" shape as before. Deliberately reads
    /// `messageId`/`accountId` (the view's `let` constants, always
    /// available) rather than `self.message` (a `@State` that may still be
    /// `nil` the instant `.onAppear` fires, since `.onAppear` and `.task`
    /// aren't ordered against each other) — every call site, including the
    /// ones still inside `load()`'s post-body-fetch branches, is safely
    /// idempotent thanks to `markSeen`'s own "already `\Seen`?" guard.
    private func markAsReadIfNeeded() {
        let messageId = messageId
        let accountId = accountId
        Task {
            do {
                let didMark = try await environment.database.dbWriter.write { db in
                    try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
                }
                guard didMark else { return }
                guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort: the local flag update simply doesn't happen
                // if this fails.
            }
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

    // MARK: - Translation (design-phase-3, 1i)

    private func resetTranslationState() {
        translateTask?.cancel()
        translateTask = nil
        aiState.translationState = .none
        aiState.translationShowOriginal = false
        translationParagraphOverrides = []
    }

    /// Plain text handed to `MessageTranslator`/`summarizeLongText`
    /// regardless of body kind — the engine only ever translates/
    /// summarizes plain strings (`docs/translation.md`), so an HTML body is
    /// flattened the same way `ComposerView`'s reply quoting already does
    /// (`HTMLTextExtractor`, no `WKWebView` needed just to extract text).
    ///
    /// Real-device report (design-phase-3 follow-up): summarizing an HTML
    /// mail sometimes returned the raw markup verbatim instead of a
    /// summary. This method already ran HTML through `HTMLTextExtractor`
    /// whenever `bodyRecord.plainText` was empty — the gap was messages
    /// whose server-reported `text/plain` part is itself non-empty but
    /// (some real-world senders duplicate/mislabel content this way) still
    /// contains literal markup. Every candidate string, not just the HTML
    /// fallback, now goes through `HTMLTextExtractor.plainText` before
    /// being returned — a no-op for genuinely plain text (nothing matching
    /// `<...>` to strip), and a safety net for the mislabeled case either
    /// way.
    private func sourceTextForTranslation() -> String? {
        guard let bodyRecord else { return nil }
        let candidate: String?
        if let plainText = bodyRecord.plainText, !plainText.isEmpty {
            candidate = plainText
        } else if let html = bodyRecord.html, !html.isEmpty {
            candidate = html
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let normalized = HTMLTextExtractor.plainText(fromHTML: candidate)
        return normalized.isEmpty ? nil : normalized
    }

    /// Opportunistically fills in (or corrects) `message.detectedLanguage`
    /// for a message whose body was already fetched (so no network call
    /// needed here — just local text already in `body`). Real-device report
    /// (design-phase-3 follow-up): the translation bar/button never appeared
    /// for genuinely English mail, traced to exactly this —
    /// `SyncEngine.BodyFetcher` only sets `detectedLanguage` at the moment
    /// a body is *first* fetched, and never re-runs for a message whose
    /// `bodyState` is already `.fetched` (`prefetchRecent`'s `notFetched`
    /// filter), so any message fetched before this field was added (or
    /// whose short/ambiguous body legitimately didn't yield a confident
    /// guess at the time) stayed `nil` forever. This runs once per message
    /// open, using the same `MessageLanguageDetector`
    /// `SyncEngine.BodyFetcher` itself uses, and persists the result so
    /// later opens (and list-level features keyed on `detectedLanguage`,
    /// e.g. `SearchFilterOption`) see the same backfilled value.
    ///
    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール, hypothesis (2)): this used to be a strict no-op
    /// whenever `detectedLanguage` was already non-`nil`, on the reasoning
    /// that "a confidently-non-English message shouldn't be re-guessed every
    /// time it's opened". That reasoning has a gap: `detectedLanguage` being
    /// non-`nil` only ever meant *some* past detection ran and committed a
    /// value — not that the value was actually correct. A build that stored
    /// a wrong non-`nil` guess (e.g. an early version whose sample text
    /// wasn't yet cleaned the same way `resolvePlainText`/this method's own
    /// `sample` below are — a stray HTML/CSS-heavy sample can plausibly
    /// throw `NLLanguageRecognizer` off) would leave that wrong value stuck
    /// forever, indistinguishable from a *correctly* detected non-English
    /// message — exactly the same permanently-hidden-button symptom as the
    /// `nil` case this method already existed to fix, just with a non-`nil`
    /// value instead of a missing one. Now always re-detects from the
    /// current body text and only writes back when the fresh result
    /// actually *disagrees* with what's stored — a no-op (same `update`
    /// skip, same "don't hammer the DB every open") for the overwhelmingly
    /// common case where the stored value already matches, and self-healing
    /// for the mismatched case without needing a full re-sync or app
    /// reinstall.
    private func backfillDetectedLanguageIfNeeded(message: MessageRecord, body: MessageBodyRecord) async -> MessageRecord {
        guard message.id != nil else { return message }

        let sample: String?
        if let plainText = body.plainText, !plainText.isEmpty {
            sample = plainText
        } else if let html = body.html, !html.isEmpty {
            let extracted = HTMLTextExtractor.plainText(fromHTML: html)
            sample = extracted.isEmpty ? nil : extracted
        } else {
            sample = nil
        }
        // A failed re-detection (`sample == nil`, or the recognizer itself
        // couldn't commit to a language this time) never overwrites an
        // existing value — only a confident, *different* result does.
        guard let sample, let detected = Self.detectLanguageLocally(sample), detected != message.detectedLanguage else {
            return message
        }

        var updated = message
        updated.detectedLanguage = detected
        let toPersist = updated
        try? await environment.database.dbWriter.write { db in
            try toPersist.update(db)
        }
        self.message = updated
        return updated
    }

    /// See `SyncEngine.BodyFetcher.detectLanguage`'s identical helper —
    /// duplicated rather than shared across the `SyncEngine`/app module
    /// boundary purely to avoid a new cross-target dependency for one
    /// `#if canImport(NaturalLanguage)` wrapper; both call the same
    /// `MessageLanguageDetector.detect` underneath.
    private static func detectLanguageLocally(_ text: String) -> String? {
        #if canImport(NaturalLanguage)
        MessageLanguageDetector.detect(text)
        #else
        nil
        #endif
    }

    /// Called once per `load()`, after `bodyRecord` is populated (every
    /// exit path in `load()` calls this) — only actually starts a
    /// translation when every precondition holds: an English message, the
    /// device can translate at all, the "英文を自動で翻訳" setting is on
    /// (1l), and there's a non-empty cache-key-eligible `messageId`. Manual
    /// translation (the bar's "翻訳"/"再試行" button, when auto-translate is
    /// off or a previous attempt failed) goes through the same
    /// `requestTranslation(message:)` this calls into.
    private func kickoffTranslationIfNeeded(message: MessageRecord) {
        // design-phase-3: deliberately *stricter* than `shouldShowTranslationBar`
        // (Task #138: that gate dropped its language check entirely — the
        // bar now shows for every message, language-independent — see its
        // doc comment). Auto-translating on a mere "maybe English, couldn't
        // tell" guess (or a confirmed-non-English message) would silently
        // run the on-device model against possibly-non-English text with no
        // way for the user to have opted out first; showing the bar and
        // letting them tap "翻訳" themselves for that ambiguous/non-English
        // case is the safer default, while a *confirmed*
        // English message still auto-translates exactly as before.
        guard aiFeaturesEnabled else { return }
        guard message.detectedLanguage == "en" else { return }
        guard LocalizationSettingsStore.effectiveLanguageCode != "en" else { return }
        guard environment.isTranslationAvailable else { return }
        guard autoTranslateEnglish else { return }
        requestTranslation(message: message)
    }

    /// Shared by the automatic kickoff above and the translation bar's
    /// manual "翻訳"/"再試行" button — `MessageTranslator.translate`/
    /// `translateHTMLTextNodes` already check their own persisted cache
    /// first (`docs/translation.md`'s キャッシュ方針), so calling this again
    /// after a previous success (e.g. re-opening the same message) is cheap
    /// rather than re-running the on-device model.
    ///
    /// 1i「HTMLメールもレイアウトを保持したまま翻訳」: branches on the same
    /// `isHTMLMessage`/`isShowingHTML` pair `content` uses to decide which
    /// body view to render at all — an HTML message currently shown as HTML
    /// *and* whose `htmlTranslationController` is actually connected
    /// collects its DOM text nodes and goes through `translateHTMLTextNodes`;
    /// everything else (plain-text body, an HTML message switched to text
    /// view, or — Task #128 — an HTML message whose controller never
    /// connected) goes through the original flattened-string `translate`
    /// path. See the `htmlTranslationController`-nil branch below for why
    /// that last case is a fallback rather than a failure now.
    private func requestTranslation(message: MessageRecord) {
        guard translateTask == nil else { return }
        let messageId = messageId
        let translator = environment.messageTranslator

        if isHTMLMessage, isShowingHTML, let htmlTranslationController {
            aiState.translationState = .translating
            translateTask = Task {
                // `extractTranslatableTexts()` always runs even when
                // `translateHTMLTextNodes` is about to hit its own cache and
                // ignore its `texts` argument entirely (`MessageTranslator
                // .translateHTMLTextNodes`'s doc comment) — collecting is
                // cheap (idempotent DOM stamping, no engine call) and this
                // keeps the two call sites symmetric rather than needing a
                // separate "peek the cache first" API just to skip it.
                //
                // Task #61: `nil` (not just an empty array) means the DOM
                // text-node extraction itself failed (`extractTranslatableTexts`'s
                // doc comment) — silently proceeding with an empty `texts`
                // array here used to make `translateHTMLTextNodes` "succeed"
                // translating zero paragraphs, which looked identical to a
                // dead tap (no visible change, no error) from the user's
                // side. Task #128: unlike the (now-removed) "controller is
                // nil" case below, a *connected* web view whose extraction
                // itself fails doesn't get the plain-text fallback — a DOM
                // walk failing on a live web view is a genuinely unexpected
                // condition (`HTMLTranslationController.translationLogger`
                // already logs the JS-side detail), not the "never even
                // connected" case the fallback below targets, so this still
                // surfaces a real, visible failure instead of silently
                // downgrading to a different (layout-losing) translation
                // path the user didn't ask for.
                guard let texts = await htmlTranslationController.extractTranslatableTexts() else {
                    guard !Task.isCancelled else { return }
                    aiState.translationState = .failed(message: "本文の読み込みに失敗しました。もう一度お試しください。")
                    translateTask = nil
                    return
                }
                guard !Task.isCancelled else { return }
                let result = await translator.translateHTMLTextNodes(
                    messageId: messageId,
                    texts: texts,
                    sourceLanguage: .english,
                    targetLanguage: .japanese
                )
                guard !Task.isCancelled else { return }
                aiState.translationState = result
                translateTask = nil
            }
            return
        }
        if isHTMLMessage, isShowingHTML {
            // Task #61/#64 originally landed here whenever `htmlTranslationController`
            // was still `nil` (`HTMLMessageView.onAppear` hadn't fired yet, a
            // brief race — or, after #64's identity fix, a genuine wiring
            // regression) and just showed a fixed, dead-end failure message.
            // Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」—
            // Okta のサインオン通知メール): `syncAIFeaturesState()` no longer
            // hides the translate button while waiting for this controller
            // (see its doc comment), so this path is now reachable on a
            // genuine tap, not just a theoretical race — and there's a
            // strictly better option than failing outright:
            // `sourceTextForTranslation()` flattens `bodyRecord.html` via
            // `HTMLTextExtractor` exactly the way the plain-text branch below
            // already does, entirely independent of `WKWebView`/
            // `HTMLTranslationController`. Falling back to it here means a
            // controller that never connects (or connects too slowly) costs
            // only the layout-preserving HTML overlay (1i) — the message
            // still gets translated, just as a flattened block of text
            // instead of in place.
            Self.translationWiringLogger.error("requestTranslation: htmlTranslationController is nil for messageId=\(messageId, privacy: .public) — falling back to plain-text translation")
        }
        guard let sourceText = sourceTextForTranslation() else { return }
        aiState.translationState = .translating
        translateTask = Task {
            let result = await translator.translate(
                messageId: messageId,
                sourceText: sourceText,
                sourceLanguage: .english,
                targetLanguage: .japanese
            )
            guard !Task.isCancelled else { return }
            aiState.translationState = result
            translateTask = nil
        }
    }

    // MARK: - AI要約 (表示・操作改善バッチ)

    private func resetSummaryState() {
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

/// Task #102 (3パート要約: ■要約/■伝えたいこと/■アクション): renders the
/// generated summary text with its "■"-prefixed label lines in a heavier
/// weight than the surrounding body text, so the three parts stay visually
/// distinct without a heavier UI change (a dedicated per-part layout,
/// markdown parsing, ...) than the sheet already had. Splits on newlines
/// and checks each line's own prefix rather than parsing any real
/// structure — the label lines are a small, fixed set coming from
/// `FoundationModelsTranslationService.summarizeInstructions`'s own
/// literal "■要約"/"■伝えたいこと"/"■アクション" strings, not user input, so
/// a plain prefix check is enough. `Text(verbatim:)`, not plain `Text`, for
/// the same reason `sourceTextForSummary()`'s callers use it elsewhere in
/// this file (`AccountFilterChip`'s doc comment): a dynamic string routed
/// through `LocalizedStringKey` gets Markdown-interpreted, which turns a
/// bare email address into a `mailto:` link.
private struct SummaryText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(line.hasPrefix("■") ? OtegamiFont.body().bold() : OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
            }
        }
        .textSelection(.enabled)
    }
}

/// Task #59 (実機フィードバック「要約/翻訳のフローティングアイコンが常に
/// 左下固定であってほしいのに、HTML本文と一緒にスクロールしてしまう」):
/// the shared, `@Observable` handle that originally let `ThreadDetailView`'s
/// own top-level `overlay` — *outside* its `ScrollView`, so it stays pinned
/// to the screen regardless of scroll position — render and drive the
/// 要約/翻訳 buttons that `MessageView` (nested three levels down:
/// `ThreadDetailView` → `ThreadMessageRow` → `MessageView`, and itself now
/// potentially much taller than the screen post-Task #58) still fully owns
/// the behavior of.
///
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに
/// 入れて」): the overlay/floating rendering (`MessageDetailFloatingButtons`,
/// `AISummaryFloatingButton`, `TranslationFloatingButton`) is gone —
/// `MessageDetailFooterToolbar`'s `summarizeButton`/`translateButton` render
/// from this same handle instead, forwarded through unchanged
/// (`ThreadDetailView.footerToolbar`'s `aiFeaturesState:` parameter). The
/// class itself, and the reason it has to live *outside* this potentially
/// very tall view rather than as plain `@State` here, are otherwise
/// unchanged by that move — a footer toolbar pinned via `.safeAreaInset
/// (edge: .bottom)` is just as much "outside this view's own frame" as the
/// old top-level `overlay` was.
///
/// `MessageView` is the only writer of every property here (via
/// `syncAIFeaturesState()`/`requestSummary(message:)`/`requestTranslation
/// (message:)`) and the only place `onSummarize`/`onShowSummary`/
/// `onTranslate` are assigned; `MessageDetailFooterToolbar`'s rendering only
/// ever *reads* these properties and *calls* these closures — never assigns
/// state directly — mirroring how `HTMLTranslationController` already draws
/// that same "owns the behavior / exposes a live handle" line for a
/// different feature in this same file. A plain `@Observable` class (not
/// `ObservableObject`/a `Binding` pair) because SwiftUI's `@Observable`
/// tracks property-level reads from *any* view that touches them, regardless
/// of where in the tree that view physically lives — exactly what's needed
/// to let an ancestor three levels up (now: a sibling of the whole
/// expanded-row subtree) react to state a descendant mutates.
@MainActor
@Observable
final class MessageDetailAIFeaturesState {
    var showsSummaryButton = false
    var summaryState: MessageSummaryState = .none
    var showsTranslationButton = false
    var translationState: MessageTranslationState = .none
    /// The 訳文/原文 toggle `MessageDetailFooterToolbar`'s `translateButton`
    /// drives directly (`handleTranslateTap`'s `aiFeaturesState
    /// .translationShowOriginal.toggle()`) — `false` (訳文) is the handoff's
    /// explicit default ("既定は訳文"), unchanged since this state first
    /// moved out of `MessageView`.
    var translationShowOriginal = false
    var isTranslationAvailable = false
    var onSummarize: () -> Void = {}
    var onShowSummary: () -> Void = {}
    var onTranslate: () -> Void = {}
}
