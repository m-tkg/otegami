import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// B4/B5 「送信者のプロフィールアイコン」: a circular avatar for a message's
/// sender. アバター強化バッチ以降は優先順位付きの複数情報源を持つ
/// (`docs/design-system.md` のこのバッチの節):
///
/// 1. 連絡先の写真 (`ContactPhotoResolver`, オンデバイス)
/// 2. Google プロフィール写真 (`GoogleProfilePhotoAvatarResolver`, Gmail
///    アカウントが1つ以上ある場合のみ — People API に差出人アドレスを送信)
/// 3. Gravatar (`GravatarAvatarResolver`, 差出人アドレスのハッシュを
///    gravatar.com に送信 — 既定 ON、設定で無効化可)
/// 4. BIMI/企業ロゴの favicon (`CompanyLogoAvatarResolver`)
/// 5. どれも解決できなければイニシャル + アカウント色
///    (`OtegamiAccountColor`) — 元々の唯一の実装で、いまもこのビュー自身が
///    直接描画する最終フォールバック。
///
/// 実際の解決は `@Environment(\.avatarImageResolver)` (`AvatarImageResolving`
/// プロトコル、`AvatarImageResolving.swift` 参照) 越しに行う — この型自体は
/// `Contacts`/`URLSession` の類に一切依存しないので、`DesignSystemCatalog`
/// (resolver を注入しない) では常にイニシャル表示のまま安全に描画できる。
/// Used by `ThreadRowView` (B4, the message list), `MessageView`'s
/// per-message header (B5, the thread detail screen), and
/// `ThreadMessageSummaryRow`'s collapsed-row preview.
public struct SenderAvatar: View {
    private let displayName: String?
    private let address: String
    private let accountId: String
    /// D「アカウントのラベル色を変更可能に」: `AccountRecord.labelColorKey`,
    /// forwarded as-is. See `AccountColorRail`'s identical field / `OtegamiAccountColor.color(for:override:)`.
    private let labelColorKey: String?
    private let diameter: CGFloat

    @Environment(\.avatarImageResolver) private var resolver
    /// `nil` until (if ever) `resolver` resolves a non-`nil` image for
    /// `address` — the initials fallback renders unconditionally underneath
    /// this, so there is no loading spinner/placeholder state to represent
    /// separately (一覧のスクロールをブロックしない、`docs/design-system.md`
    /// の要件どおり: このビューは非同期解決を`.task`で待つだけで、初期描画は
    /// 常に即座にイニシャルで完了する)。
    @State private var imageData: Data?

    /// - Parameters:
    ///   - displayName: the sender's display name if the message had one
    ///     (`EmailAddress.name`); initials are derived from this when
    ///     present, falling back to `address` otherwise.
    ///   - address: the sender's email address — always used for the
    ///     background color's stability (`OtegamiAccountColor.color(for:)`
    ///     keys off the *account* this message belongs to, not the sender,
    ///     so every avatar for messages in the same account reads
    ///     consistently even though the initials differ per sender) and as
    ///     the initials fallback.
    ///   - accountId: which account this message belongs to — the avatar's
    ///     background color, not the sender's own identity, so a user
    ///     visually associates "this row/header is in account X" the same
    ///     way `AccountColorRail`/`AccountFilterChip` already do.
    ///   - diameter: 28pt in the list row (`ThreadRowView`, close to a
    ///     typical Mail-app avatar size at this app's row density), 36pt in
    ///     the detail header (`MessageView`, given more room next to the
    ///     larger headline-weight sender name there).
    public init(displayName: String?, address: String, accountId: String, labelColorKey: String? = nil, diameter: CGFloat) {
        self.displayName = displayName
        self.address = address
        self.accountId = accountId
        self.labelColorKey = labelColorKey
        self.diameter = diameter
    }

    public var body: some View {
        // Decoded once per `body` evaluation and shared by the fill color
        // and `avatarContent` below, rather than each reading the
        // `platformImage` computed property (and so re-decoding
        // `imageData`) independently.
        let resolvedImage = platformImage
        return Circle()
            // Task #87 (3) / Task #93: both a resolved image (Google 写真/
            // Gravatar/BIMI・favicon/連絡先写真) and the initials fallback
            // sit on the same neutral dark-gray chip
            // (`OtegamiColor.avatarImageBackdrop`) — a transparent PNG
            // logo's margin previously read as an odd color-keyed halo, a
            // dark logo mark could disappear into a dark account color, and
            // (Task #93) the account-color-keyed initials background was
            // visually inconsistent with the image case and not guaranteed
            // to contrast with the white initials text in every account
            // color. `accountId`/`labelColorKey` remain stored properties
            // (call sites still pass them) but no longer feed the fill
            // color — kept for API stability and in case a future design
            // wants the account-color signal back in a different spot
            // (e.g. a small colored ring).
            .fill(OtegamiColor.avatarImageBackdrop)
            .frame(width: diameter, height: diameter)
            .overlay {
                avatarContent(image: resolvedImage)
            }
            .accessibilityHidden(true)
            // `id: address`: a `SenderAvatar` instance is reused by SwiftUI
            // across row recycling for a *different* address (same identity
            // in the view tree) without necessarily reinitializing `@State`
            // — keying the task to `address` restarts resolution (and clears
            // the previous address' stale `imageData`) whenever the address
            // this instance is showing actually changes.
            .task(id: address) {
                imageData = nil
                guard let resolver, !address.isEmpty else { return }
                imageData = await resolver.resolveAvatarImageData(displayName: displayName, address: address)
            }
    }

    @ViewBuilder
    private func avatarContent(image: Image?) -> some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            Text(initials)
                .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var platformImage: Image? {
        guard let imageData else { return nil }
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: imageData) else { return nil }
        return Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: imageData) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }

    /// Up to 2 characters: the first letter of each of the first two
    /// whitespace-separated words in `displayName` (matches how "First
    /// Last" style display names read as "FL"), or just the first
    /// character of a single-word name/the address's local part when
    /// there's nothing to split — always uppercased, and always at least
    /// one character unless both `displayName` and `address` are somehow
    /// empty (a defensive fallback, not expected in practice: every synced
    /// message has a non-empty `from` address).
    private var initials: String {
        let source = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!
            : String(address.split(separator: "@").first ?? Substring(address))
        let words = source.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        if let first = source.first {
            return String(first).uppercased()
        }
        return "?"
    }
}
