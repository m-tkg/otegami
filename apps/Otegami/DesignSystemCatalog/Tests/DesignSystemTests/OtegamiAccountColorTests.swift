import Testing
@testable import DesignSystem

/// Task #72「自動割当の改善」: `OtegamiAccountColor.leastUsedColorKey(avoiding:)`
/// picks the palette entry whose circular hue-wheel distance to its
/// *nearest* used entry is largest. See `docs/design-system.md`'s "Task #72"
/// section for why this test lives in this standalone package rather than
/// `packages/OtegamiKit` or an app-target Xcode test target.
struct OtegamiAccountColorTests {
    private typealias PaletteColor = OtegamiAccountColor.PaletteColor

    @Test("No existing accounts: falls back to the first palette entry (red)")
    func noExistingAccounts() {
        #expect(OtegamiAccountColor.leastUsedColorKey(avoiding: []) == .red)
    }

    @Test("One existing account: picks the color on the opposite side of the wheel")
    func oneExistingAccount() {
        // `.red` is wheelIndex 0 on a 20-entry wheel; the farthest point is
        // 10 slots away. `.allCases` is declared in hue order, so index 10
        // is whatever the 11th case is — resolve it the same way production
        // code does rather than hardcoding a name that'd silently go stale
        // if the palette were reordered.
        let expected = PaletteColor.allCases[10]
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
        // Every color used except one — the picker must return that one
        // unused color, no matter how many times the others repeat.
        let allButLast = Array(PaletteColor.allCases.dropLast())
        let saturating = allButLast + allButLast // each used twice
        #expect(OtegamiAccountColor.leastUsedColorKey(avoiding: saturating) == PaletteColor.allCases.last)
    }
}
