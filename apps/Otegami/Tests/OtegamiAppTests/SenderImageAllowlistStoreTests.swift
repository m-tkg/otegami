import Foundation
import Testing
@testable import Otegami

/// `SenderImageAllowlistStore` — 送信者別のリモート画像許可リスト。
/// `UserDefaults(suiteName:)` の独立スイートを毎テストで作り直すので、
/// アプリ実体の `standard` にも並行実行中の他テストにも影響しない。
@Suite("Sender image allowlist store")
struct SenderImageAllowlistStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SenderImageAllowlistStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("add + contains は大文字小文字と前後空白を無視して一致する")
    func addAndContainsNormalizes() {
        let defaults = makeDefaults()
        SenderImageAllowlistStore.add(" News@Example.COM ", defaults: defaults)
        #expect(SenderImageAllowlistStore.contains("news@example.com", defaults: defaults))
        #expect(SenderImageAllowlistStore.contains("NEWS@EXAMPLE.COM", defaults: defaults))
        #expect(!SenderImageAllowlistStore.contains("other@example.com", defaults: defaults))
    }

    @Test("重複追加しても1件のまま")
    func addIsIdempotent() {
        let defaults = makeDefaults()
        SenderImageAllowlistStore.add("a@example.com", defaults: defaults)
        SenderImageAllowlistStore.add("A@example.com", defaults: defaults)
        #expect(SenderImageAllowlistStore.all(defaults: defaults) == ["a@example.com"])
    }

    @Test("remove は該当アドレスだけ外す")
    func removeOnlyTarget() {
        let defaults = makeDefaults()
        SenderImageAllowlistStore.add("a@example.com", defaults: defaults)
        SenderImageAllowlistStore.add("b@example.com", defaults: defaults)
        SenderImageAllowlistStore.remove("A@Example.com", defaults: defaults)
        #expect(SenderImageAllowlistStore.all(defaults: defaults) == ["b@example.com"])
    }

    @Test("空文字・空白のみは追加されない")
    func emptyAddressIgnored() {
        let defaults = makeDefaults()
        SenderImageAllowlistStore.add("   ", defaults: defaults)
        #expect(SenderImageAllowlistStore.all(defaults: defaults).isEmpty)
    }

    @Test("未設定キーは空リスト")
    func unsetKeyIsEmpty() {
        let defaults = makeDefaults()
        #expect(SenderImageAllowlistStore.all(defaults: defaults).isEmpty)
        #expect(!SenderImageAllowlistStore.contains("a@example.com", defaults: defaults))
    }
}
