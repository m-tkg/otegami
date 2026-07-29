import SwiftUI
import GRDB
import OtegamiStore
import SyncEngine

/// Task #92 (アカウントダイジェスト画面) で追加、Task #99 で埋め込み表示に
/// 変更: 元は一覧ヘッダの「アカウントでグループ化」ボタン
/// (`MailScreenView.groupByAccountToggleButton`、Task #106 で廃止 — 今は
/// 1a の「すべて」チップのプルダウン`AccountFilterChipRow.AllModeFilterChip`
/// が同じ`ListDisplaySettingsStore.groupByAccountKey`をトグルする) がON/OFF
/// する一覧領域の中身の一つ — #77 で実装したインラインのアカウント別`Section`分割
/// (`AccountGroupSectionHeader`、廃止済み) を置き換える。アカウントごとに
/// 1行 (`AccountDigestRow`): 色罫線 + 表示名 + 未読/件数バッジ + 直近2-3件の
/// 差出人/件名プレビュー。行タップでそのアカウントに絞り込んだ一覧へ
/// (`onSelectAccount`、1a のアカウント絞り込みチップと同じ
/// `MailScreenView.accountFilter`機構を再利用する — 新しいフィルタ機構は
/// 増やしていない)。行のスワイプは「表示中フォルダの全メールを一括処理」
/// — 確認ダイアログを必ず挟み、実行後は`MessageListView`と同じ`UndoToast`
/// を出す。
///
/// Task #99 (ユーザーフィードバック「グルーピングボタンは未読のみボタンと
/// 同じトグル挙動にしたい」): 当初 (#92) は`MailScreenView.content`から
/// `.navigationDestination`でプッシュされる独立画面 (`.navigationTitle`+
/// 戻るボタン付き) だった。プッシュ遷移だと戻るボタンが余分に出てしまう
/// ため、`MailScreenView.content`が`MessageListView`の代わりにこの`View`を
/// 直接埋め込む形に変えた — このため`.navigationTitle`/`\.dismiss`は
/// 持たない(ヘッダは呼び出し元の`NavigationStack`のものがそのまま
/// 見え続ける)。行タップ (`onSelectAccount`) はもう画面を閉じない —
/// 呼び出し元が`accountFilter`をセットするだけで、`MailScreenView
/// .isShowingAccountDigest`が`false`になり自動的に絞り込み一覧へ切り替わる
/// (そちらのdoc comment参照)。
///
/// `role`は呼び出し元 (`MailScreenView`) の`mailSelection`から決まる —
/// `.unifiedInbox`なら`.inbox`、`.unifiedRole(let role)`ならその`role`。
/// `.mailbox`選択中はそもそも`MailScreenView.isAccountDigestEligible`が
/// `false`でこのViewに切り替わらない (Task #106 以降は入口である「すべて」
/// チップも`.unifiedInbox`選択中にしか出ない) ので、このViewが`.mailbox`
/// 由来の`role`を渡されることは無い。
struct AccountDigestView: View {
    @Environment(AppEnvironment.self) private var environment

    let role: MailboxRoleRecord
    /// タップされた行のアカウントIDを呼び出し元へ — `MailScreenView`が
    /// `accountFilter`にセットしてこの画面を閉じる。
    var onSelectAccount: (String) -> Void

    @State private var digests: [AccountDigest] = []

    // MARK: - 一括処理の確認ダイアログ

    private struct PendingBulkAction: Identifiable {
        var accountId: String
        var action: SwipeAction
        var id: String { "\(accountId).\(action.rawValue)" }
    }
    @State private var pendingBulkAction: PendingBulkAction?

    // MARK: - Undo (`MessageListView`と同じ「即時反映 + Undoトースト」方針)

    private struct PendingUndo {
        var accountId: String
        var message: String
        var undo: () async -> Void
    }
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoTask: Task<Void, Never>?
    /// `MessageListView.undoWindow`と同じ値 — 別画面だが同じ「元に戻す」
    /// という体験である以上、猶予秒数も揃えておく。
    private static let undoWindow: Duration = .seconds(5)

    private struct ObservationKey: Hashable {
        var accountIds: [String]
        var role: MailboxRoleRecord
    }

