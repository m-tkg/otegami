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
        var action: AccountDigestBulkAction
        var id: String { "\(accountId).\(action.rawValue)" }
    }
    @State private var pendingBulkAction: PendingBulkAction?
    /// Task #190: `ListDisplaySettingsStore.confirmBulkActionKey`のdoc
    /// comment参照 — OFFのときは`requestBulkAction`が確認ダイアログを
    /// 経由せず即座に`performBulkAction`を呼ぶ。
    @AppStorage(ListDisplaySettingsStore.confirmBulkActionKey) private var confirmBulkAction = ListDisplaySettingsStore.defaultConfirmBulkAction

    // MARK: - Undo (`MessageListView`と同じ「即時反映 + Undoトースト」方針)

    private struct PendingUndo {
        var accountId: String
        var message: String
        /// Task #163: `nil` for a blocked-action notice — nothing was
        /// actually removed (every target in the batch was pinned), so
        /// there's nothing to reverse. See `MessageListView.PendingUndo
        /// .undo`'s doc comment for the identical rationale in the sibling
        /// view this mirrors.
        var undo: (() async -> Void)?
    }
    @State private var pendingUndo: PendingUndo?
    @State private var pendingUndoTask: Task<Void, Never>?

    /// 実機フィードバック (2026-07-29「アーカイブ時のトーストがまだ最前面に
    /// 来てない」): この画面の一括アーカイブのトーストが `MailScreenView` の
    /// FAB (`.overlay` チェーンで後から重なる) の背面に描画されていた —
    /// `MessageListView` が Task #108 で踏んだのと同じ問題。同じ解決策を
    /// そのまま移植する: 親 (`MailScreenView`) がこのフラグを立てて
    /// `onPendingUndoChanged` で受け取り、FAB より後の overlay で自ら描く。
    /// macOS (`RootView`) は渡さないので従来どおり内部描画。
    var suppressInternalUndoToast = false
    /// See `suppressInternalUndoToast` — fires with the current pending
    /// undo (`nil` when cleared) every time it changes.
    var onPendingUndoChanged: (MessageListView.UndoToastPayload?) -> Void = { _ in }
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
                    accountEmail: accountEmails[digest.accountId] ?? digest.accountId,
                    labelColorKey: accountLabelColorKeys[digest.accountId],
                    onSelect: { selectAccount(digest.accountId) },
                    onRequestBulkAction: { action in requestBulkAction(accountId: digest.accountId, action: action) }
                )
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
        .accessibilityIdentifier("accountDigest.list")
        // 2026-08-07 (メイン UI の macOS ネイティブ化): 独自の背景塗りは
        // iOS のみ (`MessageListView.messageListCore` と同じ判断)。
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        #endif
        .overlay {
            if digests.isEmpty {
                ContentUnavailableView("アカウントがありません", systemImage: "envelope.badge")
                    .accessibilityIdentifier("accountDigest.emptyState")
            }
        }
        .overlay(alignment: .bottom) {
            // `suppressInternalUndoToast` の doc comment 参照 — iOS の
            // `MailScreenView` 配下では親が FAB より手前に描くのでここでは
            // 描画しない。
            if !suppressInternalUndoToast, let pendingUndo {
                UndoToast(message: pendingUndo.message, onUndo: undoButtonAction(for: pendingUndo))
                    .animation(.default, value: pendingUndo.message)
            }
        }
        // Task #190 (実機フィードバック「グループのスワイプで出てくる確認
        // 画面は…吹き出しっぽく確認が出るけどそうではなく真ん中に確認画面を
        // 出して」): `.confirmationDialog`はiPhoneでは画面下からの
        // アクションシートだが、iPad/macOSではソースに紐づく**ポップオーバー
        // (吹き出し)** として出る — これが「吹き出しっぽく出る」の正体。
        // `.alert`はiOS/macOSどちらも常に画面中央のモーダルで出るため、
        // これに差し替えて解消した。`presenting: pendingBulkAction`で
        // `request`を受け取るのは`AccountSettingsCategoryView`の削除確認
        // アラートと同じ形。
        .alert(
            confirmationTitle,
            isPresented: isConfirmingBulkAction,
            presenting: pendingBulkAction
        ) { request in
            Button(request.action.title, role: request.action.isDestructive ? .destructive : nil) {
                pendingBulkAction = nil
                Task { await performBulkAction(accountId: request.accountId, action: request.action) }
            }
            .accessibilityIdentifier("accountDigest.confirmButton")
            Button("キャンセル", role: .cancel) { pendingBulkAction = nil }
                .accessibilityIdentifier("accountDigest.cancelButton")
        } message: { request in
            // `name`はアカウント表示名 — メールアドレスそのものの場合が
            // あるため`Text(verbatim:)`必須(`AccountFilterChip.swift`の
            // 教訓コメント参照、`LocalizedStringKey`経由の文字列補間だと
            // SwiftUIが自動で`mailto:`リンク化する実バグ前例がある)。
            Text(verbatim: confirmationMessage(for: request))
        }
        .task(id: ObservationKey(accountIds: environment.accounts.map(\.id), role: role)) {
            await observeDigests()
        }
    }

    private var isConfirmingBulkAction: Binding<Bool> {
        Binding(get: { pendingBulkAction != nil }, set: { if !$0 { pendingBulkAction = nil } })
    }

    /// アラートの`title`— 対象件数を含む(「N件をアーカイブしますか？」の
    /// ような文言、仕様「対象件数が分かる文言にすること」に対応)。
    /// `.alert(_:isPresented:presenting:actions:message:)`の`title`引数は
    /// `StringProtocol`型で`Text`/`LocalizedStringKey`を経由しないため、
    /// 動的な数値を埋め込んでも`mailto:`自動リンク化のような文字列補間
    /// バグの対象にはならない(アカウント表示名のような文字列そのものは
    /// 下の`message`側で`Text(verbatim:)`を使う)。件数は表示中の
    /// `digests`スナップショット (`AccountDigest.totalCount`) から見せる
    /// だけ — 実行時の対象確定は`performBulkAction`が
    /// `AccountDigestQuery.allSummaries`で都度取り直すので、ここが多少
    /// 古くても実際に処理される件数がずれることはない(表示だけの問題)。
    private var confirmationTitle: String {
        guard let request = pendingBulkAction, let digest = digests.first(where: { $0.accountId == request.accountId }) else { return "" }
        return "\(digest.totalCount)件を\(request.action.title)しますか？"
    }

    /// アラートの`message`— どのアカウントが対象かを補足する。
    /// `accountDisplayNames`はメールアドレスそのものの場合があるため、
    /// 呼び出し元の`Text(verbatim:)`でのみ表示する(このプロパティ自体は
    /// 表示以外の用途がないので`String`のまま返して問題ない)。
    private func confirmationMessage(for request: PendingBulkAction) -> String {
        let name = accountDisplayNames[request.accountId] ?? request.accountId
        return "\(name)が対象です。"
    }

    /// Task #190: `ListDisplaySettingsStore.confirmBulkActionKey`が
    /// OFFのときは確認ダイアログを経由せず即座に実行する — ONのときは
    /// これまでどおり`pendingBulkAction`をセットして`.alert`を出す。
    private func requestBulkAction(accountId: String, action: AccountDigestBulkAction) {
        guard confirmBulkAction else {
            Task { await performBulkAction(accountId: accountId, action: action) }
            return
        }
        pendingBulkAction = PendingBulkAction(accountId: accountId, action: action)
    }

    private var accountDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.displayName) })
    }

    /// Task #130, 1「アカウント別のアバターを表示」: `SenderAvatar`の
    /// `address`引数用 — `AccountSettingsCategoryView.accountRow(for:)`
    /// (Task #117) と同じ「自分のアドレスをそのまま解決チェーンに渡す」
    /// 発想を、この画面のダイジェスト行にも適用する。
    private var accountEmails: [String: String] {
        Dictionary(uniqueKeysWithValues: environment.accounts.map { ($0.id, $0.email) })
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

    private func performBulkAction(accountId: String, action: AccountDigestBulkAction) async {
        do {
            let summaries = try await environment.database.dbWriter.read { db in
                try AccountDigestQuery.allSummaries(accountId: accountId, role: role, db: db)
            }
            guard !summaries.isEmpty else { return }
            switch action {
            case .archive, .delete, .junk:
                await performRemoval(action, summaries: summaries, accountId: accountId)
            case .markRead:
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
    ///
    /// Task #163: `.archive`の各`commit`呼び出しが`ArchiveGuardError.pinned`
    /// を投げた件数 (ピン留め済みでスキップされた件数) を別途数える —
    /// アーカイブが1件でも成功していればそのスキップ件数をUndoトースト本文に
    /// 添え(「n件をアーカイブしました（m件はピン留めのためスキップ）」)、
    /// 全件ピン留めで1件も成功しなかった場合は元に戻す対象が無いので
    /// Undoボタン無しの通知のみを出す。
    private func performRemoval(_ action: AccountDigestBulkAction, summaries: [ThreadSummary], accountId: String) async {
        let kind: MessageRemoval.Kind
        switch action {
        case .archive: kind = .archive
        case .delete: kind = .delete
        case .junk: kind = .junk
        case .markRead, .pin: return
        }
        var snapshots: [MessageRemoval.Snapshot] = []
        var pinnedSkipCount = 0
        for summary in summaries {
            do {
                if let snapshot = try await environment.database.dbWriter.write({ db in
                    try MessageRemoval.commit(
                        kind, summary: summary, accountId: accountId, db: db,
                        markSeenOnArchive: ArchiveActionSettingsStore.markAsReadOnArchive
                    )
                }) {
                    snapshots.append(snapshot)
                }
            } catch is MessageRemoval.ArchiveGuardError {
                pinnedSkipCount += 1
            } catch {
                // Best-effort — the rest of the batch still proceeds.
            }
        }
        guard !snapshots.isEmpty || pinnedSkipCount > 0 else { return }
        let name = accountDisplayNames[accountId] ?? accountId
        guard !snapshots.isEmpty else {
            // Every target was pinned — nothing to undo, just notify.
            scheduleUndo(accountId: accountId, message: "\(name)の\(pinnedSkipCount)件はピン留めのためスキップしました", undo: nil)
            return
        }
        var message = "\(name)の\(snapshots.count)件を\(action.title)しました"
        if pinnedSkipCount > 0 {
            message += "（\(pinnedSkipCount)件はピン留めのためスキップ）"
        }
        scheduleUndo(accountId: accountId, message: message) {
            for snapshot in snapshots {
                do {
                    try await environment.database.dbWriter.write { db in try MessageRemoval.undo(snapshot, db: db) }
                } catch {
                    // Best-effort, matching `MessageListView.undoRemoval`.
                }
            }
        }
    }

    /// `.markRead`の一括版 — `MessageListView.selectionBottomBar`の
    /// 「既読に」ボタンと同じく、現在の既読/未読状態を見て切り替えるのでは
    /// なく常に既読へ揃える(混在した集合を一括トグルすると結果が直感的で
    /// ない、というそのボタンの既存判断をそのまま踏襲)。破壊的操作では
    /// ないためUndoトーストは出さない — フラグ更新/`OpQueue.enqueueSetFlags`/
    /// `recomputeAggregates`の中核は`SyncEngine.MessagePinReadState
    /// .applyReadState`が担う(`MessageListView.applyReadState`/
    /// `ThreadDetailView`の同名メソッドと共有、その型のdoc comment参照) —
    /// この画面固有なのは対象解決 (`ThreadQuery.actionTargets(for:db:)`) と
    /// `replayOpQueueSoon`呼び出しだけの薄いラッパー。
    private func applyReadState(_ summary: ThreadSummary, markingRead: Bool, accountId: String) async {
        guard let threadId = summary.thread.id else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                try MessagePinReadState.applyReadState(
                    markingRead: markingRead, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort, matching `MessageListView.applyReadState`.
        }
    }

    /// `.pin`の一括版 — 同じ理由で常に「ピン留めする」側へ揃える。
    /// `applyReadState(_:markingRead:accountId:)`と同じく中核は
    /// `SyncEngine.MessagePinReadState.applyPinState`共有、ここは対象解決 +
    /// `replayOpQueueSoon`だけの薄いラッパー。
    private func applyPinState(_ summary: ThreadSummary, pinning: Bool, accountId: String) async {
        guard let threadId = summary.thread.id else { return }
        do {
            try await environment.database.dbWriter.write { db in
                let messages = try ThreadQuery.actionTargets(for: summary, db: db)
                try MessagePinReadState.applyPinState(
                    pinning: pinning, messages: messages, threadId: threadId, accountId: accountId, db: db
                )
            }
            await replayOpQueueSoon(accountId: accountId)
        } catch {
            // Best-effort, matching `MessageListView.applyPinState`.
        }
    }

    private func scheduleUndo(accountId: String, message: String, undo: (() async -> Void)?) {
        pendingUndoTask?.cancel()
        if let previous = pendingUndo {
            Task { await replayOpQueueSoon(accountId: previous.accountId) }
        }
        let pending = PendingUndo(accountId: accountId, message: message, undo: undo)
        pendingUndo = pending
        onPendingUndoChanged(MessageListView.UndoToastPayload(message: message, onUndo: undoButtonAction(for: pending)))
        pendingUndoTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            pendingUndo = nil
            onPendingUndoChanged(nil)
            await replayOpQueueSoon(accountId: accountId)
        }
    }

    private func undoPending() {
        pendingUndoTask?.cancel()
        guard let pendingUndo, let undo = pendingUndo.undo else { return }
        self.pendingUndo = nil
        onPendingUndoChanged(nil)
        Task { await undo() }
    }

    /// Task #163: `UndoToast`'s `onUndo` for a given `PendingUndo` — `nil`
    /// (no button rendered) for a blocked-action notice (`pending.undo ==
    /// nil`), `undoPending` otherwise. Pulled into its own explicitly-typed
    /// function rather than an inline ternary at the `body` call site —
    /// the inline form (`pending.undo != nil ? undoPending : nil`) made the
    /// surrounding `some View` expression fail to type-check with a Swift
    /// compiler crash ("failed to produce diagnostic for expression"),
    /// presumably the same class of `ViewBuilder`-inference blowup
    /// `CLAUDE.md`'s CI type-check-timeout note already warns this codebase
    /// is prone to.
    private func undoButtonAction(for pending: PendingUndo) -> (() -> Void)? {
        guard pending.undo != nil else { return nil }
        return undoPending
    }

    private func replayOpQueueSoon(accountId: String) async {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
    }
}
