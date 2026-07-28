import SwiftUI
import GRDB
import os
import OtegamiCore
import OtegamiStore

/// 画面構造改修バッチ (Task #33, 1): the destination iOS's push-based
/// navigation (`MailScreenView`/`SearchScreenView`) actually pushes for
/// "open this thread" now, instead of `ThreadDetailView` directly. Decides,
/// once the thread's real message count is known, which of the two
/// requirements applies:
/// - **1 message**: skip straight to `ThreadDetailView` in single-message
///   mode (`singleMessageId`) — no selection screen, matching "スレッドが
///   1通だけなら選択画面をスキップして直接本文へ" (承認済み).
/// - **2+ messages**: show `ThreadSelectionView` first; tapping a row then
///   pushes to `ThreadDetailView`, also in single-message mode for the
///   tapped message — so the body screen *never* shows the thread
///   accordion/stack, regardless of entry path.
///
/// macOS's 3-pane `detailColumn` (`OtegamiApp.swift`) keeps instantiating
/// `ThreadDetailView` directly and is untouched by this type — `CLAUDE.md`'s
/// "1a はコンパクト幅向けの設計であり、Macの広い画面には適用しない" reasoning
/// extends naturally to this batch's item 1 too: a wide macOS detail pane
/// doesn't have the "本文のエリアが狭い" problem this screen exists to solve,
/// and inserting an extra selection pane there would be a bigger interaction
/// change than this batch asked for.
struct ThreadEntryView: View {
    @Environment(AppEnvironment.self) private var environment
    let threadId: Int64
    /// A flat-mode row (`ListDisplaySettingsStore.threadingKey` OFF) already
    /// knows exactly which single message it wants open —
    /// `MessageListView.selectedMessageId`'s doc comment. Non-`nil` here
    /// skips both the message-count lookup and the selection screen
    /// entirely and goes straight to that message, exactly matching this
    /// screen's pre-existing (pre-Task #33) flat-mode behavior.
    let preselectedMessageId: Int64?
    var onReply: (Int64, Bool, Bool) -> Void = { _, _, _ in }
    var onForward: (Int64) -> Void = { _ in }
    var onSearchFromSender: ((String) -> Void)?
    var onThreadRemoved: ((Int64) -> Void)?

    @State private var accountId: String?
    @State private var accountLabelColorKey: String?
    @State private var messages: [MessageRecord] = []
    @State private var isLoaded = false
    @State private var selectedMessageId: Int64?

    var body: some View {
        Group {
            if let preselectedMessageId {
                // 実機バグ報告「スレッド表示をオフにしてるのに、スレッドで
                // 表示されることがある」の再発防止: この分岐はフラットモード
                // (または検索のフラット結果) の行が「これが唯一のメッセージ」
                // と既に確定済みで渡してきたケース — `isFlatModeEntry: true`
                // (`ThreadDetailView`のdoc comment参照) で「次のメールを開く」
                // を抑制する、これまでどおりの挙動。
                detailView(singleMessageId: preselectedMessageId, isFlatModeEntry: true)
            } else if !isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OtegamiColor.background)
                    .accessibilityIdentifier("threadEntry.loadingIndicator")
            } else if messages.count <= 1 {
                // グループ化モードのスレッドが1通しか無かっただけ —
                // `isFlatModeEntry: false`(既定)のまま。「次のメールを開く」
                // は引き続き有効。
                detailView(singleMessageId: messages.first?.id, isFlatModeEntry: false)
            } else {
                ThreadSelectionView(
                    messages: messages, accountId: accountId, accountLabelColorKey: accountLabelColorKey,
                    onSelect: { selectedMessageId = $0 }
                )
                .navigationDestination(item: $selectedMessageId) { messageId in
                    // 同上 — 選択画面でどのメッセージを選んでも、これは
                    // グループ化モードのスレッドのまま。
                    detailView(singleMessageId: messageId, isFlatModeEntry: false)
                }
            }
        }
        .task(id: threadId) { await load() }
        .onAppear {
            // Task #105 続報の計装: cold launch 直後の初回タップだけ
            // `preselectedMessageId` が nil で渡り、フラット設定なのに
            // スレッド選択画面が出る実機報告の切り分け用 (notice — log
            // collect のアーカイブに残るレベル)。
            Self.entryLogger.notice(
                "ThreadEntryView appear: threadId=\(threadId, privacy: .public) preselectedMessageId=\(preselectedMessageId.map(String.init) ?? "nil", privacy: .public)"
            )
        }
    }

    private static let entryLogger = Logger(subsystem: "com.mtkg.otegami", category: "ThreadEntry")

    private func detailView(singleMessageId: Int64?, isFlatModeEntry: Bool) -> ThreadDetailView {
        ThreadDetailView(
            threadId: threadId, singleMessageId: singleMessageId, isFlatModeEntry: isFlatModeEntry,
            onReply: onReply, onForward: onForward,
            onSearchFromSender: onSearchFromSender, onThreadRemoved: onThreadRemoved
        )
    }

    /// A one-shot read (not a live `ValueObservation` like `ThreadDetailView
    /// .load()`'s own message fetch) — this view only ever needs the
    /// message count/list once, to decide which screen to show; the screen
    /// it decides on (`ThreadDetailView` or `ThreadSelectionView`) is what
    /// actually needs to stay live afterward, and `ThreadDetailView` already
    /// does.
    private func load() async {
        guard preselectedMessageId == nil else { return }
        isLoaded = false
        messages = []

        let thread = try? await environment.database.dbWriter.read { db in
            try ThreadRecord.fetchOne(db, key: threadId)
        }
        accountId = thread?.accountId
        accountLabelColorKey = accountId.flatMap { id in environment.accounts.first(where: { $0.id == id })?.labelColorKey }
        messages = (try? await environment.database.dbWriter.read { db in
            try ThreadQuery.messages(threadId: threadId, db: db)
        }) ?? []
        isLoaded = true
    }
}
