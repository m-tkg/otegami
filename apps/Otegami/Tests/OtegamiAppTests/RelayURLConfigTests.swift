import Testing
@testable import Otegami

/// `RelayURLConfig.isFeatureHidden(infoValue:)` は Info.plist の
/// `OTEGAMI_PUSH_FEATURE_HIDDEN` (xcconfig 展開後の文字列 "YES"/"NO") を
/// 解釈する純粋関数。厳密に "YES" の時だけ true になる。
@Suite("RelayURLConfig.isFeatureHidden")
struct RelayURLConfigTests {
    @Test
    func yesHidesTheFeature() {
        #expect(RelayURLConfig.isFeatureHidden(infoValue: "YES"))
    }

    @Test(arguments: ["NO", "", "yes", "true", "$(OTEGAMI_PUSH_FEATURE_HIDDEN)"])
    func otherStringsDoNotHideTheFeature(value: String) {
        #expect(!RelayURLConfig.isFeatureHidden(infoValue: value))
    }

    @Test
    func missingOrNonStringValueDoesNotHideTheFeature() {
        #expect(!RelayURLConfig.isFeatureHidden(infoValue: nil))
        #expect(!RelayURLConfig.isFeatureHidden(infoValue: true))
    }
}