    var body: some View {
        List {
            ForEach(digests) { digest in
                AccountDigestRow(
                    digest: digest,
                    accountDisplayName: accountDisplayNames[digest.accountId] ?? digest.accountId,
                    labelColorKey: accountLabelColorKeys[digest.accountId],
                    onSelect: { selectAccount(digest.accountId) },
                    onRequestBulkAction: { action in pendingBulkAction = PendingBulkAction(accountId: digest.accountId, action: action) }
                )
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .accessibilityIdentifier("accountDigest.list")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .overlay {
            if digests.isEmpty {
                ContentUnavailableView("アカウントがありません", systemImage: "envelope.badge")
                    .accessibilityIdentifier("accountDigest.emptyState")
            }
        }
        .overlay(alignment: .bottom) {
            if let pendingUndo {
                UndoToast(message: pendingUndo.message, onUndo: undoPending)
                    .animation(.default, value: pendingUndo.message)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirmingBulkAction, titleVisibility: .visible) {
            confirmationActions
        }
        .task(id: ObservationKey(accountIds: environment.accounts.map(\.id), role: role)) {
            await observeDigests()
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        if let request = pendingBulkAction {
            Button(request.action.title, role: request.action == .delete ? .destructive : nil) {
                pendingBulkAction = nil
                Task { await performBulkAction(accountId: request.accountId, action: request.action) }
            }
            .accessibilityIdentifier("accountDigest.confirmButton")
            Button("キャンセル", role: .cancel) { pendingBulkAction = nil }
                .accessibilityIdentifier("accountDigest.cancelButton")
        }
    }

    private var isConfirmingBulkAction: Binding<Bool> {
        Binding(get: { pendingBulkAction != nil }, set: { if !$0 { pendingBulkAction = nil } })
    }

    /// 対象件数は表示中の`digests`スナップショット (`AccountDigest.totalCount`)
    /// から見せるだけ — 実行時の対象確定は`performBulkAction`が
    /// `AccountDigestQuery.allSummaries`で都度取り直すので、ここが多少
    /// 古くても実際に処理される件数がずれることはない(表示だけの問題)。
    private var confirmationTitle: String {
        guard let request = pendingBulkAction, let digest = digests.first(where: { $0.accountId == request.accountId }) else { return "" }
        let name = accountDisplayNames[request.accountId] ?? request.accountId
        return "\(name)の\(digest.totalCount)件を\(request.action.title)しますか？"
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    private var accountLabelColorKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.compactMap { account in
            account.labelColorKey.map { (account.id, $0) }
        })
    }

    /// Task #99: 以前は`dismiss()`で自身を閉じていたが、この`View`はもう
    /// プッシュされていない(埋め込み表示)ので閉じる対象が無い —
    /// `onSelectAccount`が`accountFilter`をセットした結果、呼び出し元
    /// (`MailScreenView.content`)がこの`View`自体を描画しなくなることで
    /// 「閉じる」が実現される。
    private func selectAccount(_ accountId: String) {
        onSelectAccount(accountId)
    }

    private func observeDigests() async {
        let accountIds = environment.accounts.map(\.id)
        let observation = AccountDigestQuery.digestsObservation(accountIds: accountIds, role: role)
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                digests = fetched
            }
        } catch {
            // A failing observation just stops the list from updating
            // further — matches `MessageListView.observeThreads()`.
        }
    }

    // MARK: - 一括処理の実行

    private func performBulkAction(accountId: String, action: SwipeAction) async {
        do {
            let summaries = try await environment.database.dbWriter.read { db in
                try AccountDigestQuery.allSummaries(accountId: accountId, role: role, db: db)
            }
            guard !summaries.isEmpty else { return }
            switch action {
            case .archive, .delete, .junk:
                await performRemoval(action, summaries: summaries, accountId: accountId)
            case .toggleRead:
                for summary in summaries { await applyReadState(summary, markingRead: true, accountId: accountId) }
            case .pin:
                for summary in summaries { await applyPinState(summary, pinning: true, accountId: accountId) }
            }
        } catch {
            // Best-effort, matching every other opQueue-enqueuing path in
            // this app (`MessageListView`'s equivalents).
        }
    }

    /// `.archive`/`.delete`/`.junk`の一括版 — `MessageListView.archiveSelected`/
    /// `deleteSelected`と同じ「1スレッドずつ`MessageRemoval.commit`して
    /// スナップショットを集め、1つでも成功したらUndoトーストを出す」形。
    private func performRemoval(_ action: SwipeAction, summaries: [ThreadSummary], accountId: String) async {
        let kind: MessageRemoval.Kind
        switch action {
        case .archive: kind = .archive
        case .delete: kind = .delete
        case .junk: kind = .junk
        case .toggleRead, .pin: return
        }
        var snapshots: [MessageRemoval.Snapshot] = []
        for summary in summaries {
            do {
                if let snapshot = try await environment.database.dbWriter.write({ db in
                    try MessageRemoval.commit(kind, summary: summary, accountId: accountId, db: db)
                }) {
                    snapshots.append(snapshot)
                }
            } catch {
                // Best-effort — the rest of the batch still proceeds.
            }
        }
        guard !snapshots.isEmpty else { return }
        let name = accountDisplayNames[accountId] ?? accountId
        scheduleUndo(accountId: accountId, message: "\(name)の\(snapshots.count)件を\(action.title)しました") {
            for snapshot in snapshots {
                do {
                    try await environment.database.dbWriter.write { db in try MessageRemoval.undo(snapshot, db: db) }
                } catch {
                    // Best-effort, matching `MessageListView.undoRemoval`.
                }
            }
        }
    }

    /// `.toggleRead`の一括版 — `MessageListView.selectionBottomBar`の
    /// 「既読に」ボタンと同じく、現在の既読/未読状態を見て切り替えるのでは
    /// なく常に既読へ揃える(混在した集合を一括トグルすると結果が直感的で
    /// ない、というそのボタンの既存判断をそのまま踏襲)。破壊的操作では
    /// ないためUndoトーストは出さない — `MessageListView.applyReadState`
    /// と同じ実装をこの画面向けに複製している(どちらも薄いopQueue経由の
    /// 書き込みで、切り出すほどの共通ロジックが無いための重複)。
    private func applyReadState(_ summary: ThreadSummary, markingRead: Bool, accountId: String) async {
        guard let threadId = summary.thread.id else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                for var message in messages {
                    if markingRead {
                        guard !message.flags.contains(.seen) else { continue }
                        message.flags.insert(.seen)
                    } else {
                        guard message.flags.contains(.seen) else { continue }
                        message.flags.remove(.seen)
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    // Task #120: same pending-relocation guard as
                    // `MessageListView.applyReadState(_:markingRead:)`.
                    guard !message.isPendingRelocation,
                          let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
                    else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort, matching `MessageListView.applyReadState`.
        }
    }

    /// `.pin`の一括版 — 同じ理由で常に「ピン留めする」側へ揃える
    /// (`MessageListView.applyPinState`の複製、doc comment は同じ)。
    private func applyPinState(_ summary: ThreadSummary, pinning: Bool, accountId: String) async {
        guard let threadId = summary.thread.id else { return }
        let syncEnabled = PinSettingsStore.isSyncWithFlaggedEnabled
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                for var message in messages {
                    guard message.isPinnedLocal != pinning else { continue }
                    message.isPinnedLocal = pinning
                    if syncEnabled {
                        if pinning {
                            message.flags.insert(.flagged)
                        } else {
                            message.flags.remove(.flagged)
                        }
                    }
                    message.updatedAt = Date()
                    try message.update(db)
                    // Task #120: same pending-relocation guard as
                    // `MessageListView.applyPinState(_:pinning:)`.
                    guard syncEnabled, !message.isPendingRelocation,
                          let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId)
                    else { continue }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: message.mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(message.uid)], flags: message.flags, db: db
                    )
                }
                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
            }
            if syncEnabled { await replayOpQueueSoon(accountId: accountId) }
        } catch {
            // Best-effort, matching `MessageListView.applyPinState`.
        }
    }

    private func scheduleUndo(accountId: String, message: String, undo: @escaping () async -> Void) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await replayOpQueueSoon(accountId: previous.accountId) }
        }
        pendingUndo = PendingUndo(accountId: accountId, message: message, undo: undo)
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pendingUndo = nil
            await replayOpQueueSoon(accountId: accountId)
        }
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo else { return }
        let undo = pendingUndo.undo
        self.pendingUndo = nil
        Task { await undo() }
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
