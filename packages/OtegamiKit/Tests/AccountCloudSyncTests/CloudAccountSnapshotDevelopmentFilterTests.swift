import Foundation
import Testing
import OtegamiStore
@testable import AccountCloudSync

/// Pure boundary-case coverage for `CloudAccountSnapshot.isDevelopmentHost`/
/// `.isDevelopmentAccount` — the predicate `AccountCloudSyncEngine.reconcile()`/
/// `pushLocalChange` use to keep this repo's own dev-mailstack accounts out
/// of the real iCloud KVS payload (`docs/icloud-sync.md`'s "開発用アカウント
/// の除外"). See that property's doc comment for the real-device incident
/// this exists to prevent.
@Suite("CloudAccountSnapshot development-host filter")
struct CloudAccountSnapshotDevelopmentFilterTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Hosts that must be classified as development

    @Test(arguments: [
        "localhost",
        "LOCALHOST", // case-insensitive
        "127.0.0.1",
        "127.1.2.3",
        "10.0.0.1",
        "10.255.255.255",
        "192.168.0.2", // the exact host docs/icloud-sync.md's duplicate-account report names
        "192.168.1.1",
        "172.16.0.1",
        "172.31.255.255", // upper end of 172.16.0.0/12
        "imap.otegami.test",
        "otegami.test",
        "mail.example.local",
        "IMAP.OTEGAMI.TEST" // case-insensitive suffix match
    ])
    func classifiesKnownDevelopmentHosts(_ host: String) {
        #expect(CloudAccountSnapshot.isDevelopmentHost(host), "expected \(host) to be classified as a development host")
    }

    // MARK: - Hosts that must NOT be classified as development (real mail providers, adjacent-but-different ranges)

    @Test(arguments: [
        "imap.gmail.com",
        "imap.mail.me.com",
        "smtp.mail.me.com",
        "mail.example.com",
        "172.15.255.255", // just below 172.16.0.0/12
        "172.32.0.1", // just above 172.16.0.0/12
        "193.168.0.1", // looks close to 192.168.x but isn't
        "1.2.3.4",
        "otegami.testing", // must not fuzzy-match ".test" as a substring
        "otegami.localish", // must not fuzzy-match ".local" as a substring
        "",
        "not.a.valid.ip.address.but.has.dots"
    ])
    func doesNotClassifyOrdinaryHosts(_ host: String) {
        #expect(!CloudAccountSnapshot.isDevelopmentHost(host), "expected \(host) NOT to be classified as a development host")
    }

    // MARK: - `isDevelopmentAccount` reads `imapHost` off a real snapshot

    @Test
    func isDevelopmentAccountReflectsImapHost() {
        let devAccount = CloudAccountSnapshot.fixture(imapHost: "192.168.0.2", updatedAt: epoch)
        let realAccount = CloudAccountSnapshot.fixture(imapHost: "imap.gmail.com", updatedAt: epoch)

        #expect(devAccount.isDevelopmentAccount)
        #expect(!realAccount.isDevelopmentAccount)
    }
}
