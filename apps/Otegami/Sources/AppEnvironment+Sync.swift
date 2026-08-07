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
                        // `forceReconcileVanishedUIDs: true` (実機バグ「別クライアント
                        // で全部アーカイブ→アプリを切り替えて戻すと未読メールが復活」):
                        // Gmail は他クライアントの EXPUNGE で HIGHESTMODSEQ を上げない
                        // ことがあり (Task #83、`MailboxSyncer.incrementalSync` の
                        // `forceReconcileVanishedUIDs` doc comment)、デフォルトの
                        // `false` だとフォアグラウンド復帰同期がサーバー側で消えた
                        // メッセージをローカルから削除できず、未読のまま残り続ける。
                        // この呼び出しは起動/フォアグラウンド復帰時の1回きり・
                        // INBOX スコープなので、追加コストはアカウントあたり
                        // `UID SEARCH` 1回で済む。
                        _ = try? await syncCoordinator.syncAccountIncrementally(account, auth: auth, forceReconcileVanishedUIDs: true)
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

    /// 検索の IMAP サーバーサイド SEARCH フォールバック
    /// (`SearchScreenView`の「サーバーで検索」トリガー行): 実際のロジックは
    /// すべて`SyncCoordinator.serverSearch(query:accounts:authProvider:
    /// timeout:)`にあり、これは`auth(for:)`を注入するだけの薄い配線 —
    /// `prefetchMessageBodiesIfNeeded(messageIds:)`と同じ役割分担
    /// (`PushNotificationCoordinator.swift`参照)。
    ///
    /// - Parameter accountIds: 空なら`accounts`全件 (全アカウント横断) —
    ///   `SearchScreenView.accountFilter == nil`のとき (`SearchScope
    ///   .allAccounts`と同じ「全部」の意味)。
    func serverSearch(query: String, accountIds: [String]) async -> ServerSearchOutcome {
        let targetAccounts = accountIds.isEmpty ? accounts : accounts.filter { accountIds.contains($0.id) }
        return await syncCoordinator.serverSearch(query: query, accounts: targetAccounts) { [weak self] account in
            guard let self else { throw AuthResolutionError.missingCredential }
            return try await self.auth(for: account)
        }
    }

    /// Task (opqueue スタック修正、診断画面強化): `OpQueueDiagnosticsView`の
    /// 「今すぐ再送を実行」ボタンが呼ぶ、手動トリガー版の replay。
    /// `syncAllAccountsOnce`の自動トリガー (フォアグラウンド復帰など) と
    /// 違い、`syncAccountIncrementally`までは行わない — これは診断目的で
    /// 「replay だけ」を今すぐ動かし、結果 (成功/破棄/再試行待ち/恒久失敗
    /// 件数とエラー文言) をその場で確認するためのもの。アカウントを直列に
    /// 処理する (`syncAllAccountsOnce`のような同時2並列はしない) — 手動で
    /// 一度だけ押すボタンの結果表示用途では、並列化の複雑さより「どの
    /// アカウントの結果か」が画面にそのまま出る単純さを優先した。
    func replayOpQueueNowForDiagnostics(accountIds: [String]) async -> [ManualReplayOutcome] {
        let targetAccounts = accounts.filter { accountIds.contains($0.id) }
        var outcomes: [ManualReplayOutcome] = []
        for account in targetAccounts {
            do {
                let resolvedAuth = try await auth(for: account)
                let result = try await syncCoordinator.replayOpQueue(for: account, auth: resolvedAuth)
                outcomes.append(ManualReplayOutcome(accountId: account.id, accountDisplayName: account.displayName, result: result, errorDescription: nil))
            } catch {
                outcomes.append(ManualReplayOutcome(accountId: account.id, accountDisplayName: account.displayName, result: nil, errorDescription: String(describing: error)))
            }
        }
        return outcomes
    }
}

/// `AppEnvironment.replayOpQueueNowForDiagnostics(accountIds:)`の結果1件分
/// (1アカウント分)。`auth(for:)`自体が失敗するケース (Keychain/OAuthトークン
/// 解決失敗) も、接続後の`OpQueueProcessor.replay`失敗と同じく`errorDescription`
/// に収め、`OpQueueDiagnosticsView`側は「成功したか、失敗したなら何が
/// 起きたか」だけを見ればよいようにする。
struct ManualReplayOutcome: Sendable, Identifiable {
    var id: String { accountId }
    var accountId: String
    var accountDisplayName: String
    var result: OpQueueProcessor.ReplayResult?
    var errorDescription: String?
}
