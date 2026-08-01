import Foundation
import Observation
import OtegamiCore
import OtegamiTranslation

/// 2026-07-30 (実機フィードバック: 翻訳が理由不明のまま失敗し続ける報告が
/// 連続し、しかもユーザーが外出中で Mac が無く実機ログを採取できない場面
/// があった): `AppleTranslationService`の各呼び出し (`translate`/
/// `translateParagraphs`) が実際に何を送り成功/失敗したかを、この端末上の
/// UI (設定の「翻訳の診断」画面) から**ログ採取なしで**確認できるように
/// するための、直近の試行だけを憶えておく軽量な記録庫。
///
/// `os.Logger`と役割が重複するように見えるが別物 — `Logger`の出力は
/// Mac 経由の`log collect`/sysdiagnoseでしか読めない (`docs/verify.md`)。
/// これは**その場でスクリーンショット1枚で共有できる**ことが目的。F15の
/// 趣旨は変わらず維持: 本文そのものは一切保持しない、件数・文字数・文字種
/// 比率・エラーのdomain/code/型名/説明だけ。
///
/// `@MainActor`/`@Observable`: `TranslationSessionCoordinator`と同じ理由 —
/// SwiftUIの再描画と自然に噛み合わせるため。直近5件だけ保持 (無制限に
/// 貯めない)。
@available(iOS 18.0, macOS 15.0, *)
@MainActor
@Observable
public final class TranslationDiagnosticsStore {
    public struct Attempt: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let date: Date
        /// e.g. "translate" / "translateParagraphs" — which
        /// `AppleTranslationService` method this came from.
        public let kind: String
        public let elementCount: Int
        public let totalChars: Int
        /// `MessageTranslator.characterClassStats`-style summary (letters/
        /// digits/equals/other-symbol percentages) — never the text itself.
        public let characterClassSummary: String
        public let outcome: Outcome

        public enum Outcome: Sendable, Equatable {
            case success(resultChars: Int)
            case failure(domain: String, code: Int, type: String, description: String)
        }

        public init(date: Date = Date(), kind: String, elementCount: Int, totalChars: Int, characterClassSummary: String, outcome: Outcome) {
            self.id = UUID()
            self.date = date
            self.kind = kind
            self.elementCount = elementCount
            self.totalChars = totalChars
            self.characterClassSummary = characterClassSummary
            self.outcome = outcome
        }
    }

    /// 2026-07-30 (Task #203, 実機フィードバック「HTMLの構造が壊れている
    /// メールで言語判定に失敗する」— Okta 通知メール): a second, independent
    /// "recent attempts" record, alongside `Attempt` above but not merged
    /// into it — `MessageLanguageDetector.detectWithFallback`'s outcome
    /// shape (which of two *candidate texts* won, or neither) doesn't fit
    /// `Attempt.Outcome`'s success/failure-with-engine-error shape (there's
    /// no engine error here, just "no candidate was usable"). Reuses this
    /// store/screen rather than a new one for the same reason `Attempt`
    /// itself exists: "confirm from this screen, no `log collect` needed".
    public struct LanguageDetectionAttempt: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let date: Date
        /// `MessageLanguageDetector.characterClassSummary` of the
        /// `plainText` candidate, or `nil` when the message had none at
        /// all (no `messageBody.plainText`).
        public let plainTextSummary: String?
        /// Same, for the HTML candidate *after* `HTMLTextExtractor`
        /// extraction (i.e. what `detectWithFallback` actually fed the
        /// recognizer, not the raw markup) — `nil` when the message had no
        /// `messageBody.html`.
        public let htmlSummary: String?
        public let outcome: Outcome

        public enum Outcome: Sendable, Equatable {
            case detected(language: String, source: MessageLanguageDetector.TextSource)
            case undetected
        }

        public init(date: Date = Date(), plainTextSummary: String?, htmlSummary: String?, outcome: Outcome) {
            self.id = UUID()
            self.date = date
            self.plainTextSummary = plainTextSummary
            self.htmlSummary = htmlSummary
            self.outcome = outcome
        }
    }

    private static let maxAttempts = 5

    public private(set) var attempts: [Attempt] = []
    public private(set) var languageDetectionAttempts: [LanguageDetectionAttempt] = []

    public init() {}

    /// Newest first — `record` inserts at the front, `attempts` is already
    /// in the order a diagnostics screen wants to display.
    public func record(_ attempt: Attempt) {
        attempts.insert(attempt, at: 0)
        if attempts.count > Self.maxAttempts {
            attempts.removeLast(attempts.count - Self.maxAttempts)
        }
    }

    /// Same newest-first/`maxAttempts`-capped policy as `record(_:Attempt)`,
    /// kept in its own array (see `LanguageDetectionAttempt`'s doc comment
    /// for why it isn't merged into `attempts`).
    public func recordLanguageDetection(_ attempt: LanguageDetectionAttempt) {
        languageDetectionAttempts.insert(attempt, at: 0)
        if languageDetectionAttempts.count > Self.maxAttempts {
            languageDetectionAttempts.removeLast(languageDetectionAttempts.count - Self.maxAttempts)
        }
    }
}
