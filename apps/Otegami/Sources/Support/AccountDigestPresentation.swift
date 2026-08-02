import OtegamiStore

/// Shared eligibility and role mapping for the account-digest list.
/// Grouping applies only to an unfiltered cross-account selection.
enum AccountDigestPresentation {
    static func isVisible(
        groupByAccount: Bool,
        accountFilter: String?,
        accountCount: Int,
        selection: SidebarSelection
    ) -> Bool {
        guard groupByAccount, accountFilter == nil, accountCount > 1 else { return false }
        return role(for: selection) != nil
    }

    static func role(for selection: SidebarSelection) -> MailboxRoleRecord? {
        switch selection {
        case .unifiedInbox:
            return .inbox
        case .unifiedRole(let role):
            return role
        case .mailbox:
            return nil
        }
    }
}
