import Foundation
import GRDB

/// `ThreadQuery.setMuted`'s implementation, pulled out into its own file
/// purely to keep `ThreadQuery.swift`'s size down — no behavior or API
/// change: still called exactly as `ThreadQuery.setMuted(threadId:muted:
/// db:)` from every existing call site (e.g. `ThreadDetailView
/// +ThreadOperations`'s mute/unmute menu action).
extension ThreadQuery {
    /// 新画面構成: メール本文画面「…」メニューの「スレッドをミュート」/「ミュート
    /// 解除」— see `ThreadRecord.isMuted`'s doc comment for what the flag
    /// does (list dimming only, not push suppression). A no-op if the
    /// thread no longer exists (e.g. a race with it being deleted).
    public static func setMuted(threadId: Int64, muted: Bool, db: Database) throws {
        guard var thread = try ThreadRecord.fetchOne(db, key: threadId) else { return }
        guard thread.isMuted != muted else { return }
        thread.isMuted = muted
        try thread.update(db, columns: [Column("isMuted")])
    }
}
