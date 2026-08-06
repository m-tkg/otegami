import SwiftUI

/// Otegami's semantic color tokens — light/dark pairs, named by *purpose*
/// (background / surface / ink / accent / destructive / divider), never by
/// the raw hex value. UI code should only ever reach for a name from this
/// list; if you find yourself wanting a color that isn't here, add a token
/// here first rather than writing `Color(hex:)` at the call site — see
/// `docs/design-system.md`.
///
/// Light values are the ones the design handoff shipped
/// (`docs/design-system.md`'s "Design Tokens" table) — they're
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

    /// Task #85 (実機フィードバック「フローティングボタンの青をもう少し
    /// 濃く」): `accent`より一段深い、常に同じ向き (どちらのモードでも
    /// 「より濃い」) に振れる青 — `OtegamiFloatingButton`の塗りつぶし専用。
    /// `accentText`を丸ごと流用しなかった理由: `accentText`はダークモードで
    /// **より明るい**方向に振れる (本文上の文字コントラスト用トークンの
    /// ため) — 白アイコンを乗せる塗りつぶしの円には逆効果 (`accent`の
    /// ダーク値`0x7FC7E3`はただでさえ薄い水色で、白アイコンとのコントラ
    /// ストが低かった)。ダーク値は`accent`のライト値をそのまま「一段深い
    /// ステップ」として再利用しているが、ライト値は`accentText`とは別の、
    /// さらに一段深い値にしてある。Liquid Glass Phase 0 で
    /// `OtegamiFloatingButtonTone`(旧`active`ケース含む) 自体は削除した
    /// が、`accentFloating`の値そのものはフローティングボタンの塗りとして
    /// 今も使うため変更していない。
    public static let accentFloating = Color(light: 0x235A73, dark: 0x3D7F9E)

    /// Task #108 続報 (実機フィードバック「undo トーストの『元に戻す』の色が
    /// 薄くて見えづらい」): `ink` を背景にした要素 (トースト等、周囲の
    /// モードと明暗が反転した面) の上に載せるアクセント文字色。`accentText`
    /// はあくまで通常背景上のコントラスト用にモードへ追随するトークンなので、
    /// 反転面に載せると常に沈む — こちらはモードに対して逆向き
    /// (ライトモード = 暗い ink の上なので明るい水色、ダークモード = 明るい
    /// ink の上なので深い青) に振れる。
    public static let accentTextOnInk = Color(light: 0x9AD6EC, dark: 0x2A6B88)

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

    // MARK: アバター画像の下地 (avatar image backdrop)

    /// Task #87 (3): the chip `SenderAvatar` fills *behind an image* (Google
    /// profile photo / Gravatar / BIMI-or-favicon company logo / a synced
    /// contact photo) — never behind the initials fallback, which keeps
    /// using `OtegamiAccountColor.color(for:override:)` as before. A
    /// transparent PNG (most company logos) previously sat directly on
    /// `SenderAvatar`'s existing account-color fill, so a dark logo mark
    /// could disappear into a dark account color, and the transparent
    /// margin around a non-circular logo read as an odd color-keyed halo
    /// rather than a neutral mat. Deliberately a plain, desaturated dark
    /// gray — distinct from every other token above, all of which lean
    /// into this design system's pale-blue family — since the whole point
    /// is a neutral backdrop that doesn't fight whatever color the logo
    /// itself actually is. The dark-mode value is a step *lighter* than
    /// `surface`/`background` (not the same near-black) so the chip still
    /// reads as its own distinct shape against the app's dark paper rather
    /// than blending into it.
    public static let avatarImageBackdrop = Color(light: 0x4A4A4A, dark: 0x3A3F42)
}
