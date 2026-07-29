import Foundation
import MailTransport
import MailTransportMailCore
import OtegamiStore
import os

/// 接続テスト失敗の実機切り分け用 (Yahoo! JAPAN ログイン失敗報告、2026-07-29)。
/// `docs/verify.md` の教訓どおり notice 未満は `log collect` に残らないため、
/// 生エラーを notice で記録する — パスワードは絶対にログへ含めない。
private let connectionTestLogger = Logger(subsystem: "com.mtkg.otegami", category: "ConnectionTest")

/// The outcome of `testIMAPConnection`/`testSMTPConnection` below: a
/// success flag plus a user-facing message, ready to feed straight into a
/// `Label(result.message, systemImage: result.succeeded ? "checkmark.circle"
/// : "xmark.octagon")`-shaped result banner.
struct AccountConnectionTestResult {
    var succeeded: Bool
    var message: String
}

/// Connect-then-disconnect IMAP test, shared by every account form's "接続
/// テスト" button (`AccountSetupView`, `ICloudAccountSetupView`, and the
/// account-edit screen `AccountEditView`) — pulled out so the three forms'
/// tests can't drift from each other (e.g. one forgetting
/// `mailTransportUserFacingMessage`'s failure classification, which
/// `ICloudAccountSetupView` did before this existed).
func testIMAPConnection(
    host: String,
    port: Int,
    security: ConnectionSecurityRecord,
    username: String,
    password: String
) async -> AccountConnectionTestResult {
    let config = IMAPConfig(host: host, port: port, security: security.mailTransportSecurity)
    let session = MailCoreIMAPSession(config: config)
    do {
        try await session.connect(auth: .password(username: username, password: password))
        await session.disconnect()
        return AccountConnectionTestResult(succeeded: true, message: "接続に成功しました。")
    } catch {
        connectionTestLogger.notice("IMAP connect test failed: host=\(host, privacy: .public):\(port) user=\(username, privacy: .private(mask: .hash)) error=\(String(describing: error), privacy: .public)")
        return AccountConnectionTestResult(
            succeeded: false,
            message: mailTransportUserFacingMessage(for: error, prefix: "接続に失敗しました")
        )
    }
}

/// SMTP counterpart of `testIMAPConnection` above — shared by
/// `AccountSetupView`'s "SMTP接続テスト" button and `AccountEditView`'s
/// equivalent (M6's `ICloudAccountSetupView` has no SMTP test button of its
/// own; iCloud's SMTP host is a fixed preset never exercised independently
/// of the IMAP one).
func testSMTPConnection(
    host: String,
    port: Int,
    security: ConnectionSecurityRecord,
    username: String,
    password: String
) async -> AccountConnectionTestResult {
    let config = SMTPConfig(host: host, port: port, security: security.mailTransportSecurity)
    let session = MailCoreSMTPSession(config: config)
    do {
        try await session.connect(auth: .password(username: username, password: password))
        await session.disconnect()
        return AccountConnectionTestResult(succeeded: true, message: "SMTP接続に成功しました。")
    } catch {
        connectionTestLogger.notice("SMTP connect test failed: host=\(host, privacy: .public):\(port) user=\(username, privacy: .private(mask: .hash)) error=\(String(describing: error), privacy: .public)")
        return AccountConnectionTestResult(
            succeeded: false,
            message: mailTransportUserFacingMessage(for: error, prefix: "SMTP接続に失敗しました")
        )
    }
}
