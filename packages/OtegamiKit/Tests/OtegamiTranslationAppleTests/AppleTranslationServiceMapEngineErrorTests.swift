import Testing
import Translation
@testable import OtegamiTranslation
@testable import OtegamiTranslationApple

/// 2026-07-30 (Phase 5再訂正, 実機ログ `9e28ea5`): `AppleTranslationService
/// .mapEngineError`は3回連続で「`TranslationError`のケース/生の`NSError`
/// コードから確信度の高い診断を推測する」→次の実機報告でその推測が誤りと
/// 判明、を繰り返した (`.notInstalled`→誤って「要ダウンロード」、
/// `unableToIdentifyLanguage`/Code=21→誤って「言語判定不能」)。最終的に
/// この関数は「Appleが明示的に名付けた、意図の疑いようがないケース
/// (unsupportedXxx) だけを信頼し、それ以外は全部中立に倒す」という方針へ
/// 単純化された — この方針そのものをロックインするテスト。
///
/// `TranslationLanguageLocaleTests`と同じ理由 (`TranslationLanguageLocaleTests`
/// のdoc comment参照) で、実際の`translate`/`prepareTranslation`呼び出しに
/// 必要な生の`TranslationSession`はこのテストプロセスでは作れない —
/// このスイートは`mapEngineError`という純粋関数だけを直接呼ぶ (`internal`に
/// した理由もそのため、`AppleTranslationService.swift`のdoc comment参照)。
@Suite("AppleTranslationService.mapEngineError")
struct AppleTranslationServiceMapEngineErrorTests {
    @Test("unsupportedSourceLanguage/unsupportedTargetLanguage/unsupportedLanguagePairing map to .languagePairUnsupported regardless of knownNotDownloaded")
    func unsupportedCasesMapToLanguagePairUnsupported() {
        let cases: [Error] = [
            TranslationError.unsupportedSourceLanguage,
            TranslationError.unsupportedTargetLanguage,
            TranslationError.unsupportedLanguagePairing,
        ]
        for error in cases {
            #expect(AppleTranslationService.mapEngineError(error, knownNotDownloaded: false) == .unavailable(.languagePairUnsupported))
            #expect(AppleTranslationService.mapEngineError(error, knownNotDownloaded: true) == .unavailable(.languagePairUnsupported))
        }
    }

    @Test("never returns .insufficientInput, no matter the error shape — that classification belongs solely to MessageTranslator's own empty-input pre-check now")
    func neverReturnsInsufficientInput() {
        let cases: [Error] = [
            TranslationError.unableToIdentifyLanguage,
            TranslationError.nothingToTranslate,
            NSError(domain: "Translation.TranslationError", code: 1),
            NSError(domain: "TranslationErrorDomain", code: 21),
            NSError(domain: "SomeOtherDomain", code: 999),
        ]
        for error in cases {
            #expect(!AppleTranslationService.mapEngineError(error, knownNotDownloaded: false).isInsufficientInput)
            #expect(!AppleTranslationService.mapEngineError(error, knownNotDownloaded: true).isInsufficientInput)
        }
    }

    @Test("unclassified errors map to .languagePackNotDownloaded only when knownNotDownloaded is true — never guessed from the error itself")
    func unclassifiedErrorsRespectKnownNotDownloaded() {
        // The exact real-device shape that caused this whole investigation:
        // a `prepareTranslation()`-originated failure (domain
        // "Translation.TranslationError", code 1) reaching here even though
        // `languagePairStatus` had already confirmed `.installed`
        // (`knownNotDownloaded: false`) — must NOT claim "not downloaded".
        let prepareShapedError = NSError(domain: "Translation.TranslationError", code: 1)
        #expect(AppleTranslationService.mapEngineError(prepareShapedError, knownNotDownloaded: false) == .failed(message: "翻訳に失敗しました（時間をおいて再試行してください）"))
        // Only when this app's own `LanguageAvailability` check already
        // confirmed the pair as `.supported` (not yet installed) does an
        // unclassified failure afterward get attributed to that.
        #expect(AppleTranslationService.mapEngineError(prepareShapedError, knownNotDownloaded: true) == .unavailable(.languagePackNotDownloaded))
    }

    @Test("the neutral fallback message never hardcodes an OS Settings path or names a specific diagnosis")
    func neutralMessageStaysNeutral() {
        guard case .failed(let message) = AppleTranslationService.mapEngineError(NSError(domain: "x", code: 0), knownNotDownloaded: false) else {
            Issue.record("expected .failed")
            return
        }
        #expect(!message.contains(">"))
        #expect(!message.contains("設定"))
        #expect(!message.contains("ダウンロード"))
        #expect(!message.contains("判定"))
    }
}
