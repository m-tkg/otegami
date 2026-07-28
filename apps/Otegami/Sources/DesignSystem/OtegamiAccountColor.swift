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
    /// The original 8 (`teal`/`indigo`/`plum`/`amber`/`rose`/`sage`/
    /// `slateBlue`/`coral`) keep their *exact* previous hex values —
    /// existing accounts' already-saved `labelColorKey`s (and every
    /// account still on the FNV-1a auto assignment) must not visibly
    /// change color just because the palette grew. The 12 new hues fill
    /// the gaps between them so the resulting 20-stop wheel is close to
    /// evenly spaced (see the palette-design note in `docs/design-system.md`
    /// for the exact hue/gap numbers). Saturation/value stay in the same
    /// desaturated "上品" family the original 8 established (per this
    /// enum's pre-existing doc comment) rather than jumping to the fully
    /// saturated swatches of the reference screenshot (a different app's
    /// visual style) — the goal was more *distinct hues*, not a different
    /// color language for this app.
    private static let red = Color(light: 0xA84940, dark: 0xDE8881)
    private static let coral = Color(light: 0xC97A54, dark: 0xE8A97F)
    private static let amber = Color(light: 0xB8853A, dark: 0xE3B36E)
    private static let mustard = Color(light: 0x806920, dark: 0xC7AD5A)
    private static let yellow = Color(light: 0xD1C02A, dark: 0xE6D967)
    private static let sage = Color(light: 0x6B8F4E, dark: 0xA9CB86)
    private static let green = Color(light: 0x439445, dark: 0x7ACC7D)
    private static let emerald = Color(light: 0x3C8559, dark: 0x70C291)
    private static let mint = Color(light: 0x4A947B, dark: 0x82D1B7)
    private static let teal = Color(light: 0x2F8F82, dark: 0x6FCBBE)
    private static let cyan = Color(light: 0x439BA8, dark: 0x7FCFDB)
    private static let slateBlue = Color(light: 0x4A6FA5, dark: 0x8FB3E0)
    private static let indigo = Color(light: 0x5B6EC9, dark: 0x9AA8EA)
    private static let periwinkle = Color(light: 0x6155BD, dark: 0x9D93E6)
    private static let violet = Color(light: 0x7252A3, dark: 0xAE8EDE)
    private static let plum = Color(light: 0x8A5A9E, dark: 0xC79FDB)
    private static let lavender = Color(light: 0xBC7EC2, dark: 0xE1AEE6)
    private static let magenta = Color(light: 0xA84793, dark: 0xE087CD)
    private static let pink = Color(light: 0xCC568F, dark: 0xE68EB8)
    private static let rose = Color(light: 0xC15B6E, dark: 0xE8A0AF)

    private static let palette: [Color] = [
        red, coral, amber, mustard, yellow, sage, green, emerald, mint, teal,
        cyan, slateBlue, indigo, periwinkle, violet, plum, lavender, magenta, pink, rose,
    ]

    /// D「アカウントのラベル色を変更可能に」: a named, stable identifier for
    /// each palette entry — `AccountRecord.labelColorKey` stores this
    /// enum's `rawValue` (a plain `String`, since `OtegamiStore` can't
    /// import this app-target-only module; see that property's doc
    /// comment), and `AccountCloudSync`'s snapshot carries the same raw
    /// string so a manually-picked color travels between devices exactly
    /// like every other account field `docs/icloud-sync.md` syncs.
    /// `CaseIterable`'s order matches `palette`'s (ascending hue), which is
    /// what backs `AccountEditView`'s picker grid and `wheelIndex` below.
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

        /// This case's position in the hue-ascending `allCases` order —
        /// used only for the circular hue-distance estimate in
        /// `leastUsedColorKey(avoiding:)`. Force-`!` is safe: `self` is
        /// always one of `Self.allCases` by construction.
        var wheelIndex: Int {
            Self.allCases.firstIndex(of: self)!
        }
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
        return PaletteColor.allCases[paletteIndex(for: accountId)]
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
    /// `PaletteColor.allCases.first` (red) when there are no existing
    /// accounts to avoid, so the very first account added gets a fixed,
    /// predictable color rather than whatever its id happens to hash to.
    public static func leastUsedColorKey(avoiding existingAccountColors: [PaletteColor]) -> PaletteColor {
        let usedIndices = existingAccountColors.map(\.wheelIndex)
        guard !usedIndices.isEmpty else { return PaletteColor.allCases[0] }

        let wheelSize = PaletteColor.allCases.count
        // Shortest hop between two positions on a `wheelSize`-slot circle —
        // e.g. on a 20-slot wheel, positions 1 and 18 are 3 apart (through
        // 0), not 17.
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
        return PaletteColor.allCases[farthestIndex]
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
