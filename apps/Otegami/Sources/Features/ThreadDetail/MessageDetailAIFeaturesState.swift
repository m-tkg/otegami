import SwiftUI
import TranslationEngine

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
    /// Task #159: `AppEnvironment.isSummarizationAvailable`, mirrored here
    /// the same way `isTranslationAvailable` above already is —
    /// `MessageDetailFooterToolbar.isSummarizeEnabled` reads this instead of
    /// `isTranslationAvailable` now that the two features are backed by
    /// different engines (`FoundationModelsTranslationService` vs.
    /// `AppleTranslationService`) with different availability stories.
    var isSummarizationAvailable = false
    var onSummarize: () -> Void = {}
    var onShowSummary: () -> Void = {}
    var onTranslate: () -> Void = {}
}
