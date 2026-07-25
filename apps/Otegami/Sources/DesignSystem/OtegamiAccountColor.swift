import SwiftUI

/// Deterministically assigns each account a color from a small fixed
/// palette, keyed by the account's stable id (`AccountRecord.id`, a
/// string) — needed for 1d's "アカウント色の左罫線" (per-account 3px left
/// rail on each message row, see `AccountColorRail`) and reusable
/// anywhere else an account needs a recognizable color (e.g. the filter
/// chips in 1a).
///
/// Deliberately *not* keyed by `String.hashValue` — Swift salts that hash
/// per process launch specifically to prevent it being relied on as
/// stable, which is exactly what this needs to be (the same account
/// should get the same color every launch, on every device). Uses FNV-1a
/// instead, a simple non-cryptographic hash with no per-process salt.
public enum OtegamiAccountColor {
    // Each hue is its own top-level `let` (rather than all eight sitting
    // inline inside one `[Color] = [...]` array-literal expression) —
    // Xcode 27 flagged the combined array literal as slow to type-check
    // (`docs/ci.md`'s "SwiftUI ビューの型チェックタイムアウト" note documents
    // the same class of problem for view bodies; this is the same
    // underlying inference cost, just for an array literal of initializer
    // calls instead of a modifier chain). Splitting it into eight
    // independently-typed statements plus one array literal of bare names
    // gives the type-checker nothing to combinatorially search: each `let`
    // has an inferred type of exactly `Color` on its own, and the final
    // array literal is just eight already-typed references.
    //
    /// Eight muted hues that stay in the same desaturated, "上品" family
    /// as the base pale-blue tokens (`OtegamiColor.paleBase`/`.accent`)
    /// rather than reading as a generic Material-style bright category
    /// palette — chosen to sit *alongside* `OtegamiColor.accent` without
    /// being mistaken for it (accounts vs. the unread/link accent are
    /// different signals on the same row).
    private static let teal = Color(light: 0x2F8F82, dark: 0x6FCBBE)
    private static let indigo = Color(light: 0x5B6EC9, dark: 0x9AA8EA)
    private static let plum = Color(light: 0x8A5A9E, dark: 0xC79FDB)
    private static let amber = Color(light: 0xB8853A, dark: 0xE3B36E)
    private static let rose = Color(light: 0xC15B6E, dark: 0xE8A0AF)
    private static let sage = Color(light: 0x6B8F4E, dark: 0xA9CB86)
    private static let slateBlue = Color(light: 0x4A6FA5, dark: 0x8FB3E0)
    private static let coral = Color(light: 0xC97A54, dark: 0xE8A97F)

    private static let palette: [Color] = [teal, indigo, plum, amber, rose, sage, slateBlue, coral]

    /// The color assigned to `accountId`. Stable across launches and
    /// across devices (iCloud-synced accounts get the same color rail on
    /// every device once this ships) as long as `accountId` itself is
    /// stable, which `AccountRecord.id` already is.
    public static func color(for accountId: String) -> Color {
        palette[paletteIndex(for: accountId)]
    }

    static func paletteIndex(for accountId: String) -> Int {
        Int(fnv1aHash(accountId) % UInt64(palette.count))
    }

    /// FNV-1a, 64-bit. Not cryptographic — doesn't need to be, this only
    /// has to be stable and roughly-evenly-distributed across a handful
    /// of buckets.
    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
