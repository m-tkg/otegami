import XCTest
@testable import OtegamiCore

/// Task #116「アカウント追加画面のプロバイダ拡充」: pins down the exact
/// host/port/security values the plan specifies for each new preset, so a
/// future accidental edit (typo'd host, swapped port) fails a fast unit
/// test instead of only surfacing as a broken "接続テスト" button deep in a
/// manual verify pass.
final class MailProviderPresetTests: XCTestCase {
    func testYahooPreset() {
        let preset = MailProviderPresets.yahoo
        XCTAssertEqual(preset.emailDomainHint, "yahoo.com")
        XCTAssertEqual(preset.imap.host, "imap.mail.yahoo.com")
        XCTAssertEqual(preset.imap.port, 993)
        XCTAssertEqual(preset.imap.security, .tls)
        XCTAssertEqual(preset.smtp.host, "smtp.mail.yahoo.com")
        XCTAssertEqual(preset.smtp.port, 465)
        XCTAssertEqual(preset.smtp.security, .tls)
    }

    func testYahooJapanPreset() {
        let preset = MailProviderPresets.yahooJapan
        XCTAssertEqual(preset.emailDomainHint, "yahoo.co.jp")
        XCTAssertEqual(preset.imap.host, "imap.mail.yahoo.co.jp")
        XCTAssertEqual(preset.imap.port, 993)
        XCTAssertEqual(preset.imap.security, .tls)
        XCTAssertEqual(preset.smtp.host, "smtp.mail.yahoo.co.jp")
        XCTAssertEqual(preset.smtp.port, 465)
        XCTAssertEqual(preset.smtp.security, .tls)
    }

    /// Exchange's host is deliberately blank (the user's own server, never
    /// knowable ahead of time) — only port/security are real presets.
    func testExchangePreset() {
        let preset = MailProviderPresets.exchange
        XCTAssertNil(preset.emailDomainHint)
        XCTAssertEqual(preset.imap.host, "")
        XCTAssertEqual(preset.imap.port, 993)
        XCTAssertEqual(preset.imap.security, .startTLS)
        XCTAssertEqual(preset.smtp.host, "")
        XCTAssertEqual(preset.smtp.port, 587)
        XCTAssertEqual(preset.smtp.security, .startTLS)
    }

    /// Every preset's `id` is unique — `AccountEntryRoute`/accessibility
    /// identifiers key off these, so a duplicate would silently make two
    /// buttons indistinguishable to XCUITest.
    func testPresetIdsAreUnique() {
        let ids = [MailProviderPresets.yahoo.id, MailProviderPresets.yahooJapan.id, MailProviderPresets.exchange.id]
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
