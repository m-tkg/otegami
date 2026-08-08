import Foundation
import PushRelayClient
import Testing

/// Communication Notifications (Task: 送信者アバター付きプッシュ通知) — pure
/// decision logic tests for `NotificationService.senderDecision(...)`/
/// `.conversationIdentifier(accountId:senderAddress:)`
/// (`CommunicationNotification.swift`). Same "`NotificationService.swift`
/// itself compiled directly into this target's sources" approach as
/// `NotificationServiceEnvelopeContentDecisionTests`/
/// `NotificationServiceSyncFirstDecisionTests` — no real `Intents`
/// donation, `UNMutableNotificationContent`, or App Group container
/// involved. `SharedAvatarStore(directory:)` is pointed at a fresh
/// temporary directory per test so the shared avatar cache can be
/// populated (or left empty) under full test control, mirroring
/// `SharedAvatarStore`'s own test suite.
@Suite("Communication Notification sender decision")
struct CommunicationNotificationDecisionTests {
    private static let address = "alice@example.test"

    /// A fresh `SharedAvatarStore` backed by a new temporary directory —
    /// never shared across tests, so one test writing an avatar can never
    /// leak into another's "cache miss" expectation.
    private func makeAvatarStore(withCachedAvatarFor address: String? = nil) -> SharedAvatarStore {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CommunicationNotificationDecisionTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let store = SharedAvatarStore(directory: directory)
        if let address {
            #expect(store.write(Data([0x89, 0x50, 0x4E, 0x47]), for: address))
        }
        return store
    }

    // MARK: - senderDecision

    @Test("showsSender off skips before even looking at the avatar cache")
    func showsSenderOffSkips() {
        let preferences = NotificationContentPreferences(showsSender: false, showsSubject: true, showsBodyPreview: true)
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice",
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: preferences,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: Self.address)
        )
        #expect(decision == .skip(reason: .showsSenderOff))
    }

    @Test("the list-display \"show avatar\" toggle being off skips even though showsSender is on")
    func showAvatarOffSkips() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice",
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: false,
            avatarStore: makeAvatarStore(withCachedAvatarFor: Self.address)
        )
        #expect(decision == .skip(reason: .showAvatarOff))
    }

    @Test("no sender address anywhere (payload or sync) skips")
    func noSenderAddressSkips() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: nil,
            payloadSenderName: nil,
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore()
        )
        #expect(decision == .skip(reason: .noSenderAddress))
    }

    @Test("a resolved address with no cached avatar skips — never falls back to an initials placeholder")
    func avatarCacheMissSkips() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice",
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore() // no entry written for `Self.address`
        )
        #expect(decision == .skip(reason: .avatarCacheMiss))
    }

    @Test("no SharedAvatarStore at all (App Group unreachable) is treated the same as a cache miss")
    func noAvatarStoreIsTreatedAsCacheMiss() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice",
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: nil
        )
        #expect(decision == .skip(reason: .avatarCacheMiss))
    }

    @Test("the payload's own sender is preferred over a sync-resolved one when both are present")
    func payloadSenderTakesPriorityOverSync() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice (payload)",
            syncSenderAddress: "bob@example.test",
            syncSenderName: "Bob (sync)",
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: Self.address)
        )
        guard case .decorate(let sender) = decision else {
            Issue.record("expected .decorate, got \(decision)")
            return
        }
        #expect(sender.address == Self.address)
        #expect(sender.displayName == "Alice (payload)")
    }

    @Test("falls back to the sync-resolved sender when the payload named none")
    func fallsBackToSyncSenderWhenPayloadHasNone() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: nil,
            payloadSenderName: nil,
            syncSenderAddress: "bob@example.test",
            syncSenderName: "Bob (sync)",
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: "bob@example.test")
        )
        guard case .decorate(let sender) = decision else {
            Issue.record("expected .decorate, got \(decision)")
            return
        }
        #expect(sender.address == "bob@example.test")
        #expect(sender.displayName == "Bob (sync)")
    }

    @Test("an empty payload address string is treated as absent, falling back to sync")
    func emptyPayloadAddressFallsBackToSync() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: "",
            payloadSenderName: nil,
            syncSenderAddress: "bob@example.test",
            syncSenderName: "Bob (sync)",
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: "bob@example.test")
        )
        guard case .decorate(let sender) = decision else {
            Issue.record("expected .decorate, got \(decision)")
            return
        }
        #expect(sender.address == "bob@example.test")
    }

    @Test("a resolved sender with no display name falls back to the address as the display name")
    func missingDisplayNameFallsBackToAddress() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: nil,
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: Self.address)
        )
        guard case .decorate(let sender) = decision else {
            Issue.record("expected .decorate, got \(decision)")
            return
        }
        #expect(sender.displayName == Self.address)
    }

    // MARK: - conversationIdentifier

    @Test("stable across the same address's casing/whitespace varying")
    func conversationIdentifierIgnoresCasingAndWhitespace() {
        let lower = NotificationService.conversationIdentifier(accountId: "account-1", senderAddress: "alice@example.test")
        let mixedWithWhitespace = NotificationService.conversationIdentifier(accountId: "account-1", senderAddress: "  Alice@Example.Test  ")
        #expect(lower == mixedWithWhitespace)
    }

    @Test("different accountId values produce different conversation identifiers for the same address")
    func conversationIdentifierDiffersByAccount() {
        let first = NotificationService.conversationIdentifier(accountId: "account-1", senderAddress: Self.address)
        let second = NotificationService.conversationIdentifier(accountId: "account-2", senderAddress: Self.address)
        #expect(first != second)
    }

    @Test("a decorated decision's conversationIdentifier matches conversationIdentifier(accountId:senderAddress:) directly")
    func decisionConversationIdentifierMatchesDirectComputation() {
        let decision = NotificationService.senderDecision(
            accountId: "account-1",
            payloadSenderAddress: Self.address,
            payloadSenderName: "Alice",
            syncSenderAddress: nil,
            syncSenderName: nil,
            preferences: .allEnabled,
            showsAvatar: true,
            avatarStore: makeAvatarStore(withCachedAvatarFor: Self.address)
        )
        guard case .decorate(let sender) = decision else {
            Issue.record("expected .decorate, got \(decision)")
            return
        }
        #expect(sender.conversationIdentifier == NotificationService.conversationIdentifier(accountId: "account-1", senderAddress: Self.address))
    }
}
