import Foundation
import Testing

@testable import PushRelayClient

/// Unit coverage for `SharedAvatarStore` — the App Group handoff the app
/// writes sender avatars into and the Notification Service Extension reads
/// them back out of. Every test points the store at a fresh temporary
/// directory rather than a real App Group container (a SwiftPM test bundle
/// carries no such entitlement), which is exactly why
/// `init(directory:)` exists alongside `init?(appGroupIdentifier:)`.
///
/// What can't be covered here: the actual `INImage(url:)`/`updating(from:)`
/// decoration and the file protection class' effect on a locked device —
/// both need a real device (`docs/push-notification-actions.md`'s 実機での
/// 確認ポイント).
@Suite("SharedAvatarStore")
struct SharedAvatarStoreTests {
    private func makeStore() -> SharedAvatarStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SharedAvatarStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SharedAvatarStore(directory: directory)
    }

    private let pngData = Data([0x89, 0x50, 0x4E, 0x47])

    @Test("address normalization collapses case and surrounding whitespace")
    func normalizationMatchesGravatarRules() {
        #expect(SharedAvatarStore.normalize("  MyEmailAddress@Example.COM ") == "myemailaddress@example.com")
    }

    @Test("addresses differing only by case or whitespace resolve to the same file")
    func fileURLIsCaseAndWhitespaceInsensitive() {
        let store = makeStore()
        let canonical = store.fileURL(for: "sender@example.com")
        #expect(store.fileURL(for: "Sender@Example.com") == canonical)
        #expect(store.fileURL(for: "  sender@example.com\n") == canonical)
        #expect(store.fileURL(for: "other@example.com") != canonical)
    }

    @Test("a written entry reads back as a file URL")
    func writeThenRead() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(store.write(pngData, for: "sender@example.com"))
        let url = try #require(store.imageURL(for: "SENDER@example.com"))
        #expect(try Data(contentsOf: url) == pngData)
    }

    @Test("an address that was never written reads back as nil")
    func missingEntryIsNil() {
        let store = makeStore()
        #expect(store.imageURL(for: "nobody@example.com") == nil)
    }

    @Test("an entry older than the TTL reads back as nil")
    func expiredEntryIsNil() {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(store.write(pngData, for: "sender@example.com"))
        let wellPastTTL = Date().addingTimeInterval(SharedAvatarStore.defaultTimeToLive + 60)
        #expect(store.imageURL(for: "sender@example.com", now: wellPastTTL) == nil)
        // Still readable from inside the window.
        #expect(store.imageURL(for: "sender@example.com", now: Date().addingTimeInterval(60)) != nil)
    }

    @Test("prune drops expired entries and keeps live ones")
    func pruneDropsExpired() {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(store.write(pngData, for: "a@example.com"))
        #expect(store.write(pngData, for: "b@example.com"))
        let wellPastTTL = Date().addingTimeInterval(SharedAvatarStore.defaultTimeToLive + 60)
        store.prune(now: wellPastTTL)

        #expect(store.imageURL(for: "a@example.com") == nil)
        #expect(store.imageURL(for: "b@example.com") == nil)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: "a@example.com").path(percentEncoded: false)) == false)
    }

    @Test("prune enforces the entry limit, keeping the newest entries")
    func pruneEnforcesEntryLimit() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let addresses = (0..<5).map { "sender\($0)@example.com" }
        // Distinct modification dates, oldest first, so "keep the newest"
        // has something deterministic to order by.
        for (index, address) in addresses.enumerated() {
            #expect(store.write(pngData, for: address))
            let stamp = Date().addingTimeInterval(TimeInterval(index) - 100)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: store.fileURL(for: address).path(percentEncoded: false))
        }

        store.prune(entryLimit: 2)

        #expect(store.imageURL(for: addresses[0]) == nil)
        #expect(store.imageURL(for: addresses[1]) == nil)
        #expect(store.imageURL(for: addresses[2]) == nil)
        #expect(store.imageURL(for: addresses[3]) != nil)
        #expect(store.imageURL(for: addresses[4]) != nil)
    }

    @Test("no App Group identifier yields no store")
    func nilAppGroupYieldsNoStore() {
        #expect(SharedAvatarStore(appGroupIdentifier: nil) == nil)
    }
}
