import SwiftUI

/// Task #153 (スレッド表示タイトル + スレッド全体 AI 要約): the whole-thread
/// counterpart to `MessageSummaryState` (`AISummaryBar.swift`) — same
/// 4-case shape (none/summarizing/summarized/failed), but drives
/// `ThreadDetailView`'s own toolbar button/sheet instead of a single
/// expanded message's. Kept as its own type rather than reusing
/// `MessageSummaryState` directly: the two states describe genuinely
/// different operations (one message's ■要約/■伝えたいこと/■アクション vs. a
/// whole thread's ■経緯/■現状 digest, see `TranslationService
/// .summarizeThreadDigest`'s doc comment) owned by different views
/// (`MessageView` vs. `ThreadDetailView`), and giving them independent
/// types lets either evolve (e.g. a future "詳しく要約" variant for one but
/// not the other) without the other having to carry unused cases.
enum ThreadSummaryState: Equatable {
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
}
