#if os(macOS)
import SwiftUI
import OtegamiStore

/// ユーザー要望 (2026-08-08「マウスなどで複数選択して、右クリックで
/// アーカイブや既読化、ピン留めできるようにして」): macOS の一覧
/// (`MessageListView.messageListCore`) が `List` 全体に付ける
/// `.contextMenu(forSelectionType:)` の中身。
///
/// 行ごとの `.contextMenu` (`MessageListRow` が macOS で持っていたもの) を
/// 置き換える形にしてある — 行側に残したままだと、複数選択して右クリック
/// しても「右クリックした 1 行」に対するメニューしか出せない
/// (行の`View`は選択集合を知らない)。`List`側の
/// `.contextMenu(forSelectionType:)` なら SwiftUI が選択集合を`ids`として
/// 渡してくれるうえ、選択外の行を右クリックしたときはその行だけを`ids`に
/// 載せる (＝従来の単一行メニューと同じ挙動) ところまで面倒を見る。
///
/// 返信/全員に返信/転送は対象が 1 通に定まらないと意味を成さないので、
/// 選択が 1 件のときだけ出す (Apple Mail.app も複数選択時は返信系を
/// 落とす)。それ以外の項目は件数によらず同じ並び。
struct MessageListSelectionMenu: View {
    /// `.contextMenu(forSelectionType:)` が渡した集合に対応するスレッド
    /// (`MessageListView.summaries(for:)` が解決済み)。
    let targets: [ThreadSummary]
    /// 「アーカイブ」を「アーカイブ解除」に差し替えるか —
    /// `MessageListRow.archiveLabel` の単一行版と同じ出し分け。
    let isArchiveView: Bool
    let onReply: (ThreadSummary) -> Void
    let onReplyAll: (ThreadSummary) -> Void
    let onForward: (ThreadSummary) -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onArchive: () -> Void
    let onUnarchive: () -> Void
    /// `true` でピン留め、`false` で解除 — 下の `isAllPinned` が決める。
    let onPin: (Bool) -> Void
    let onJunk: () -> Void
    let onDelete: () -> Void

    var body: some View {
        replySection
        readSection
        archiveButton
        pinButton
        Divider()
        junkButton
        deleteButton
    }

    /// 選択が 1 件のときだけの返信系 — Task #165 が単一行メニューで
    /// 先頭に置いた並び (返信/全員に返信/転送) をそのまま踏襲する。
    @ViewBuilder
    private var replySection: some View {
        if let summary = targets.count == 1 ? targets.first : nil {
            Button { onReply(summary) } label: { Label("返信", systemImage: "arrowshape.turn.up.left") }
            Button { onReplyAll(summary) } label: { Label("全員に返信", systemImage: "arrowshape.turn.up.left.2") }
            Button { onForward(summary) } label: { Label("転送", systemImage: "arrowshape.turn.up.right") }
            Divider()
        }
    }

    /// 単一行メニューの「既読/未読を切り替え」と違い、既読化と未読化を
    /// 別々の項目として並べる — 混在した集合をトグルすると結果が直感的で
    /// ない (`MessageListView+Selection.markSelectedAsUnread()`の doc
    /// comment、および iOS の一括「既読に」からの既存判断)。
    @ViewBuilder
    private var readSection: some View {
        Button(action: onMarkRead) { Label("既読にする", systemImage: "envelope.open") }
        Button(action: onMarkUnread) { Label("未読にする", systemImage: "envelope.badge") }
    }

    @ViewBuilder
    private var archiveButton: some View {
        if isArchiveView {
            Button(action: onUnarchive) { Label("アーカイブ解除", systemImage: "tray.and.arrow.up") }
        } else {
            Button(action: onArchive) { Label(SwipeAction.archive.title, systemImage: SwipeAction.archive.systemImage) }
        }
    }

    @ViewBuilder
    private var pinButton: some View {
        if isAllPinned {
            Button { onPin(false) } label: { Label("ピン留めを解除", systemImage: "pin.slash") }
        } else {
            Button { onPin(true) } label: { Label("ピン留め", systemImage: "pin") }
        }
    }

    @ViewBuilder
    private var junkButton: some View {
        Button(action: onJunk) { Label(SwipeAction.junk.title, systemImage: SwipeAction.junk.systemImage) }
    }

    @ViewBuilder
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Label(SwipeAction.delete.title, systemImage: SwipeAction.delete.systemImage)
        }
    }

    /// 選択が全部ピン留め済みのときだけ「解除」を出す — 1 件でも未ピンが
    /// 混ざっていれば「ピン留め」(＝揃える方向) にする。
    private var isAllPinned: Bool {
        !targets.isEmpty && targets.allSatisfy(\.thread.isPinned)
    }
}
#endif
