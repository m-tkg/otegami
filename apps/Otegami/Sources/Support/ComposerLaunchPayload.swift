import Foundation

/// What to open `ComposerView` with: a brand-new message, or a reply to an
/// existing one (plan: "ツールバー「作成」ボタン" for new, per-message "返信"/
/// "全員に返信" for reply). `Codable`/`Hashable` so macOS can pass it as a
/// `WindowGroup(for:)` value (each compose action opens its own window);
/// `Identifiable` (a fresh `UUID` per construction) so iOS can drive it as a
/// `.sheet(item:)` — a second "作成" tap while one composer sheet is already
/// up should present a distinct one, not be coalesced by SwiftUI's identity
/// diffing into reusing the dismissed one's state.
struct ComposerLaunchPayload: Identifiable, Codable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case new
        case reply(originalMessageId: Int64, replyAll: Bool)
    }

    var id = UUID()
    var kind: Kind

    static let new = ComposerLaunchPayload(kind: .new)

    static func reply(originalMessageId: Int64, replyAll: Bool) -> ComposerLaunchPayload {
        ComposerLaunchPayload(kind: .reply(originalMessageId: originalMessageId, replyAll: replyAll))
    }
}
