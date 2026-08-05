import Testing
@testable import OtegamiTranslation

/// 2026-08-05 (実機フィードバック「要約ボタンがグレーアウトして押せない
/// ことがある」): `allowsUserInitiatedAttempt`の全ケースをカバーする —
/// この計算プロパティが Task #128/#138 の既定方針 (「隠して誤診断させる
/// より、押せるようにしてその場で失敗を見せる」) 通りに、`modelNotReady`
/// (一時状態)だけを`available`と同じ「試行を許可」側に倒し、それ以外の
/// unavailable理由 (ユーザーがアプリを離れない限り解消しない状態) は
/// 引き続き不許可のままであることを固定する。
@Suite("TranslationAvailability.allowsUserInitiatedAttempt")
struct TranslationAvailabilityTests {
    @Test("available allows a user-initiated attempt")
    func availableAllowsAttempt() {
        #expect(TranslationAvailability.available.allowsUserInitiatedAttempt)
    }

    @Test("unavailable(.modelNotReady) allows a user-initiated attempt — SystemLanguageModel isn't Observable, so a stale snapshot must not permanently disable the button")
    func modelNotReadyAllowsAttempt() {
        #expect(TranslationAvailability.unavailable(reason: .modelNotReady).allowsUserInitiatedAttempt)
    }

    @Test("every other unavailable reason does not allow a user-initiated attempt")
    func everyOtherUnavailableReasonDisallowsAttempt() {
        let reasonsThatStayDisabled: [TranslationUnavailableReason] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .languagePairUnsupported,
            .languagePackNotDownloaded,
            .other("some internal engine detail"),
        ]
        for reason in reasonsThatStayDisabled {
            #expect(!TranslationAvailability.unavailable(reason: reason).allowsUserInitiatedAttempt)
        }
    }
}
