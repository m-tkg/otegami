import SwiftUI
import OtegamiCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Task #129 (作成画面リッチテキスト化)/#161 (第2段): the formatting bar for
/// `ComposerView`'s body editor — 太字/イタリック/下線/打ち消し線/フォント
/// サイズ/文字色/背景色(ハイライト)/番号付きリスト/箇条書きリスト/引用ブロック/
/// インデント増減/リンク挿入/書式クリア, one control each. Task #161's 下部バー
/// 再構成: this bar itself no longer sits permanently above the body editor —
/// `ComposerView`'s bottom action bar (`flatBottomActionBar`) shows it only
/// while its "T" button is toggled on, Spark-style. Still an inline SwiftUI
/// toolbar (not a keyboard `inputAccessoryView`) for the same
/// screenshot-testability reason the original doc comment gave.
///
/// A single `@ViewBuilder` `body` with one `HStack` of independent small
/// control views — deliberately not a `ForEach` over a config array — keeps
/// this well clear of the SwiftUI type-check-timeout pitfall documented in
/// `docs/ci.md`; each control is its own small `View` type already (the
/// `Menu`-based ones' `ForEach` over a `CaseIterable` palette lives *inside*
/// that control's own small `body`, never inlined into this top-level
/// `HStack`), so the `HStack` itself stays a flat, cheap-to-check list.
struct RichTextFormattingBar: View {
    @ObservedObject var controller: RichTextEditingController
    /// Task #161: whether the link button should be enabled — a non-empty
    /// selection (something to wrap in `<a>`) or a collapsed cursor already
    /// sitting inside an existing link (`controller.typingState.linkURL`,
    /// which itself only reads non-`nil` in exactly that case — see
    /// `RichTextAttributedString.typingState(in:selectedRange:)`'s doc
    /// comment). A genuinely collapsed cursor with no link under it has
    /// nothing for `RichTextEditingController.setLink(_:)` to apply to.
    let hasSelection: Bool

    @State private var isShowingLinkSheet = false
    @State private var linkURLText = ""

    private var canUseLinkButton: Bool { hasSelection || controller.typingState.linkURL != nil }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OtegamiSpacing.xs) {
                FormatBarButton(systemImage: "bold", isActive: controller.typingState.isBold, accessibilityIdentifier: "composer.format.bold") {
                    controller.toggleBold()
                }
                FormatBarButton(systemImage: "italic", isActive: controller.typingState.isItalic, accessibilityIdentifier: "composer.format.italic") {
                    controller.toggleItalic()
                }
                FormatBarButton(systemImage: "underline", isActive: controller.typingState.isUnderline, accessibilityIdentifier: "composer.format.underline") {
                    controller.toggleUnderline()
                }
                FormatBarButton(systemImage: "strikethrough", isActive: controller.typingState.isStrikethrough, accessibilityIdentifier: "composer.format.strikethrough") {
                    controller.toggleStrikethrough()
                }
                Divider().frame(height: 20)
                FontSizeMenuButton(controller: controller)
                RichTextColorMenuButton(
                    systemImage: "character",
                    accessibilityIdentifier: "composer.format.textColor",
                    defaultLabel: "デフォルトの文字色",
                    currentColor: controller.typingState.textColor
                ) { controller.setTextColor($0) }
                RichTextColorMenuButton(
                    systemImage: "highlighter",
                    accessibilityIdentifier: "composer.format.highlight",
                    defaultLabel: "ハイライトなし",
                    currentColor: controller.typingState.backgroundColor
                ) { controller.setBackgroundColor($0) }
                Divider().frame(height: 20)
                FormatBarButton(systemImage: "list.bullet", isActive: controller.typingState.listStyle == .bullet, accessibilityIdentifier: "composer.format.bulletList") {
                    controller.toggleList(.bullet)
                }
                FormatBarButton(systemImage: "list.number", isActive: controller.typingState.listStyle == .ordered, accessibilityIdentifier: "composer.format.numberedList") {
                    controller.toggleList(.ordered)
                }
                FormatBarButton(systemImage: "text.quote", isActive: controller.typingState.indentLevel > 0, accessibilityIdentifier: "composer.format.quote") {
                    controller.toggleBlockquote()
                }
                FormatBarButton(systemImage: "decrease.indent", isActive: false, accessibilityIdentifier: "composer.format.outdent") {
                    controller.outdent()
                }
                FormatBarButton(systemImage: "increase.indent", isActive: false, accessibilityIdentifier: "composer.format.indent") {
                    controller.indent()
                }
                Divider().frame(height: 20)
                FormatBarButton(systemImage: "link", isActive: controller.typingState.linkURL != nil, accessibilityIdentifier: "composer.format.link") {
                    linkURLText = controller.typingState.linkURL ?? ""
                    isShowingLinkSheet = true
                }
                .disabled(!canUseLinkButton)
                .opacity(canUseLinkButton ? 1 : 0.4)
                FormatBarButton(systemImage: "textformat.slash", isActive: false, accessibilityIdentifier: "composer.format.clear") {
                    controller.clearFormatting()
                }
            }
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
        }
        .background(OtegamiColor.surface)
        .accessibilityIdentifier("composer.formattingBar")
        .sheet(isPresented: $isShowingLinkSheet) {
            LinkInputSheet(
                urlText: $linkURLText,
                hasExistingLink: controller.typingState.linkURL != nil,
                onSubmit: {
                    controller.setLink(linkURLText)
                    isShowingLinkSheet = false
                },
                onRemove: {
                    controller.setLink(nil)
                    isShowingLinkSheet = false
                },
                onCancel: { isShowingLinkSheet = false }
            )
        }
    }
}

