import OtegamiStore

/// Phase 3 (アカウント間並列同期): `accounts` を IMAP ホストごとにグルーピング
/// する。`OtegamiApp`/`AppEnvironment` 側の「ホストが異なるグループは並列
/// (最大2)、同じホストのグループ内は直列」という同期ドライバの下ごしらえ
/// ——同一ホストへの同時 `LOGIN` 集中はレート制限/アカウントロックを誘発する
/// (docs/architecture.md の Known pitfalls c/i、Yahoo! JAPAN の実害前例) ため、
/// 同一ホストのアカウントは必ず同じグループにまとめ、そのグループ内は直列
/// 実行に回す — というのがこの関数の存在理由。
///
/// DB/ネットワークに触れない純関数 — ユニットテストがしやすいよう、
/// 並列実行そのもの (`withTaskGroup` を使った bounded concurrency) は
/// 呼び出し側 (`AppEnvironment`) に残し、ここでは「どうグルーピングするか」
/// の決定だけを担う。
///
/// - ホスト名の比較は大小文字を区別しない (DNS ホスト名は case-insensitive
///   — 別々のフローで作成された同一サーバー宛のアカウントが大文字/小文字
///   だけ違う `imapHost` を持つ可能性がある)。
/// - グループの並び・グループ内の並びは、どちらも `accounts` の元の順序を
///   保つ — 新しいホストが最初に登場した順にグループが並び、同じホストの
///   アカウントは元の相対順序のまま1グループにまとまる。
public func groupAccountsByHost(_ accounts: [AccountRecord]) -> [[AccountRecord]] {
    var hostOrder: [String] = []
    var accountsByHost: [String: [AccountRecord]] = [:]
    for account in accounts {
        let key = account.imapHost.lowercased()
        if accountsByHost[key] == nil {
            hostOrder.append(key)
        }
        accountsByHost[key, default: []].append(account)
    }
    return hostOrder.compactMap { accountsByHost[$0] }
}
