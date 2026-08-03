import MailTransport
import OtegamiStore
import SyncEngine

@MainActor
extension AppEnvironment {
    /// Phase 3 (アカウント間並列同期): `RootView.syncAllAccountsOnce` の元の
    /// 実装 (`for account in accounts { ... }` の完全逐次) を置き換える —
    /// アカウントを IMAP ホストでグルーピングし (`groupAccountsByHost(_:)`、
    /// `SyncEngine` の純関数)、ホストの異なるグループは最大2つまで並列に、
    /// 同一ホストのグループ内は直列に `replayOpQueue`→`syncAccountIncrementally`
    /// を実行する。同一ホストへの `LOGIN` 同時集中を避ける狙い
    /// (docs/architecture.md の Known pitfalls c/i — Yahoo! JAPAN のアカウント
    /// ロック実害前例)。
    ///
    /// 資格情報解決 (`auth(for:)`、Keychain/OAuth トークン読み出し) は
    /// このメソッド自身の `@MainActor` isolation の中で全アカウント分先に
    /// 済ませてしまい、実際に並列実行する `withTaskGroup` の子タスクへは
    /// `syncCoordinator` (`actor`、`Sendable`) と解決済みの `MailAuth`
    /// (`Sendable`) だけを渡す — `self` (この `@MainActor` クラス) 自体を
    /// 並行実行される子タスクへ渡す必要がないようにするための構成。
    ///
    /// `startIdleLoops`/prefetch 系はこの変更のスコープ外 (Phase 3 の要求
    /// どおり無変更)。
    func syncAllAccountsOnce() async {
        let groups = groupAccountsByHost(accounts)
        guard !groups.isEmpty else { return }

        var resolvedAuthByAccountId: [String: MailAuth] = [:]
        for group in groups {
            for account in group {
                resolvedAuthByAccountId[account.id] = try? await auth(for: account)
            }
        }
        // `let` (not `var`): the child tasks below only ever read this —
        // capturing a `var` here would make the Swift 6 region-isolation
        // checker treat it as still mutable by this (`@MainActor`) task
        // while the child tasks run concurrently, even though nothing
        // actually mutates it after this point.
        let authByAccountId = resolvedAuthByAccountId

        let syncCoordinator = self.syncCoordinator
        await withTaskGroup(of: Void.self) { taskGroup in
            var pendingGroups = groups.makeIterator()

            func startNextGroupIfAny() {
                guard let nextGroup = pendingGroups.next() else { return }
                taskGroup.addTask {
                    for account in nextGroup {
                        guard let auth = authByAccountId[account.id] else { continue }
                        _ = try? await syncCoordinator.replayOpQueue(for: account, auth: auth)
                        _ = try? await syncCoordinator.syncAccountIncrementally(account, auth: auth)
                    }
                }
            }

            // 最大2グループまで同時に走らせる (Phase 3 の要求: 「同時2」) —
            // 1つ完了するたびに次のグループを1つ起動する、という素朴な
            // bounded-concurrency パターン。`groups.count <= 2` なら
            // このループだけで全グループが起動し、以降の `while` は即座に
            // 終わる。
            let maxConcurrentHostGroups = 2
            for _ in 0..<maxConcurrentHostGroups {
                startNextGroupIfAny()
            }
            while await taskGroup.next() != nil {
                startNextGroupIfAny()
            }
        }
    }
}
