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
    /// Eight muted hues that stay in the same desaturated, "上品" family
    /// as the base pale-blue tokens (`OtegamiColor.paleBase`/`.accent`)
    /// rather than reading as a generic Material-style bright category
    /// palette — chosen to sit *alongside* `OtegamiColor.accent` without
    /// being mistaken for it (accounts vs. the unread/link accent are
    /// different signals on the same row).
    private static let palette: [Color] = [
        Color(light: 0x2F8F82, dark: 0x6FCBBE), // teal
        Color(light: 0x5B6EC9, dark: 0x9AA8EA), // indigo
        Color(light: 0x8A5A9E, dark: 0xC79FDB), // plum
        Color(light: 0xB8853A, dark: 0xE3B36E), // amber
        Color(light: 0xC15B6E, dark: 0xE8A0AF), // rose
        Color(light: 0x6B8F4E, dark: 0xA9CB86), // sage
        Color(light: 0x4A6FA5, dark: 0x8FB3E0), // slate blue
        Color(light: 0xC97A54, dark: 0xE8A97F), // coral
    ]

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
