import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Dynamic (light/dark) color support

/// `Color.init(light:dark:)` — the primitive every token in `OtegamiColor`
/// is built from. The design handoff (`docs/design-system.md`,
/// "Design Tokens" section) explicitly ships light-only placeholder values
/// and says to "トークン化して両対応にすること" (tokenize so both light and
/// dark are covered), since dark mode was never designed for the
/// wireframes. Rather than picking dark equivalents once and hardcoding
/// them, every token goes through this initializer so the light/dark pair
/// lives in exactly one place (`OtegamiColor.swift`) and nothing else in
/// the app ever branches on `colorScheme` to pick a color by hand.
///
/// Backed by `UIColor`/`NSColor`'s dynamic-provider initializers, which
/// resolve against the *rendering* trait/appearance (so this also works
/// correctly inside `ImageRenderer`, previews, and anywhere else that
/// isn't the live window's own trait collection) rather than sampling
/// `UITraitCollection.current`/`NSApp.effectiveAppearance` once at
/// creation time.
public extension Color {
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        }))
        #else
        self = light
        #endif
    }

    /// Convenience for a token defined directly from hex pairs, so
    /// `OtegamiColor.swift` can stay a flat list of `0xRRGGBB` literals
    /// instead of nested `Color(red:green:blue:)` calls.
    init(light hexLight: UInt32, dark hexDark: UInt32) {
        self.init(light: Color(hex: hexLight), dark: Color(hex: hexDark))
    }

    /// `0xRRGGBB` → `Color`. Internal on purpose — call sites should go
    /// through `OtegamiColor`'s named tokens, never construct a raw hex
    /// color inline (that's exactly the "生の色名を UI 側に露出させない"
    /// rule `docs/design-system.md` documents).
    init(hex: UInt32) {
        let r = Double((hex & 0xFF0000) >> 16) / 255
        let g = Double((hex & 0x00FF00) >> 8) / 255
        let b = Double(hex & 0x0000FF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
