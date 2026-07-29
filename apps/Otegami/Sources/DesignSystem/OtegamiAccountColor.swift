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
    // Each hue is its own top-level `let` (rather than all twenty sitting
    // inline inside one `[Color] = [...]` array-literal expression) —
    // Xcode 27 flagged the combined array literal as slow to type-check
    // (`docs/ci.md`'s "SwiftUI ビューの型チェックタイムアウト" note documents
    // the same class of problem for view bodies; this is the same
    // underlying inference cost, just for an array literal of initializer
    // calls instead of a modifier chain). Splitting it into independently-
    // typed statements plus one array literal of bare names gives the
    // type-checker nothing to combinatorially search: each `let` has an
    // inferred type of exactly `Color` on its own, and the final array
    // literal is just already-typed references.
    //
    /// Task #72 (実機フィードバック): the original 8-hue palette read as
    /// "あまり違いがない" once more than a handful of accounts were
    /// configured (real device report: three accounts all landed on
    /// "amber"/gold). Expanded to 20 hues, declared here in ascending hue
    /// order (a full turn of the color wheel: red → orange → yellow →
    /// green → cyan → blue → purple → magenta → pink → back to red) —
    /// `PaletteColor.wheelIndex` and `leastUsedColorKey(avoiding:)` below
    /// depend on this declaration order to approximate hue distance
    /// without decomposing a resolved `Color` back into HSB at runtime
    /// (SwiftUI's `Color` doesn't expose that uniformly across platforms
    /// without a `UIColor`/`NSColor` bridge).
    ///
    /// The 12 hues added in Task #72 fill the gaps between the original 8
    /// so the resulting 20-stop wheel is close to evenly spaced (see the
    /// palette-design note in `docs/design-system.md` for the exact
    /// hue/gap numbers).
    ///
    /// Task #72 follow-up (実機フィードバック): the desaturated "上品" family
    /// Task #72 shipped with read as "5段階の色の差は小さい" once the wheel
    /// grew to 20 stops — adjacent hues (especially within the
    /// purple/blue families) were too close in saturation and value to
    /// tell apart at the size an account color actually renders at (a 3px
    /// rail, a small dot). Every hue below — **including the original 8,
    /// whose hue angle is unchanged but whose saturation/value is
    /// not** — was re-tuned to a vivid, high-saturation family closer to
    /// the reference screenshot's (Spark's picker), because "上品" and
    /// "はっきり見分けられる" turned out to be in tension at 20 stops.
    /// Saturation/value are picked per-hue rather than one flat pair for
    /// all 20: the yellow-green band (`sage`/`green`/`emerald`) needs a
    /// lower value than red/orange to avoid clipping to neon, and every
    /// dark-mode variant runs brighter/more saturated than its light-mode
    /// counterpart so it still pops against a black background instead of
    /// looking washed out next to it.
    ///
    /// This *is* a visible color change for every existing account
    /// (manually-picked or auto-assigned) — unlike the original Task #72
    /// hue-only expansion, keeping the exact old hex was explicitly not
    /// the goal this time (see the account-color re-tune note in
    /// `docs/design-system.md`). Only the case *names* (and therefore
    /// already-saved `labelColorKey` strings) are stable; the `Color`
    /// each name resolves to is not.
    ///
    /// Task #157 (実機フィードバック): a second re-tune, this time to match
    /// hex-for-hex the user's own reference screenshot of Spark's picker
    /// (Task #75 approximated "vivid, closer to Spark" from a description;
    /// this one uses the exact values). Same rule as Task #75 applies —
    /// case names/rawValues unchanged, only the resolved `Color`s move.
    /// New wrinkle: the reference picker's 20th/last swatch (grid
    /// bottom-right) is plain white, not another hue, so `rose` (the case
    /// occupying that slot) now resolves to white in both appearances
    /// instead of a dark-pink hue. White can't be auto-assigned or treated
    /// as a point on the hue wheel — see `autoAssignableCases`,
    /// `wheelIndex`, and `paletteIndex(for:)` below, all updated to exclude
    /// it; it's reachable only via an explicit picker tap
    /// (`AccountLabelColorPicker`, which also gives its swatch a hairline
    /// border so it doesn't disappear against the picker's own background).
    private static let red = Color(light: 0xBA3229, dark: 0xDB3B30)
    private static let coral = Color(light: 0xC74527, dark: 0xE8502E)
    private static let amber = Color(light: 0xCA6320, dark: 0xEB7325)
    private static let mustard = Color(light: 0xCD7F29, dark: 0xEE9330)
    private static let yellow = Color(light: 0xCF9A28, dark: 0xF0B32E)
    private static let sage = Color(light: 0xD4B737, dark: 0xF5D440)
    private static let green = Color(light: 0x42A42A, dark: 0x4FC532)
    private static let emerald = Color(light: 0x3E8E59, dark: 0x4CAF6E)
    private static let mint = Color(light: 0x50AE8B, dark: 0x5FCFA5)
    private static let teal = Color(light: 0x4BACCF, dark: 0x57C8F0)
    private static let cyan = Color(light: 0x3F81C7, dark: 0x4A97E8)
    private static let slateBlue = Color(light: 0x285FCA, dark: 0x2F6FEB)
    private static let indigo = Color(light: 0x2B48BF, dark: 0x3355E0)
    private static let periwinkle = Color(light: 0x492CDE, dark: 0x5433FF)
    private static let violet = Color(light: 0x6A39DE, dark: 0x7A42FF)
    private static let plum = Color(light: 0x791FBA, dark: 0x8E24DB)
    private static let lavender = Color(light: 0xA26BBF, dark: 0xBE7EE0)
    private static let magenta = Color(light: 0xBA2995, dark: 0xDB30B0)
    private static let pink = Color(light: 0xB1275D, dark: 0xD22E6E)
    /// Task #157 (実機フィードバック): the reference picker's 20th swatch
    /// (grid bottom-right) is plain white, not another hue — kept as its
    /// own `Color` constant (rather than inlining `.white`) so it reads the
    /// same as every other named stop above and so a future re-tune can
    /// find it by scanning this list. Same in light and dark: white doesn't
    /// need a dimmer light-mode variant the way a saturated hue does.
    private static let rose = Color(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// D「アカウントのラベル色を変更可能に」: a named, stable identifier for
    /// each palette entry — `AccountRecord.labelColorKey` stores this
    /// enum's `rawValue` (a plain `String`, since `OtegamiStore` can't
    /// import this app-target-only module; see that property's doc
    /// comment), and `AccountCloudSync`'s snapshot carries the same raw
    /// string so a manually-picked color travels between devices exactly
    /// like every other account field `docs/icloud-sync.md` syncs.
    /// Declared in ascending hue order (matching the `let`s above), which
    /// is what backs `AccountEditView`'s picker grid and `wheelIndex`
    /// below.
    ///
    /// Existing case names (`teal`…`coral`, the original 8) keep their
    /// rawValues unchanged — renaming a case would silently reinterpret
    /// every already-saved `labelColorKey` in the database and in
    /// iCloud-synced snapshots as "unrecognized", quietly falling back to
    /// 自動 (see `color(for:override:)`'s doc comment).
    public enum PaletteColor: String, CaseIterable, Sendable {
        case red, coral, amber, mustard, yellow, sage, green, emerald, mint, teal
        case cyan, slateBlue, indigo, periwinkle, violet, plum, lavender, magenta, pink, rose

        public var color: Color {
            switch self {
            case .red: OtegamiAccountColor.red
            case .coral: OtegamiAccountColor.coral
            case .amber: OtegamiAccountColor.amber
            case .mustard: OtegamiAccountColor.mustard
            case .yellow: OtegamiAccountColor.yellow
            case .sage: OtegamiAccountColor.sage
            case .green: OtegamiAccountColor.green
            case .emerald: OtegamiAccountColor.emerald
            case .mint: OtegamiAccountColor.mint
            case .teal: OtegamiAccountColor.teal
            case .cyan: OtegamiAccountColor.cyan
            case .slateBlue: OtegamiAccountColor.slateBlue
            case .indigo: OtegamiAccountColor.indigo
            case .periwinkle: OtegamiAccountColor.periwinkle
            case .violet: OtegamiAccountColor.violet
            case .plum: OtegamiAccountColor.plum
            case .lavender: OtegamiAccountColor.lavender
            case .magenta: OtegamiAccountColor.magenta
            case .pink: OtegamiAccountColor.pink
            case .rose: OtegamiAccountColor.rose
            }
        }

        /// This case's position in the hue-ascending, white-excluded wheel
        /// (`autoAssignableCases`) — used only for the circular hue-distance
        /// estimate in `leastUsedColorKey(avoiding:)`. `nil` for `.rose`
        /// (white, Task #157): white isn't a point on a hue wheel, so it
        /// has no position to return, and both call sites below must treat
        /// an existing white pick as having no bearing on hue distance
        /// rather than crashing on it.
        var wheelIndex: Int? {
            OtegamiAccountColor.autoAssignableCases.firstIndex(of: self)
        }
    }

    /// Every `PaletteColor` eligible for *automatic* assignment — i.e. all
    /// of `allCases` except `.rose` (white). Task #157: white must only
    /// ever be reached by an explicit picker tap
    /// (`AccountLabelColorPicker`), never handed out by the FNV-1a hash
    /// fallback (`paletteIndex(for:)`) or recommended by
    /// `leastUsedColorKey(avoiding:)` — a hash landing a brand-new account
    /// on "no color" by chance would look like a bug, and white has no hue
    /// to compare against other accounts' colors anyway. Relies on `.rose`
    /// being the last case declared in `PaletteColor` (see that enum's doc
    /// comment on ordering); `dropLast()` over recomputing a filter keeps
    /// this a cheap array slice rather than an `O(n)` scan on every call.
    private static var autoAssignableCases: [PaletteColor] {
        Array(PaletteColor.allCases.dropLast())
    }

    /// The color assigned to `accountId`, honoring a manually-picked
    /// `override` (`AccountRecord.labelColorKey`, decoded to
    /// `PaletteColor`) when present and recognized. Falls back to the
    /// deterministic FNV-1a hash assignment when `override` is `nil` *or*
    /// an unrecognized raw string (e.g. read by an older build against a
    /// newer palette) — stable across launches and across devices
    /// (iCloud-synced accounts get the same color rail on every device
    /// once this ships) as long as `accountId` itself is stable, which
    /// `AccountRecord.id` already is.
    public static func color(for accountId: String, override overrideKey: String? = nil) -> Color {
        resolvedPaletteColor(for: accountId, override: overrideKey).color
    }

    /// Same resolution as `color(for:override:)` but returns the
    /// `PaletteColor` case itself rather than its `Color` — what
    /// `leastUsedColorKey(avoiding:)` needs to compute hue distance from
    /// every already-assigned account without caring whether that
    /// account's color came from an explicit pick or the hash fallback.
    public static func resolvedPaletteColor(for accountId: String, override overrideKey: String? = nil) -> PaletteColor {
        if let overrideKey, let picked = PaletteColor(rawValue: overrideKey) {
            return picked
        }
        return autoAssignableCases[paletteIndex(for: accountId)]
    }

    /// Task #72「自動割当の改善」: which `PaletteColor` a *brand-new*
    /// account should be saved with (as an explicit `labelColorKey`, not
    /// left to the hash fallback), given the colors every existing
    /// account already resolves to. Picks the palette entry whose
    /// circular hue-wheel distance to its *nearest* used entry is
    /// largest — i.e. the color that reads as most different from
    /// whatever's already on screen, rather than letting the FNV-1a hash
    /// hand out a repeat by chance (real device report: three accounts in
    /// a row all landed on "amber"). Ties resolve to the lowest
    /// `wheelIndex` (declaration/hue order), so the result is
    /// deterministic given the same set of used colors.
    ///
    /// `existingAccountColors` is every other account's *resolved* color
    /// (`resolvedPaletteColor(for:override:)`, not just the ones with an
    /// explicit override) — an auto-assigned account still occupies a
    /// color slot that a new account shouldn't collide with. Returns
    /// `autoAssignableCases.first` (red) when there are no existing
    /// accounts to avoid, so the very first account added gets a fixed,
    /// predictable color rather than whatever its id happens to hash to.
    ///
    /// Task #157: both the candidate range and the hue-distance math run
    /// over `autoAssignableCases` (19 hues, `.rose`/white excluded) instead
    /// of `allCases` (20) — this function must never *return* white, and
    /// an existing account someone manually painted white contributes no
    /// `wheelIndex` (`nil`, dropped by `compactMap`) since white has no
    /// position on the hue wheel to measure distance from.
    public static func leastUsedColorKey(avoiding existingAccountColors: [PaletteColor]) -> PaletteColor {
        let usedIndices = existingAccountColors.compactMap(\.wheelIndex)
        guard !usedIndices.isEmpty else { return autoAssignableCases[0] }

        let wheelSize = autoAssignableCases.count
        // Shortest hop between two positions on a `wheelSize`-slot circle —
        // e.g. on a 19-slot wheel, positions 1 and 17 are 3 apart (through
        // 0), not 16.
        func circularDistance(_ a: Int, _ b: Int) -> Int {
            let direct = abs(a - b)
            return min(direct, wheelSize - direct)
        }

        // `max(by:)` only replaces its running result on a *strictly*
        // greater candidate (never on a tie), so ties resolve to the
        // lowest `wheelIndex` — deterministic given the same `usedIndices`.
        let farthestIndex = (0..<wheelSize).max { candidateA, candidateB in
            let distanceA = usedIndices.map { circularDistance(candidateA, $0) }.min() ?? 0
            let distanceB = usedIndices.map { circularDistance(candidateB, $0) }.min() ?? 0
            return distanceA < distanceB
        }!
        return autoAssignableCases[farthestIndex]
    }

    /// Task #157: mods against `autoAssignableCases.count` (19), not the
    /// full 20-case palette — the hash fallback must never land a new
    /// account on white (`.rose`), which is reachable only by an explicit
    /// picker tap.
    static func paletteIndex(for accountId: String) -> Int {
        Int(fnv1aHash(accountId) % UInt64(autoAssignableCases.count))
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
