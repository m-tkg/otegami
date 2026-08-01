import Testing

/// `NotificationService.parsePayload(_:)` は push extension が受け取る
/// `userInfo` 辞書から `accountId`/`uidNext` を取り出すだけの純ロジック
/// (Task apps 層ユニットテストターゲット新設で `private` → `internal` に
/// 緩和してテストから到達可能にした)。正常系・欠損キー・型不一致の
/// 代表パターンだけを確認する。
///
/// このターゲット (`NotificationServiceTests`) は `NotificationService`
/// (app-extension) を `@testable import` するのではなく、
/// `NotificationService.swift` 自体をこのターゲットの `sources` にも
/// 追加して直接コンパイルしている (project.yml の `NotificationServiceTests`
/// ターゲットの doc comment 参照 — app-extension を TEST_HOST にする方法は
/// `xcodebuild test` の「Could not find test host」で失敗した)。そのため
/// `NotificationService` 型はこのファイルと同じモジュール内にあり、import
/// なしで直接参照できる。
@Suite("NotificationService.parsePayload")
struct NotificationServiceParsePayloadTests {
    @Test
    func parsesAccountIdAndUidNextWhenBothPresent() {
        let userInfo: [AnyHashable: Any] = ["accountId": "account-1", "uidNext": 42]

        let payload = NotificationService.parsePayload(userInfo)

        #expect(payload?.accountId == "account-1")
        #expect(payload?.uidNext == 42)
    }

    @Test
    func returnsNilWhenAccountIdIsMissing() {
        let userInfo: [AnyHashable: Any] = ["uidNext": 42]
        #expect(NotificationService.parsePayload(userInfo) == nil)
    }

    @Test
    func returnsNilWhenUidNextIsMissing() {
        let userInfo: [AnyHashable: Any] = ["accountId": "account-1"]
        #expect(NotificationService.parsePayload(userInfo) == nil)
    }

    @Test
    func returnsNilWhenUidNextHasTheWrongType() {
        // relay/APNs 側の不具合や将来のペイロード変更で `uidNext` が文字列に
        // なっていた場合など、型不一致は例外を投げず nil で握りつぶす。
        let userInfo: [AnyHashable: Any] = ["accountId": "account-1", "uidNext": "42"]
        #expect(NotificationService.parsePayload(userInfo) == nil)
    }
}
