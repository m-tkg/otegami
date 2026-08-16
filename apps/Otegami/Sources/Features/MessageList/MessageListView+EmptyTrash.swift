import Foundation
import GRDB
import OtegamiStore
import SwiftUI
import SyncEngine

/// 「ゴミ箱を空にする」— `requestEmptyTrash()`(トースト付き Undo が無い、
/// `pendingEmptyTrashCount`/`.alert`による確認必須の破壊的操作) が対象と
/// する、1アカウント分の Trash メールボックス。
struct EmptyTrashTarget: Hashable {
    var accountId: String
    var mailboxId: Int64
}

extension MessageListView {
    /// `body`の確認`.alert`用 Binding — インラインの`Binding(get:set:)`
    /// クロージャを`body`の modifier チェーンに直接書くと式が巨大化して
    /// CI の型チェックタイムアウト (`docs/ci.md`) を踏むため、名前付き
    /// プロパティに分離してある (`body`側のコメント参照)。
    var isEmptyTrashAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingEmptyTrashCount != nil },
            set: { if !$0 { pendingEmptyTrashCount = nil } }
        )
    }

    /// 確認`.alert`のボタン列 — `body`から分離している理由は
    /// `isEmptyTrashAlertPresented`と同じ。
    @ViewBuilder
    func emptyTrashAlertActions() -> some View {
        Button("空にする", role: .destructive, action: confirmEmptyTrash)
            .accessibilityIdentifier("messageList.emptyTrash.confirmButton")
        Button("キャンセル", role: .cancel, action: dismissEmptyTrashPrompt)
            .accessibilityIdentifier("messageList.emptyTrash.cancelButton")
    }

    /// 確認`.alert`の本文。
    @ViewBuilder
    func emptyTrashAlertMessage() -> some View {
        Text("\(pendingEmptyTrashCount ?? 0)件のメールを完全に削除します。この操作は取り消せません。")
    }

    /// 「キャンセル」— named method (インラインクロージャを避ける
    /// `docs/ci.md`の実践ルール)。
    func dismissEmptyTrashPrompt() {
        pendingEmptyTrashCount = nil
    }

    /// トースト付き Undo を持つ他の一括操作 (`deleteSelected()`等) と違い、
    /// これは不可逆 — 実行前に必ず`.alert`(`body`) を経由させる。ここでは
    /// 対象メールボックスを解決し、正確な対象件数を読んでから
    /// `pendingEmptyTrashCount`をセットするだけ (実際の削除は
    /// `confirmEmptyTrash()`)。対象が無い/空なら何もしない (ボタン自体が
    /// `isTrashView && !summaries.isEmpty`のときしか出ないので通常起きない
    /// が、選択直後の非同期な役割解決の隙間を突いた連打などへの防御)。
    func requestEmptyTrash() {
        Task {
            let targets = await trashMailboxTargets()
            guard !targets.isEmpty else { return }
            let mailboxIds = targets.map(\.mailboxId)
            let count = (try? await environment.database.dbWriter.read { db in
                try MessageRecord.filter(mailboxIds.contains(Column("mailboxId"))).fetchCount(db)
            }) ?? 0
            guard count > 0 else { return }
            pendingEmptyTrashTargets = targets
            pendingEmptyTrashCount = count
        }
    }

    /// `.alert`の「空にする」ボタン — `pendingEmptyTrashTargets`の全メール
    /// ボックスに対して`SyncEngine.EmptyTrash.commit`をローカルで実行し、
    /// 成功したアカウントぶんだけ`replayOpQueueSoon`で即座にサーバーへも
    /// 反映を試みる (Undo ウィンドウが無い操作なので、他の削除系のように
    /// 数秒待たせる理由が無い)。
    func confirmEmptyTrash() {
        let targets = pendingEmptyTrashTargets
        pendingEmptyTrashCount = nil
        pendingEmptyTrashTargets = []
        guard !targets.isEmpty else { return }
        Task {
            var succeededAccountIds: Set<String> = []
            for target in targets {
                do {
                    try await environment.database.dbWriter.write { db in
                        try EmptyTrash.commit(accountId: target.accountId, mailboxId: target.mailboxId, db: db)
                    }
                    succeededAccountIds.insert(target.accountId)
                } catch {
                    // Best-effort, matching every other opQueue-enqueuing/
                    // db-mutating path in this file (`commitDelete`等) —
                    // 失敗したメールボックスはローカルに残ったままになり、
                    // ユーザーは再度「空にする」を実行できる。
                }
            }
            guard !succeededAccountIds.isEmpty else { return }
            await replayOpQueueSoon(accountIds: succeededAccountIds)
        }
    }

    /// `selection`が指すゴミ箱メールボックス群 — `.mailbox`は1件、
    /// `.unifiedRole(.trash)`(「すべてのゴミ箱」) はスコープ内の各アカウント
    /// が持つ Trash-role メールボックス (`unifiedInboxAccountFilter`で絞り
    /// 込み中ならその1アカウントだけ)、`.unifiedInbox`は対象なし。
    func trashMailboxTargets() async -> [EmptyTrashTarget] {
        switch selection {
        case .mailbox(let mailboxSelection):
            return isTrashView ? [EmptyTrashTarget(accountId: mailboxSelection.accountId, mailboxId: mailboxSelection.mailboxId)] : []
        case .unifiedRole(let role):
            guard role == .trash else { return [] }
            let accountIds = unifiedInboxAccountFilter.map { [$0] } ?? environment.accounts.map(\.id)
            return (try? await environment.database.dbWriter.read { db in
                try accountIds.compactMap { accountId -> EmptyTrashTarget? in
                    guard let mailbox = try MailboxRecord
                        .filter(Column("accountId") == accountId)
                        .filter(Column("role") == MailboxRoleRecord.trash.rawValue)
                        .fetchOne(db), let mailboxId = mailbox.id else { return nil }
                    return EmptyTrashTarget(accountId: accountId, mailboxId: mailboxId)
                }
            }) ?? []
        case .unifiedInbox:
            return []
        }
    }
}
