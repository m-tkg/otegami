import OtegamiStore
import Testing
@testable import Otegami

@Suite("Account digest presentation")
struct AccountDigestPresentationTests {
    @Test("digest swipe actions use absolute bulk operations")
    func digestSwipeActionsUseAbsoluteBulkOperations() {
        #expect(AccountDigestBulkAction(.toggleRead) == .markRead)
        #expect(AccountDigestBulkAction(.archive) == .archive)
        #expect(AccountDigestBulkAction(.toggleRead).title == String(localized: "既読にする"))
        #expect(AccountDigestBulkAction(.archive).title == String(localized: "アーカイブ"))
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
