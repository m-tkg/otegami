import SwiftUI

/// Liquid Glass helpers for iOS's chrome layer (toolbars/FAB/chips/search
/// field/toast/banner) — see `docs/design-system.md`'s "Liquid Glass 方針
/// (2026-08-07 採用)" section for the full policy this file implements:
/// chrome uses system-standard Liquid Glass (`glassEffect`/
/// `.buttonStyle(.glass)`), content (rows/body/cards) stays glass-free, and
/// tinted/prominent glass is reserved for compose-class primary actions.
/// macOS is unaffected (`CLAUDE.md`'s "macOS は現状維持") — nothing in this
/// file has any effect there.
///
/// **Buttons**: don't wrap a `Button` in a modifier like `otegamiGlassChrome`
/// below — apply `.buttonStyle(.glass)`/`.glassProminent` directly at the
/// call site instead (SwiftUI's own standard styles already produce the
/// correct capsule/rounded-rect Glass chrome, sizing, and content color for
/// a `Button`/`Toggle`; a wrapper would only fight or duplicate that). This
/// file's `otegamiGlassChrome(shape:)` modifier exists for the handful of
/// custom, non-`Button` chrome views (FAB circles composed via
/// `GlassEffectContainer`, toast/banner shapes) that need a raw
/// `glassEffect` instead.
///
/// **Not in the DesignSystemCatalog renderer**: `ImageRenderer` (what
/// `DesignSystemCatalog` uses for its offscreen PNG snapshots) cannot draw
/// `glassEffect` correctly, so no Glass-using component is registered in
/// `Catalog/CatalogComponentSection.swift` — verify Glass chrome visually
/// via `scripts/verify-screen.sh` against a real simulator instead (see
/// `docs/design-system.md`, same section).
public extension View {
    /// `glassEffect(.regular, in: shape)` on iOS, a no-op everywhere else.
    /// For this app's own custom chrome shapes only (not `Button`s — see
    /// this file's doc comment). Defaults to `Capsule()`, the shape every
    /// non-circular chrome element in this app (chips, search field) uses;
    /// pass `Circle()` for round chrome (e.g. a standalone icon badge that
    /// isn't already covered by `GlassEffectContainer`-based FAB
    /// morphing).
    func otegamiGlassChrome<S: Shape>(shape: S = Capsule()) -> some View {
        #if os(iOS)
        self.glassEffect(.regular, in: shape)
        #else
        self
        #endif
    }
}
