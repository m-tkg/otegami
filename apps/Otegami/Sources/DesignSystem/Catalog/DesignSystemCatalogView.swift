#if DEBUG
import SwiftUI

/// The catalog's actual content — every design-system token and basic
/// component, colors/typography/spacing/borders/account-palette plus live
/// component instances (`AccountFilterChip`, `UnreadDot`,
/// `AccountColorRail`, `SectionDivider`, `ENBadge`, a mock message row
/// exercising the tap-target/row-divider helpers together) — with **no**
/// `ScrollView` wrapper, so it has a real, finite intrinsic height.
///
/// Split out from `DesignSystemCatalogView` (which just adds the
/// `ScrollView` for interactive/on-device use) specifically because
/// `ImageRenderer` cannot capture a `ScrollView`'s content correctly:
/// `ScrollView` relies on being hosted in a real window for its
/// clip/offset machinery, so rendering it off-screen produces the right
/// *background* (that's outside the scroll machinery) but a blank
/// interior — confirmed while building `DesignSystemCatalog/`'s renderer,
/// which imports and renders *this* type directly instead of
/// `DesignSystemCatalogView`.
public struct DesignSystemCatalogContent: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CatalogColorSection()
            CatalogTypographySection()
            CatalogSpacingSection()
            CatalogBorderSection()
            CatalogAccountColorSection()
            CatalogComponentSection()
        }
        .padding(OtegamiSpacing.lg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            Text("Otegami Design System")
                .font(OtegamiFont.largeTitle())
                .foregroundStyle(OtegamiColor.ink)
            Text("design_handoff_ios_mail/README.md 準拠のトークンカタログ")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkTertiary)
        }
        .padding(.bottom, OtegamiSpacing.md)
    }
}

/// A one-screen, scrollable catalog of every design-system token and
/// basic component — see `DesignSystemCatalogContent`'s doc comment for
/// what's actually in it; this just adds the `ScrollView` for interactive
/// use (Xcode `#Preview`s below, or a future debug launch path).
///
/// `#if DEBUG`-gated end to end (every file under `Catalog/` is), so none
/// of this compiles into a Release build. Not wired into any real launch
/// path yet — this repo's parallel-in-flight work rule for this change
/// was "new files only, don't touch `OtegamiApp.swift`/`RootView`", so
/// hooking a debug launch argument into the real app's entry point is
/// left for the next phase (see `docs/design-system.md`). Verified
/// instead via `DesignSystemCatalog/`, a standalone SwiftPM executable
/// (built through a symlink into this same `Sources/DesignSystem/`
/// directory, so it's the *exact* same source, not a copy) that renders
/// `DesignSystemCatalogContent` off-screen with `ImageRenderer` in both
/// light and dark mode and writes PNGs — see that package's `main.swift`.
public struct DesignSystemCatalogView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            DesignSystemCatalogContent()
        }
        .background(OtegamiColor.background)
        .task { OtegamiFont.registerCustomFontsIfNeeded() }
    }
}

#Preview("Light") {
    DesignSystemCatalogView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DesignSystemCatalogView()
        .preferredColorScheme(.dark)
}
#endif
