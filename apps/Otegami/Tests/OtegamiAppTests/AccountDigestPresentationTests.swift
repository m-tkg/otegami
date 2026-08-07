import OtegamiStore
import Testing
@testable import Otegami

@Suite("Account digest presentation")
struct AccountDigestPresentationTests {
    @Test("digest swipe actions use absolute bulk operations")
    func digestSwipeActionsUseAbsoluteBulkOperations() {
        #expect(AccountDigestBulkAction(.toggleRead) == .markRead)
        #expect(AccountDigestBulkAction(.archive) == .archive)
        #expect(AccountDigestBulkAction(.toggleRead)?.title == String(localized: "既読にする"))
        #expect(AccountDigestBulkAction(.archive)?.title == String(localized: "アーカイブ"))
    }

    /// ユーザー要望 (2026-08-07「グループに対してのピン留め・ピン解除は
    /// できないようにしてほしい」) — `AccountDigestBulkAction`の doc comment
    /// 参照。スワイプ設定が`.pin`のスロットは、グループ行ではボタン自体が
    /// 出ない。
    @Test("pin has no group-level counterpart")
    func pinIsNotOfferedAsBulkAction() {
        #expect(AccountDigestBulkAction(.pin) == nil)
        #expect(SwipeAction.allCases.compactMap(AccountDigestBulkAction.init).count == SwipeAction.allCases.count - 1)
    }

    /// ユーザー要望 (2026-08-07「グループに対してのアーカイブは、アーカイブ
    /// されてないものだけを対象にしたい。すべてを既読、も同じく」)。
    @Test("bulk archive skips already-archived threads, mark-read skips already-read ones")
    func bulkActionTargetsSkipNoOps() {
        let unreadUnarchived = makeSummary(id: 1, unreadCount: 2, isArchived: false)
        let readUnarchived = makeSummary(id: 2, unreadCount: 0, isArchived: false)
        let unreadArchived = makeSummary(id: 3, unreadCount: 1, isArchived: true)
        let all = [unreadUnarchived, readUnarchived, unreadArchived]

        #expect(AccountDigestPresentation.bulkActionTargets(for: .archive, in: all).map(\.thread.id) == [1, 2])
        #expect(AccountDigestPresentation.bulkActionTargets(for: .markRead, in: all).map(\.thread.id) == [1, 3])
        // `.delete`/`.junk`は「もう対象外」と言えるローカル状態が無いので
        // 表示中のスレッドをすべて対象にする。
        #expect(AccountDigestPresentation.bulkActionTargets(for: .delete, in: all).count == 3)
        #expect(AccountDigestPresentation.bulkActionTargets(for: .junk, in: all).count == 3)
    }

    private func makeSummary(id: Int64, unreadCount: Int, isArchived: Bool) -> ThreadSummary {
        var thread = ThreadRecord(accountId: "account-1", messageCount: 1, unreadCount: unreadCount)
        thread.id = id
        var summary = ThreadSummary(thread: thread, latestMessage: nil)
        summary.isArchived = isArchived
        return summary
    }

    @Test("grouped All shows the digest for cross-account selections")
    func groupedAllShowsDigest() {
        #expect(AccountDigestPresentation.isVisible(
            groupByAccount: true,
            accountFilter: nil,
            accountCount: 2,
            selection: .unifiedInbox
        ))
        #expect(AccountDigestPresentation.isVisible(
            groupByAccount: true,
            accountFilter: nil,
            accountCount: 2,
            selection: .unifiedRole(.archive)
        ))
    }

    @Test("chronological, filtered, and mailbox selections hide the digest")
    func ineligibleSelectionsHideDigest() {
        #expect(!AccountDigestPresentation.isVisible(
            groupByAccount: false,
            accountFilter: nil,
            accountCount: 2,
            selection: .unifiedInbox
        ))
        #expect(!AccountDigestPresentation.isVisible(
            groupByAccount: true,
            accountFilter: "account-1",
            accountCount: 2,
            selection: .unifiedInbox
        ))
        #expect(!AccountDigestPresentation.isVisible(
            groupByAccount: true,
            accountFilter: nil,
            accountCount: 2,
            selection: .mailbox(MailboxSelection(accountId: "account-1", mailboxId: 1))
        ))
        #expect(!AccountDigestPresentation.isVisible(
            groupByAccount: true,
            accountFilter: nil,
            accountCount: 1,
            selection: .unifiedInbox
        ))
    }

    @Test("digest role follows the cross-account selection")
    func digestRoleFollowsSelection() {
        #expect(AccountDigestPresentation.role(for: .unifiedInbox) == .inbox)
        #expect(AccountDigestPresentation.role(for: .unifiedRole(.sent)) == .sent)
        #expect(AccountDigestPresentation.role(for: .mailbox(MailboxSelection(accountId: "account-1", mailboxId: 1))) == nil)
    }
}
