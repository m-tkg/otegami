import Testing
@testable import PushRelayClient

/// Task #216: pins down the exact bug fix — `attemptsInOrder(accountId:
/// accessGroup:)` must widen every attempt to match both synchronizable and
/// non-synchronizable Keychain items, and must still fall back through the
/// legacy service name. See `NotificationServiceKeychainQuery`'s own doc
/// comment for why this pure-value type exists instead of testing
/// `NotificationService.password(forAccountId:)` (an app-extension target,
/// not `swift test`-reachable) directly.
struct NotificationServiceKeychainQueryTests {
    @Test
    func triesCurrentServiceFirstThenLegacyServicesInOrder() {
        let attempts = NotificationServiceKeychainQuery.attemptsInOrder(accountId: "acct-1", accessGroup: "group.example")

        #expect(attempts.map(\.service) == [NotificationServiceKeychainQuery.currentService] + NotificationServiceKeychainQuery.legacyServices)
    }

    /// The actual Task #216 regression: every attempt must ask
    /// `SecItemCopyMatching` to match regardless of `kSecAttrSynchronizable`
    /// — omitting that (the bug) makes the Keychain's documented default
    /// return only *non*-synchronizable items, which is exactly what made
    /// a password written by `KeychainCredentialStore.setPassword` (always
    /// synchronizable, post-M11) invisible to this Extension.
    @Test
    func everyAttemptMatchesAnySynchronizableState() {
        let attempts = NotificationServiceKeychainQuery.attemptsInOrder(accountId: "acct-1", accessGroup: nil)

        #expect(!attempts.isEmpty)
        #expect(attempts.allSatisfy { $0.matchesAnySynchronizableState })
    }

    @Test
    func carriesAccountIdAndAccessGroupThroughEveryAttempt() {
        let attempts = NotificationServiceKeychainQuery.attemptsInOrder(accountId: "acct-42", accessGroup: "group.otegami.shared")

        #expect(attempts.allSatisfy { $0.accountId == "acct-42" })
        #expect(attempts.allSatisfy { $0.accessGroup == "group.otegami.shared" })
    }

    @Test
    func accessGroupNilPassesThroughAsNil() {
        let attempts = NotificationServiceKeychainQuery.attemptsInOrder(accountId: "acct-1", accessGroup: nil)

        #expect(attempts.allSatisfy { $0.accessGroup == nil })
    }

    /// Guards against silently losing the `52df393` rename fallback this
    /// Extension never had before Task #216 — an empty list here would mean
    /// a device stuck on the pre-rename service name has no recovery path.
    @Test
    func legacyServicesIsNonEmpty() {
        #expect(!NotificationServiceKeychainQuery.legacyServices.isEmpty)
    }
}
