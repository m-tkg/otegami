import CoreGraphics
import Foundation
import ImageIO
import BIMI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Task #42, point 4「BIMI 対応」: rasterizes a `BIMIVectorImage`
/// (`BIMISVGParser`'s pure output, `packages/OtegamiKit/Sources/BIMI/`) into
/// PNG bytes via `CoreGraphics`+`ImageIO` — the one part of BIMI support
/// that's genuinely Apple-only, kept in the app layer for exactly that
/// reason (see `BIMIRecordResolver.swift`'s doc comment). `CoreGraphics`/
/// `ImageIO` are identical on iOS and macOS, so unlike
/// `CompanyLogoAvatarResolver.isDecodableImage` (which has to branch on
/// `UIImage`/`NSImage`), this renderer has no `#if os(...)` at all.
enum BIMISVGRenderer {
    /// Renders into a square `pixelSize × pixelSize` canvas, letterboxing
    /// (uniform scale, centered) if the source's aspect ratio isn't square
    /// — matches how `SenderAvatar` displays every other avatar source (a
    /// circular crop of a square image).
    static func render(_ image: BIMIVectorImage, pixelSize: Int) -> Data? {
        guard pixelSize > 0, image.width > 0, image.height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background — an avatar-sized rasterization of a logo that
        // relies on transparency (many do, for non-square marks) looks
        // wrong composited onto whatever's behind it otherwise; white
        // matches the card/list background this avatar is drawn on in
        // practice (`SenderAvatar`'s own background).
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        let scale = min(Double(pixelSize) / image.width, Double(pixelSize) / image.height)
        let offsetX = (Double(pixelSize) - image.width * scale) / 2
        let offsetY = (Double(pixelSize) - image.height * scale) / 2

        // SVG's y-axis points down; `CGContext`'s default (unflipped) space
        // has y pointing up from the bottom-left. Flipping here (rather than
        // negating every parsed y-coordinate back in `BIMISVGParser`, which
        // has no concept of a target canvas at all) keeps the parser's
        // coordinate space simply "whatever the SVG's own viewBox says."
        context.translateBy(x: offsetX, y: Double(pixelSize) - offsetY)
        context.scaleBy(x: scale, y: -scale)

        for shape in image.shapes {
            guard let fillColor = shape.fillColor, fillColor.alpha > 0 else { continue }
            guard let path = Self.cgPath(for: shape.path) else { continue }
            context.setFillColor(CGColor(red: fillColor.red, green: fillColor.green, blue: fillColor.blue, alpha: fillColor.alpha))
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }

        guard let cgImage = context.makeImage() else { return nil }
        return Self.pngData(from: cgImage)
    }

    private static func cgPath(for commands: [BIMIPathCommand]) -> CGPath? {
        guard !commands.isEmpty else { return nil }
        let path = CGMutablePath()
        for command in commands {
            switch command {
            case .moveTo(let x, let y):
                path.move(to: CGPoint(x: x, y: y))
            case .lineTo(let x, let y):
                path.addLine(to: CGPoint(x: x, y: y))
            case .curveTo(let cx1, let cy1, let cx2, let cy2, let x, let y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: cx1, y: cy1), control2: CGPoint(x: cx2, y: cy2))
            case .closePath:
                path.closeSubpath()
            }
        }
        return path
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
