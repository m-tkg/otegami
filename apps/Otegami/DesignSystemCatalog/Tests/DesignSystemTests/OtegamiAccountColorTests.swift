import Testing
@testable import DesignSystem

/// Task #72「自動割当の改善」: `OtegamiAccountColor.leastUsedColorKey(avoiding:)`
/// picks the palette entry whose circular hue-wheel distance to its
/// *nearest* used entry is largest. See `docs/design-system.md`'s "Task #72"
/// section for why this test lives in this standalone package rather than
/// `packages/OtegamiKit` or an app-target Xcode test target.
///
/// Task #157 (実機フィードバック): the palette's last stop (`.rose`) now
/// resolves to white instead of a hue, and white must never be handed out
/// automatically — only picked explicitly. `autoAssignableColors` below is
/// every case *except* `.rose`, matching production's own exclusion
/// (`OtegamiAccountColor.autoAssignableCases`, not exposed outside the
/// module, so the tests rebuild the same 19-entry set from `allCases`).
struct OtegamiAccountColorTests {
    private typealias PaletteColor = OtegamiAccountColor.PaletteColor

    /// Every case eligible for automatic assignment — all of `allCases`
    /// except `.rose` (white), which sits last in declaration order.
    private static var autoAssignableColors: [PaletteColor] {
        Array(PaletteColor.allCases.dropLast())
    }

    @Test("No existing accounts: falls back to the first palette entry (red)")
    func noExistingAccounts() {
        #expect(OtegamiAccountColor.leastUsedColorKey(avoiding: []) == .red)
    }

    @Test("One existing account: picks the color on the opposite side of the 19-hue wheel")
    func oneExistingAccount() {
        // `.red` is wheelIndex 0 on the 19-entry auto-assignable wheel
        // (white excluded); the farthest point on an odd-sized circle is
        // floor(19/2) = 9 slots away, ties resolving to the lower index.
        let expected = Self.autoAssignableColors[9]
        #expect(OtegamiAccountColor.leastUsedColorKey(avoiding: [.red]) == expected)
    }

    @Test("Never repeats a color that's already in heavy use")
    func avoidsAllUsedColors() {
        // Three accounts clustered at the start of the wheel (the exact
        // real-device complaint this feature fixes: several accounts all
        // landing on the same handful of colors). The farthest choice must
        // not be any of them.
        let used: [PaletteColor] = [.red, .coral, .amber]
        let picked = OtegamiAccountColor.leastUsedColorKey(avoiding: used)
        #expect(!used.contains(picked))
    }

    @Test("Deterministic: the same used set always yields the same pick")
    func deterministic() {
        let used: [PaletteColor] = [.teal, .indigo, .plum]
        let first = OtegamiAccountColor.leastUsedColorKey(avoiding: used)
        let second = OtegamiAccountColor.leastUsedColorKey(avoiding: used)
        #expect(first == second)
    }

    @Test("A color already used twice doesn't get picked a third time before an unused one")
    func prefersUnusedOverRepeated() {
        // Every auto-assignable color used except one — the picker must
        // return that one unused color, no matter how many times the
        // others repeat. Deliberately built from `autoAssignableColors`
        // (19 hues), not `PaletteColor.allCases` (20) — with `.rose`/white
        // excluded from the pool entirely, "all but the last one" here
        // means all but the last *hue*, not all but white.
        let allButLast = Array(Self.autoAssignableColors.dropLast())
        let saturating = allButLast + allButLast // each used twice
        #expect(OtegamiAccountColor.leastUsedColorKey(avoiding: saturating) == Self.autoAssignableColors.last)
    }

    @Test("Never auto-assigns white (.rose), even when every hue is already saturated")
    func neverReturnsWhite() {
        // Every auto-assignable hue used twice over, with no unused hue
        // left at all — the old (pre-Task #157) algorithm would have had
        // nothing left to prefer and could only fall back to whatever
        // came next in `allCases`, which is `.rose`. The white-exclusion
        // must hold regardless: the result is some already-used hue, never
        // white.
        let saturating = Self.autoAssignableColors + Self.autoAssignableColors
        let picked = OtegamiAccountColor.leastUsedColorKey(avoiding: saturating)
        #expect(picked != .rose)
    }

    @Test("An existing account manually painted white doesn't skew hue-distance math")
    func existingWhiteDoesNotAffectDistance() {
        // `.rose` (white) has no position on the hue wheel, so including it
        // in `existingAccountColors` (as if some other account picked white
        // explicitly) must be a no-op for the distance calculation — same
        // result as if that account were omitted entirely.
        let withoutWhite = OtegamiAccountColor.leastUsedColorKey(avoiding: [.red])
        let withWhite = OtegamiAccountColor.leastUsedColorKey(avoiding: [.red, .rose])
        #expect(withoutWhite == withWhite)
    }

    @Test("The FNV-1a hash fallback never assigns white to a brand-new account")
    func hashFallbackNeverAssignsWhite() {
        // `resolvedPaletteColor(for:override:)` with no override exercises
        // the hash fallback directly; white must be unreachable through it
        // for any account id.
        let sampleIds = ["a@example.com", "b@example.com", "someone@otegami.test", "", "z"]
        for id in sampleIds {
            #expect(OtegamiAccountColor.resolvedPaletteColor(for: id) != .rose)
        }
    }
}
