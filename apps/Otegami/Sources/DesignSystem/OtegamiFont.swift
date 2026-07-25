import SwiftUI

#if canImport(CoreText)
import CoreText
#endif

/// Typography tokens. English/Latin text uses Archivo (bundled under
/// `Resources/Fonts/Archivo/`, SIL Open Font License — see that folder's
/// `OFL.txt` and this repo's `NOTICE`); Japanese and any other script
/// Archivo doesn't cover falls back to the system font automatically via
/// normal CoreText font-cascade behavior — nothing here has to branch on
/// script, `Font.custom("ArchivoRoman-Regular", ...)` just works for mixed
/// Japanese/English strings out of the box.
///
/// Every case below goes through `Font.custom(_:size:relativeTo:)`, so
/// sizes scale with Dynamic Type rather than staying fixed — per the plan,
/// nothing in this design system should use a bare fixed-pt `Font.system`.
public enum OtegamiFont {
    /// Screen-level titles ("すべての受信").
    public static func largeTitle() -> Font { archivo(.bold, size: 28, relativeTo: .largeTitle) }
    /// Section/sheet titles.
    public static func title() -> Font { archivo(.semibold, size: 22, relativeTo: .title) }
    /// Row headline weight (sender name, subject line).
    public static func headline() -> Font { archivo(.semibold, size: 17, relativeTo: .headline) }
    /// Default body copy (message preview text, paragraph text).
    public static func body() -> Font { archivo(.regular, size: 16, relativeTo: .body) }
    /// Secondary row text (timestamps, account labels).
    public static func subheadline() -> Font { archivo(.medium, size: 14, relativeTo: .subheadline) }
    /// Small metadata text (chip labels, section headers).
    public static func caption() -> Font { archivo(.medium, size: 12, relativeTo: .caption) }
    /// Smallest text — badges ("EN"), tap-target-adjacent labels.
    public static func badge() -> Font { archivo(.semibold, size: 11, relativeTo: .caption2) }

    /// Archivo's weight axis, as the variable font's named instances
    /// (confirmed via `ttx -t fvar` against the Google Fonts source: each
    /// of these has its own queryable PostScript name — e.g.
    /// `ArchivoRoman-SemiBold` — once the variable font file is
    /// registered with CoreText, same as any static-weight font would).
    public enum Weight: String {
        case regular = "ArchivoRoman-Regular"
        case medium = "ArchivoRoman-Medium"
        case semibold = "ArchivoRoman-SemiBold"
        case bold = "ArchivoRoman-Bold"
    }

    private static func archivo(_ weight: Weight, size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: textStyle)
    }

    // MARK: - Registration

    /// Registers the bundled Archivo variable font with CoreText so
    /// `Font.custom("ArchivoRoman-...", ...)` above can actually resolve
    /// it. Idempotent and safe to call more than once (CoreText just
    /// reports "already registered" on repeat calls, which this treats as
    /// success, not an error).
    ///
    /// Called once from `AppEnvironment.init()` (the design-phase-2 UI
    /// restructuring pass) — `docs/design-system.md`'s earlier "次フェーズへ
    /// の申し送り" note is resolved. Until that wiring landed, `Font.custom`
    /// calls above silently fell back to the system font rather than
    /// crashing (standard SwiftUI behavior for an unresolved font name), so
    /// nothing here was ever unsafe to ship in the meantime. The debug
    /// catalog (`Catalog/DesignSystemCatalogView.swift`) and the
    /// screenshot renderer (`DesignSystemCatalog/`) also call this
    /// themselves (independently of `AppEnvironment`, since neither runs
    /// the real app target) so they can verify the *actual* Archivo
    /// glyphs, not the fallback.
    @MainActor
    public static func registerCustomFontsIfNeeded() {
        guard !hasRegistered else { return }
        hasRegistered = true
        for url in candidateFontURLs() {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Ignore "already registered" (duplicatedName) — everything
            // else is silently best-effort too, matching the fallback
            // behavior described above: a failed registration just means
            // `Font.custom` keeps using the system font.
        }
    }

    nonisolated(unsafe) private static var hasRegistered = false

    /// Bundle layout for loose (non-asset-catalog) resources isn't
    /// guaranteed to preserve source subdirectories once xcodegen/Xcode
    /// copies them into the app bundle, so this tries a few plausible
    /// locations rather than assuming one. Internal — the standalone
    /// catalog renderer (which isn't an app bundle at all) does its own
    /// direct file lookup instead of calling this.
    private static func candidateFontURLs() -> [URL] {
        let name = "Archivo-Variable"
        let ext = "ttf"
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            urls.append(url)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts/Archivo") {
            urls.append(url)
        }
        if urls.isEmpty, let resourcePath = Bundle.main.resourcePath {
            // Last resort: walk the bundle looking for the file by name,
            // in case the folder structure was preserved as a blue
            // "folder reference" under some other path than the two
            // guesses above.
            let enumerator = FileManager.default.enumerator(atPath: resourcePath)
            while let relativePath = enumerator?.nextObject() as? String {
                if relativePath.hasSuffix("\(name).\(ext)") {
                    urls.append(URL(fileURLWithPath: resourcePath).appendingPathComponent(relativePath))
                    break
                }
            }
        }
        return urls
    }
}
