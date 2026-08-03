import Testing
import OtegamiStore
@testable import SyncEngine

/// Phase 3 (アカウント間並列同期): `groupAccountsByHost(_:)` の純粋なグルー
/// ピング決定だけを検証する — 実際の並列実行 (`withTaskGroup`) は
/// `AppEnvironment.syncAllAccountsOnce()` 側の責務で、ここではテストしない
/// (DB/ネットワークに触れないのがこの関数の存在理由)。
@Suite("groupAccountsByHost")
struct AccountHostGroupingTests {
    private func makeAccount(id: String, host: String, username: String? = nil) -> AccountRecord {
        AccountRecord(
            id: id,
            displayName: id,
            email: "\(id)@otegami.test",
            authType: .password,
            imapHost: host,
            imapPort: 1143,
            imapSecurity: .plain,
            imapUsername: username ?? "\(id)@otegami.test"
        )
    }

    @Test("two accounts on the same host end up in exactly one group")
    func sameHostAccountsShareOneGroup() {
        let a1 = makeAccount(id: "a1", host: "imap.mail.yahoo.co.jp")
        let a2 = makeAccount(id: "a2", host: "imap.mail.yahoo.co.jp")

        let groups = groupAccountsByHost([a1, a2])

        #expect(groups.count == 1)
        #expect(groups.first?.map(\.id) == ["a1", "a2"])
    }

    @Test("accounts on different hosts end up in separate groups")
    func differentHostAccountsGetSeparateGroups() {
        let a1 = makeAccount(id: "a1", host: "imap.gmail.com")
        let a2 = makeAccount(id: "a2", host: "imap.mail.yahoo.co.jp")

        let groups = groupAccountsByHost([a1, a2])

        #expect(groups.count == 2)
        #expect(groups.map { $0.map(\.id) } == [["a1"], ["a2"]])
    }

    @Test("host comparison is case-insensitive")
    func hostComparisonIsCaseInsensitive() {
        let a1 = makeAccount(id: "a1", host: "IMAP.Mail.Yahoo.co.jp")
        let a2 = makeAccount(id: "a2", host: "imap.mail.yahoo.co.jp")

        let groups = groupAccountsByHost([a1, a2])

        #expect(groups.count == 1)
        #expect(groups.first?.map(\.id) == ["a1", "a2"])
    }

    @Test("group order follows each host's first appearance; within-group order is preserved")
    func groupsAndMembersPreserveOriginalOrder() {
        let a1 = makeAccount(id: "a1", host: "hostA")
        let a2 = makeAccount(id: "a2", host: "hostB")
        let a3 = makeAccount(id: "a3", host: "hostA")
        let a4 = makeAccount(id: "a4", host: "hostC")
        let a5 = makeAccount(id: "a5", host: "hostB")

        let groups = groupAccountsByHost([a1, a2, a3, a4, a5])

        #expect(groups.map { $0.map(\.id) } == [
            ["a1", "a3"],
            ["a2", "a5"],
            ["a4"],
        ])
    }

    @Test("an empty account list yields no groups")
    func emptyAccountsYieldNoGroups() {
        #expect(groupAccountsByHost([]).isEmpty)
    }
}
