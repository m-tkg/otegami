import Foundation
import SwiftUI
import OtegamiCore
import OtegamiStore
import TranslationEngine
import os

extension MessageView {
    // MARK: - Translation (design-phase-3, 1i)

    /// Task #64 (根治): distinguishes "the HTML web view's translation
    /// controller was never connected (a wiring bug)" from
    /// `HTMLTranslationController`'s own `translationLogger` (`HTMLMessageView
    /// .swift`), which only ever logs a *connected* controller's own
    /// extraction/JS-bridge failures — the two loggers cover disjoint
    /// failure modes on purpose, so a real occurrence of either is
    /// unambiguous in `log stream` output.
    private static let translationWiringLogger = Logger(subsystem: "com.mtkg.otegami", category: "HTMLTranslationDiagnostic")

    func resetTranslationState() {
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

    /// Called once per `load()`, after `bodyRecord` is populated (every
    /// exit path in `load()` calls this) — only actually starts a
    /// translation when every precondition holds: an English message, the
    /// device can translate at all, the "英文を自動で翻訳" setting is on
    /// (1l), and there's a non-empty cache-key-eligible `messageId`. Manual
    /// translation (the bar's "翻訳"/"再試行" button, when auto-translate is
    /// off or a previous attempt failed) goes through the same
    /// `requestTranslation(message:)` this calls into.
    func kickoffTranslationIfNeeded(message: MessageRecord) {
        // design-phase-3: deliberately *stricter* than `shouldShowTranslationBar`
        // (Task #138: that gate dropped its language check entirely — the
        // bar now shows for every message, language-independent — see its
        // doc comment). Auto-translating on a confirmed-non-English message
        // would silently run the engine against text the user never asked
        // to have translated; showing the bar and letting them tap "翻訳"
        // themselves for that case is the safer default.
        //
        // Task #159 (実機報告「明らかに英語の Okta 通知メールが
        // `NLLanguageRecognizer`に`pl`(ポーランド語)と誤判定される」):
        // before this task, this guard required an *exact* `detectedLanguage
        // == "en"` match — a confident-but-wrong non-English guess (this
        // real-device report's `"pl"`) silently suppressed auto-translate
        // for a genuinely English mail, with no visible error (the always-
        // enabled manual button was the only way to get exactly the same
        // translation regardless of this gate's outcome — `requestTranslation`
        // itself hardcodes `sourceLanguage: .english` unconditionally,
        // never actually reading `detectedLanguage`). Loosened to "anything
        // *other than* a confident Japanese guess" — the same "loosen an
        // over-strict language gate" fix already established in this
        // codebase for a different gate (`docs/translation.md`'s "翻訳可能
        // 判定の緩和" — `isEnglishMessage`'s `"en"`-or-`nil` relaxation), and
        // now safe here too in a way it wasn't before Task #159:
        // `AppleTranslationService` auto-detects the *real* source language
        // at the moment it actually translates (`source: nil` — that
        // type's own doc comment, Task #159 point 4), so a false-positive
        // kickoff on genuinely non-English, non-Japanese text no longer
        // risks a silently-mistranslated result the way blindly assuming
        // English with the old Foundation Models engine would have — worst
        // case is a redundant translate attempt whose real detected source
        // just isn't English, handled the same as any other translation.
        guard aiFeaturesEnabled else { return }
        guard message.detectedLanguage != "ja" else { return }
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
    func requestTranslation(message: MessageRecord) {
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
                // 2026-07-30 (Phase 5続報、実機 eml 再現: Okta通知メールの
                // table レイアウトHTML — `<p>`が1つも無く本文が`<td>`直下の
                // テキストノード): このメッセージでは
                // `extractTranslatableTexts()`が実質空の`texts`を返し、一方
                // `bodyRecord.plainText`(またはHTMLからの`HTMLTextExtractor`
                // 抽出)には翻訳可能な本文が存在した。DOM抽出が実際に何も
                // 拾えなかった (または拾えても短すぎてエンジンが言語判定
                // できなかった) 場合に限り、plain 本文へフォールバックして
                // 再試行する — HTML表示のレイアウト保持は諦めるが、翻訳
                // 自体は失敗させない。
                //
                // 2026-07-30 再訂正 (f7b623f 適用後の実機再報告): 当初は
                // `result`が`MessageTranslator.noTranslatableContentMessage`
                // という**特定の文言**と完全一致するかで判定していたが、
                // 同じ根本原因 (実質空/短すぎる入力) が Apple 側の
                // `unableToIdentifyLanguage`経由で「翻訳元の言語を判定
                // できませんでした」という**別の文言**として表面化した実機
                // ケースをすり抜けた。`MessageTranslationState
                // .insufficientInput` (`TranslationServiceError
                // .isInsufficientInput`由来、型で分類) を見るよう修正 —
                // 将来また新しい言い回しのバリエーションが増えても文字列
                // 比較に頼らない。それ以外の失敗理由 (ガードレール・未対応
                // 言語など) はフォールバックしても同じ結果になるだけなので、
                // 対象を`.insufficientInput`だけに絞ったまま。
                if case .insufficientInput = result, let fallbackSourceText = sourceTextForTranslation() {
                    let fallbackResult = await translator.translate(
                        messageId: messageId,
                        sourceText: fallbackSourceText,
                        sourceLanguage: .english,
                        targetLanguage: .japanese
                    )
                    guard !Task.isCancelled else { return }
                    aiState.translationState = fallbackResult
                    translateTask = nil
                    return
                }
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
}
