import Testing
@testable import OtegamiTranslation

/// Phase 5 (2026-07-30, real-device report: a raw `other("...")` dump
/// reached the user as a garbled, self-contradictory, un-actionable toast —
/// see `TranslationServiceError.userFacingMessage`'s doc comment). These
/// cover the one property this whole task exists to fix: every case must
/// produce a short, fixed, curated Japanese string — never an interpolation
/// of an engine's raw error text or a case's own `String(describing:)`
/// dump.
@Suite("TranslationServiceError.userFacingMessage")
struct TranslationServiceErrorTests {
    @Test("every TranslationUnavailableReason case has its own short, fixed Japanese message — never a raw enum/string dump")
    func unavailableReasonsHaveDedicatedMessages() {
        let cases: [TranslationUnavailableReason] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .languagePairUnsupported,
            .languagePackNotDownloaded,
            .other("some internal engine detail that must never reach the user verbatim"),
        ]
        for reason in cases {
            let message = TranslationServiceError.unavailable(reason).userFacingMessage
            #expect(!message.isEmpty)
            // The whole point of this task: the raw Swift enum description
            // (`other("...")`, `deviceNotEligible`, ...) must never leak
            // into the user-facing string.
            #expect(!message.contains("other("))
            #expect(!message.contains(String(describing: reason)) || String(describing: reason).count < 4)
        }
    }

    @Test(".other's internal detail string never appears in the user-facing message")
    func otherReasonDoesNotLeakItsInternalString() {
        let internalDetail = "TranslationErrorDomain Code=21, batch of 0 inputs"
        let message = TranslationServiceError.unavailable(.other(internalDetail)).userFacingMessage
        #expect(!message.contains(internalDetail))
        #expect(!message.contains("Code=21"))
    }

    @Test("none of the fixed unavailable-reason messages hardcode an OS Settings navigation path")
    func noHardcodedSettingsPath() {
        // 2026-07-30 correction: a previous version of this wording hardcoded
        // "設定 > 一般 > 言語と地域", which had already moved on the reporting
        // user's actual device (this exact menu has relocated across iOS
        // versions before) — no wording anywhere in this type may name a
        // specific menu path again.
        let cases: [TranslationUnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
            .languagePairUnsupported, .languagePackNotDownloaded, .other("x"),
        ]
        for reason in cases {
            let message = reason.userFacingMessage
            #expect(!message.contains(">"))
            #expect(!message.contains("一般"))
            #expect(!message.contains("言語と地域"))
        }
    }

    @Test("languagePackNotDownloaded reads as a confirmed, actionable download message")
    func languagePackNotDownloadedMessage() {
        #expect(TranslationUnavailableReason.languagePackNotDownloaded.userFacingMessage == "翻訳用の言語データが未ダウンロードです")
    }

    @Test("other falls back to a neutral retry message, not a confident-but-possibly-wrong diagnosis")
    func otherReasonIsNeutral() {
        let message = TranslationUnavailableReason.other("anything").userFacingMessage
        #expect(!message.contains("ダウンロード"))
        #expect(message.contains("再試行") || message.contains("時間をおいて"))
    }

    // MARK: - Phase 5続報 (2026-07-30): .insufficientInput classification —
    // added after a real-device report showed the same root cause (empty/
    // too-short input) surfacing as a *different* message
    // ("翻訳元の言語を判定できませんでした") than the one a prior fix's
    // string-comparison fallback checked for. These lock in that the
    // classification is queryable by case/property, not by comparing
    // rendered text.

    @Test("isInsufficientInput is true only for .insufficientInput, false for every other case")
    func isInsufficientInputPredicate() {
        #expect(TranslationServiceError.insufficientInput(message: "x").isInsufficientInput)
        #expect(!TranslationServiceError.failed(message: "x").isInsufficientInput)
        #expect(!TranslationServiceError.tooLong(message: "x").isInsufficientInput)
        #expect(!TranslationServiceError.contentBlocked(message: "x").isInsufficientInput)
        #expect(!TranslationServiceError.unavailable(.deviceNotEligible).isInsufficientInput)
    }

    @Test("insufficientInput's userFacingMessage passes its message straight through, same as .failed")
    func insufficientInputMessagePassthrough() {
        #expect(TranslationServiceError.insufficientInput(message: "翻訳元の言語を判定できませんでした").userFacingMessage == "翻訳元の言語を判定できませんでした")
    }

    // MARK: - Phase 5続報2 (2026-07-30): real-device report of a literal
    // doubled toast — "翻訳に失敗しました: 翻訳に失敗しました（時間をおいて
    // 再試行してください）". `MessageDetailFooterToolbar.translateFootnote`
    // is the one place that prepends "翻訳に失敗しました: " to whatever
    // `MessageTranslationState.failureMessage` becomes (that prepending
    // itself isn't unit-testable — it's a private computed property on a
    // SwiftUI View — so this locks in the other half of the fix instead:
    // no message this package hands to that prefix may itself start with
    // the same clause).

    @Test("no TranslationUnavailableReason message starts with the footer UI's own '翻訳に失敗しました' prefix clause")
    func noReasonMessageStartsWithTheFooterPrefix() {
        let cases: [TranslationUnavailableReason] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
            .languagePairUnsupported, .languagePackNotDownloaded, .other("x"),
        ]
        for reason in cases {
            #expect(!reason.userFacingMessage.hasPrefix("翻訳に失敗しました"))
        }
    }

    @Test("TranslationServiceError.failed/.insufficientInput/.tooLong/.contentBlocked messages never start with the footer UI's own prefix clause either")
    func noErrorCaseMessageStartsWithTheFooterPrefix() {
        let cases: [TranslationServiceError] = [
            .failed(message: "時間をおいて再試行してください"),
            .insufficientInput(message: "翻訳できる本文が見つかりませんでした"),
            .tooLong(message: "x"),
            .contentBlocked(message: "x"),
        ]
        for error in cases {
            #expect(!error.userFacingMessage.hasPrefix("翻訳に失敗しました"))
        }
    }
}
