import SwiftUI

/// Task #55: replaced the persistent "AI要約"バー (which, together with the
/// old `TranslationBar`, used to occupy two full-width rows under the header
/// of *every* opened message, translated or not) with a single small
/// floating button (`AISummaryFloatingButton`).
///
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに
/// 入れて」): that floating button — and its sibling
/// `TranslationFloatingButton` (`TranslationBar.swift`, deleted entirely by
/// this same batch since it had nothing left in it once its one struct was
/// removed) — moved into `MessageDetailFooterToolbar`'s `summarizeButton`/
/// `translateButton`. This file now only holds the state enum both that
/// toolbar and `MessageView`'s own summary sheet (`summarySheet`) still
/// share.
///
/// `MessageTranslationState`(`TranslationEngine`パッケージ側)と同じ形だが、
/// 要約はキャッシュもリトライ判定もない単発の非同期呼び出しでしかないため、
/// アプリ側にこの軽量な列挙型を独自に置いている (パッケージを跨いだ共有型に
/// するほどの複雑さがない)。
enum MessageSummaryState: Equatable {
    case none
    case summarizing
    case summarized(String)
    case failed(String)

    var isSummarizing: Bool {
        if case .summarizing = self { return true }
        return false
    }

    var isSummarized: Bool {
        if case .summarized = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
