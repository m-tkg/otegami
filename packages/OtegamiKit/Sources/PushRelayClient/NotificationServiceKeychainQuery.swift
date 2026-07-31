import Foundation

/// Task #216 (実機バグ: ある Yahoo! アカウントだけ通知拡張の「Resolving
/// Credential」が `noCredential` で 0ms 失敗 — IMAP 接続にすら到達しない):
/// `NotificationService.password(forAccountId:)`
/// (`apps/Otegami/NotificationService/NotificationService.swift`) の
/// `SecItemCopyMatching` クエリが `kSecAttrSynchronizable` を一切指定して
/// いなかった。指定しない場合、Apple のドキュメント上の既定動作は
/// **非同期化 (non-synchronizable) の項目しか返さない**——一方アプリ本体の
/// `KeychainCredentialStore` (`apps/Otegami/Sources/Support/
/// KeychainCredentialStore.swift`) は M11 (iCloud Keychain 同期) 以降、
/// `setPassword` が書くすべての項目 (新規保存・編集画面の接続テストに
/// よる再保存のどちらも) を `kSecAttrSynchronizable = true` にする。結果、
/// M11 以降に一度でも (再) 保存されたパスワードはこの Extension から
/// 一切見えなくなっていた——未編集のまま残っていた旧アカウントだけが
/// 非同期化項目のままだったので偶然見え続けていた。詳細は
/// `docs/architecture.md` の Known pitfalls (j.) 参照。
///
/// `Security`/`SecItemCopyMatching` そのものは `swift test`
/// (Linux 含む) から呼べない上、実際のクエリは `[String: Any]` という
/// `Equatable` でない型を経由する——`apps/Otegami/NotificationService`は
/// そもそも `swift test` 到達不能な Extension target でもある
/// (`KeychainCredentialStore`のトップレベル doc comment が同じ理由で
/// クエリ構築ロジックを「inspection で検証する」に留めている前例と同じ
/// 制約)。この型はその制約を回避するため、**どのサービス名を・どういう
/// 順で・どんな属性 (同期状態を問わず一致させるかどうか) で試すか**という
/// 「純粋な事実」だけを `Security` に依存しない値として切り出す——
/// `NotificationService.password(forAccountId:)` はこの列挙が返す
/// `Attempts` を実際の `[String: Any]` CFDictionary へ変換して
/// `SecItemCopyMatching` を呼ぶだけの薄いラッパーになる。
public enum NotificationServiceKeychainQuery {
    /// 1回の `SecItemCopyMatching` 呼び出し相当の属性——`Security`
    /// フレームワーク固有の型 (`OSStatus`/`CFString` 定数) を一切含まない
    /// ので、この型自体は他プラットフォームでもテストできる。
    public struct Attempt: Equatable, Sendable {
        public let service: String
        public let accountId: String
        public let accessGroup: String?
        /// 常に `true`——「`kSecAttrSynchronizable` を明示的に
        /// `kSecAttrSynchronizableAny` にして、同期化・非同期化どちらの
        /// 項目にもマッチさせる」ことを表す。今回のバグの本質はまさに
        /// これが抜けていたことなので、フィールドとして残しておくことで
        /// 将来また抜け落ちたときにテストが real failure として検知する。
        public let matchesAnySynchronizableState: Bool

        public init(service: String, accountId: String, accessGroup: String?, matchesAnySynchronizableState: Bool) {
            self.service = service
            self.accountId = accountId
            self.accessGroup = accessGroup
            self.matchesAnySynchronizableState = matchesAnySynchronizableState
        }
    }

    /// `KeychainCredentialStore`の既定 `service` 文字列のミラー——
    /// `apps/Otegami/Sources`側は`swift test`到達不能なので、直接
    /// importして共有する代わりに文字列リテラルを複製している。
    public static let currentService = "com.mtkg.otegami.account-password"

    /// `KeychainCredentialStore.legacyServices`のミラー(`52df393`の
    /// サービス名リネームバグ)——追記専用、古いリネームからの項目もいつか
    /// 見えなくならないよう削除しない、という同じ方針。
    public static let legacyServices = ["com.m-tkg.otegami.account-password"]

    /// `NotificationService.password(forAccountId:)`が試すべきクエリを
    /// 順番通りに並べたもの: まず現行の`service`(通常はここで見つかる)、
    /// 続いて`legacyServices`を古い順に。すべて
    /// `matchesAnySynchronizableState: true`——Task #216の本当の修正点。
    public static func attemptsInOrder(accountId: String, accessGroup: String?) -> [Attempt] {
        ([currentService] + legacyServices).map { service in
            Attempt(service: service, accountId: accountId, accessGroup: accessGroup, matchesAnySynchronizableState: true)
        }
    }
}
