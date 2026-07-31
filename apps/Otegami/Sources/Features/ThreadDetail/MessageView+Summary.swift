import Foundation
import SwiftUI
import OtegamiCore
import OtegamiStore
import OtegamiTranslation
import TranslationEngine
import os

extension MessageView {
    // MARK: - Task #55/#59/#88: AI要約 (要約シート)

    /// Task #55: where a generated summary is actually shown — a sheet
    /// (`aiState.onShowSummary`, called from `MessageDetailFooterToolbar`'s
    /// `summarizeButton` since Task #88) rather than the old bar's inline
    /// text, since a small toolbar icon has no room of its own to grow text
    /// into either. Handles all four `MessageSummaryState` cases so it reads
    /// sensibly regardless of when it's opened (including mid-generation,
    /// if a user re-opens it right after tapping the button).
    var summarySheet: some View {
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

    // MARK: - AI要約 (表示・操作改善バッチ)

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
    func requestSummary(message: MessageRecord, detailed: Bool = false) {
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