/// One formatting bar button — pulled out into its own `View` (not an
/// inline closure in the `HStack` above) for the same reason
/// `ComposerView`'s `AttachmentRow` is its own type: keeps the containing
/// container's body a flat list of cheap-to-check leaves.
private struct FormatBarButton: View {
    let systemImage: String
    let isActive: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 32)
                .foregroundStyle(isActive ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? OtegamiColor.paleBaseStrong : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Task #161: フォントサイズ選択 — a `Menu` over `RichTextFontSize`'s four
/// presets. Its `ForEach` lives inside this control's own small `body`
/// (never inlined into `RichTextFormattingBar`'s top-level `HStack`) — see
/// that view's doc comment on why that split matters for CI's type-checker.
private struct FontSizeMenuButton: View {
    @ObservedObject var controller: RichTextEditingController

    var body: some View {
        Menu {
            ForEach(RichTextFontSize.allCases, id: \.self) { size in
                Button {
                    controller.setFontSize(size)
                } label: {
                    if controller.typingState.fontSize == size {
                        Label(size.displayName, systemImage: "checkmark")
                    } else {
                        Text(size.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 32)
                .foregroundStyle(controller.typingState.fontSize == .standard ? OtegamiColor.inkSecondary : OtegamiColor.accentText)
        }
        .accessibilityIdentifier("composer.format.fontSize")
    }
}

/// Task #161: 文字色/背景色(ハイライト) — one reusable `Menu` shared by both
/// (`RichTextColor`'s doc comment on why one palette serves both pickers).
/// `currentColor == nil` (デフォルト/ハイライトなし) is always the first item;
/// each preset shows as a colored swatch (`RichTextColor.swatchImage`, not a
/// tinted SF Symbol — see that property's doc comment for why a *tinted*
/// symbol doesn't actually show any color once it's inside this `Menu`), so
/// this stays a single `Label` per row rather than a custom `HStack` — keeps
/// this control's own `body` just as flat as `RichTextFormattingBar`'s.
private struct RichTextColorMenuButton: View {
    let systemImage: String
    let accessibilityIdentifier: String
    let defaultLabel: String
    let currentColor: RichTextColor?
    let onSelect: (RichTextColor?) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if currentColor == nil {
                    Label(defaultLabel, systemImage: "checkmark")
                } else {
                    Text(defaultLabel)
                }
            }
            ForEach(RichTextColor.allCases, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    // Task #178 (実機フィードバック「選ぶ前にどんな色か分から
                    // ない」/「チェックボックスもその色に」): the selection
                    // mark moved from the icon slot (a colored checkmark
                    // icon hits the exact same Menu-item-icon-recoloring
                    // limitation `swatchImage` works around) into the title
                    // itself — a leading "✓ " — so the icon slot is free to
                    // always show this row's own actual color swatch,
                    // selected or not.
                    Label {
                        Text(currentColor == color ? "\u{2713} \(color.displayName)" : color.displayName)
                    } icon: {
                        color.swatchImage
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 32)
                .foregroundStyle(currentColor?.swiftUIColor ?? OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Task #161: リンク挿入/編集/削除 — a small sheet (plan: "URL 入力はアラート or
/// 小シート") rather than an `.alert` with a `TextField`, so an *existing*
/// link's URL can be shown pre-filled for editing, and so there's room for
/// a distinct "削除する" action alongside "追加"/"キャンセル" without
/// crowding an alert's button row.
private struct LinkInputSheet: View {
    @Binding var urlText: String
    let hasExistingLink: Bool
    let onSubmit: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com", text: $urlText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .accessibilityIdentifier("composer.format.linkURLField")
                if hasExistingLink {
                    Button("リンクを削除", role: .destructive, action: onRemove)
                        .accessibilityIdentifier("composer.format.linkRemoveButton")
                }
            }
            .navigationTitle("リンク")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", action: onSubmit)
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("composer.format.linkSubmitButton")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 180)
        #endif
    }
}

private extension RichTextFontSize {
    var displayName: String {
        switch self {
        case .small: "小"
        case .standard: "標準"
        case .large: "大"
        case .xlarge: "特大"
        }
    }
}

private extension RichTextColor {
    var displayName: String {
        switch self {
        case .red: "赤"
        case .orange: "オレンジ"
        case .yellow: "黄"
        case .green: "緑"
        case .blue: "青"
        case .purple: "紫"
        case .gray: "グレー"
        case .black: "黒"
        case .white: "白"
        }
    }

    /// Bridges `platformColor` (`RichTextAttributedString`'s `UIColor`/
    /// `NSColor`, built from `hex`) into SwiftUI — used only for this
    /// picker's own toolbar-button tint (`RichTextColorMenuButton`'s own
    /// `label:`, a plain SwiftUI view, not a `Menu` row — that one *does*
    /// honor `.foregroundStyle` normally), never for anything that ends up
    /// persisted or sent (the HTML encoder works from `hex` directly).
    var swiftUIColor: Color {
        #if os(iOS)
        Color(uiColor: platformColor)
        #else
        Color(nsColor: platformColor)
        #endif
    }

    /// Task #178 (実機フィードバック「選ぶ前にどんな色か分からない」): a small
    /// filled-circle `Image` for this preset's `Menu` row icon, with the
    /// color baked directly into the bitmap's pixels and the image marked
    /// "original" rather than "template".
    ///
    /// `Menu`'s rows are backed by a native `UIMenu`/`NSMenu` on both
    /// platforms, and both re-tint *template* icons (which is what a plain
    /// `Image(systemName:)` is, and what `.foregroundStyle(_:)` on one
    /// inside a `Label` cannot override once it's inside a `Menu`) to a
    /// single system color — silently discarding whatever custom color the
    /// SF Symbol was given in SwiftUI. Confirmed on-device (実機フィード
    /// バック 2026-07-30): every row's icon rendered as a plain, uncolored
    /// dot no matter which preset it belonged to, even though the SwiftUI
    /// code (this file, before this task) looked like it should have shown
    /// one. Baking the color into the pixels themselves sidesteps the
    /// limitation entirely — the menu then just draws whatever's actually
    /// in the image instead of re-tinting it.
    ///
    /// `.white`/`.black` (this task's other addition to the palette) also
    /// get a thin hairline ring baked in, so the swatch doesn't disappear
    /// against a same-toned menu background — the same "見えなくならない
    /// ように" reasoning `AccountLabelColorPicker`'s `.rose` (also plain
    /// white) swatch already applies.
    var swatchImage: Image {
        RichTextColorSwatch.image(color: platformColor, hairline: self == .white || self == .black)
    }
}

/// Task #178: the bitmap renderer behind `RichTextColor.swatchImage` — kept
/// as its own small type rather than inline in the extension above just to
/// keep the platform `#if` branching self-contained in one place.
private enum RichTextColorSwatch {
    static let diameter: CGFloat = 18

    static func image(color: PlatformColor, hairline: Bool) -> Image {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
        let rendered = renderer.image { _ in
            let inset: CGFloat = hairline ? 1.5 : 1
            let rect = CGRect(x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2)
            let path = UIBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
            if hairline {
                UIColor(OtegamiColor.divider).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysOriginal))
        #else
        let size = NSSize(width: diameter, height: diameter)
        let rendered = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = hairline ? 1.5 : 1
            let ovalRect = rect.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(ovalIn: ovalRect)
            color.setFill()
            path.fill()
            if hairline {
                NSColor(OtegamiColor.divider).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        rendered.isTemplate = false
        return Image(nsImage: rendered)
        #endif
    }
}
