import SwiftUI

/// Otegami's semantic color tokens — light/dark pairs, named by *purpose*
/// (background / surface / ink / accent / destructive / divider), never by
/// the raw hex value. UI code should only ever reach for a name from this
/// list; if you find yourself wanting a color that isn't here, add a token
/// here first rather than writing `Color(hex:)` at the call site — see
/// `docs/design-system.md`.
///
/// Light values are the ones the design handoff shipped
/// (`design_handoff_ios_mail/README.md`'s "Design Tokens" table) — they're
/// explicitly *placeholders*, not final brand colors, but they're what the
/// wireframes were built against, so they're the starting point here too.
/// The handoff's own dark-mode guidance is "未設計。トークン化して両対応に
/// すること" (not designed — tokenize it so both are covered); the dark
/// values below are this pass's answer to that, chosen to keep the same
/// "薄い水色ベース" (pale sky-blue base) feel inverted onto a dark paper
/// rather than falling back to a generic near-black/near-white pair.
/// Nothing here is final brand identity — treat it as a reasonable,
/// internally-consistent first pass that a future design pass can revise
/// token-by-token without touching call sites.
public enum OtegamiColor {
    // MARK: 背景・面 (background / surface)

    /// The app's base "paper" color — screens' outermost background.
    public static let background = Color(light: 0xEEF3F6, dark: 0x10191E)

    /// Cards, rows, sheets, and anything else that sits visually "on top
    /// of" `background`. The dark value is deliberately several steps
    /// lighter than `background` (not just a subtle tint) — an early pass
    /// used a much closer pair and the two were nearly indistinguishable
    /// in the design-system catalog screenshot (`docs/design-system.md`),
    /// which defeats the point of a separate surface token in a dark UI
    /// where elevation has to read from lightness since there's no
    /// drop-shadow convention here.
    public static let surface = Color(light: 0xFFFFFF, dark: 0x1F2E36)

    // MARK: インク (text/icon ink)

    /// Primary text/icon color (subjects, body copy, active icons).
    public static let ink = Color(light: 0x1A1A1A, dark: 0xF2F6F8)

    /// Secondary text — previews, sender names, timestamps.
    public static let inkSecondary = Color(light: 0x666666, dark: 0xAAB6BB)

    /// Tertiary/disabled-weight text — the handoff's "薄" (faint) step.
    public static let inkTertiary = Color(light: 0x999999, dark: 0x7C8A8F)

    // MARK: 水色ベース (pale-blue base — selection/emphasis fills)

    /// Faintest emphasis fill (e.g. a lightly-highlighted row). Sits
    /// between `background` and `surface` in lightness in both modes,
    /// same as the handoff's light values do (`F4F9FC` between `EEF3F6`
    /// and `FFFFFF`).
    public static let paleBase = Color(light: 0xF4F9FC, dark: 0x18262D)

    /// Mid emphasis fill (e.g. selected-row background, active chip fill).
    public static let paleBaseStrong = Color(light: 0xCFE4EE, dark: 0x25404B)

    /// Strongest emphasis fill (e.g. the active state of a filter chip).
    public static let paleBaseStrongest = Color(light: 0x9FC9DD, dark: 0x2E5A6B)

    // MARK: 水色アクセント (pale-blue accent — unread/links/icons)

    /// Accent for icons, unread dots, and other non-text UI elements.
    public static let accent = Color(light: 0x3D7F9E, dark: 0x7FC7E3)

    /// Accent for *text* (links, "EN" badge label, etc.) — a step deeper
    /// than `accent` in light mode per the handoff's note ("本文サイズの
    /// アクセント文字色は使わず、濃いステップを使う"), and a step lighter
    /// in dark mode for the equivalent contrast reason.
    public static let accentText = Color(light: 0x2A6B88, dark: 0x9AD6EC)

    // MARK: 破壊的操作 (destructive)

    /// Delete/discard actions — the one color carried over unchanged from
    /// the Modernist base system (`#ec3013`) rather than derived from the
    /// pale-blue family. Brightened slightly in dark mode for contrast
    /// against the darker surface, while staying in the same red-orange
    /// family.
    public static let destructive = Color(light: 0xEC3013, dark: 0xFF6A46)

    // MARK: 区切り (dividers)

    /// Primary structural divider — 2pt solid, per the handoff's Modernist
    /// styling (`Stroke.divider`/`CornerRadius.none` in `Borders.swift`).
    public static let divider = Color(light: 0x1A1A1A, dark: 0x3C4A52)

    /// Secondary/row-level divider — 1pt dashed, quieter than `divider`.
    public static let dividerSubtle = Color(light: 0xCCCCCC, dark: 0x2A363C)
}
