// Renders `DesignSystemCatalogView` off-screen (via SwiftUI's
// `ImageRenderer`, macOS-hosted) to PNG files in both light and dark
// mode, so the design system's tokens/components can actually be *looked
// at* without needing to build the Otegami app, boot an iOS Simulator, or
// touch any existing file in `apps/Otegami/` (this whole package sits
// outside `project.yml`'s source globs — see `Package.swift`'s doc
// comment).
//
// This was the fallback the design-system task itself sanctioned when a
// simulator launch-argument hook isn't possible without editing
// `OtegamiApp.swift` (an existing file, off-limits while a parallel
// session works elsewhere in this repo): "カタログ専用の小さな SwiftPM
// 実行ターゲットを作る". `Color(light:dark:)`
// (`DesignSystem/DynamicColor.swift`) resolves correctly under
// `ImageRenderer` purely from the rendered view's `\.colorScheme`
// environment value — verified directly before committing to this
// approach (a light-vs-dark test render produced (255,255,255) vs.
// (0,0,0) pixels as expected) — so no `NSApplication`/window/simulator is
// needed at all.
//
// Usage: `swift run DesignSystemCatalogRenderer [output-directory]`
// (defaults to `/tmp/otegami-verify`). Writes `design-light.png` and
// `design-dark.png`.

import AppKit
import CoreText
import DesignSystem
import SwiftUI

@MainActor
enum CatalogRenderer {
    static func run() {
        registerArchivo()
        let outputDirectory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/tmp/otegami-verify"
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true
        )
        render(scheme: .light, to: "\(outputDirectory)/design-light.png")
        render(scheme: .dark, to: "\(outputDirectory)/design-dark.png")
    }

    /// This tool isn't an app bundle, so `OtegamiFont.registerCustomFontsIfNeeded()`
    /// (which looks the font up in `Bundle.main`) doesn't apply here —
    /// instead, register the exact same on-disk font file directly, found
    /// relative to this very source file via `#filePath` so this doesn't
    /// depend on the current working directory `swift run` happens to be
    /// invoked from.
    private static func registerArchivo() {
        let thisFile = URL(fileURLWithPath: #filePath)
        // .../DesignSystemCatalog/Sources/DesignSystemCatalogRenderer/main.swift
        //   -> .../DesignSystemCatalog -> .../apps/Otegami
        let otegamiDirectory = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontURL = otegamiDirectory
            .appendingPathComponent("Resources/Fonts/Archivo/Archivo-Variable.ttf")
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) else {
            print("warning: could not register \(fontURL.path): \(String(describing: error))")
            return
        }
    }

    private static func render(scheme: ColorScheme, to path: String) {
        // Renders `DesignSystemCatalogContent` directly, not
        // `DesignSystemCatalogView` — `ImageRenderer` can't capture a
        // `ScrollView`'s interior correctly (see that type's doc
        // comment), so this applies the same background by hand instead
        // of going through the `ScrollView`-wrapping view.
        // Liquid Glass Phase 5 (docs/design-system.md「Liquid Glass 方針」):
        // `OtegamiColor.background` was removed once every real call site
        // migrated away. `.background(.background)` replaces it here (same
        // as `DesignSystemCatalogView`'s own change) — needed to keep this
        // offscreen render opaque per color scheme; without it `ImageRenderer`
        // exports a transparent PNG, which defeats the light-vs-dark
        // comparison this renderer exists to produce.
        let view = DesignSystemCatalogContent()
            .frame(width: 420)
            .background(.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = .init(width: 420, height: nil)
        renderer.scale = 2
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("error: failed to render \(scheme)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(nsImage.size.width))x\(Int(nsImage.size.height)))")
        } catch {
            print("error: could not write \(path): \(error)")
        }
    }
}

CatalogRenderer.run()
