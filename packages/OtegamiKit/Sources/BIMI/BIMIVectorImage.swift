import Foundation

/// Task #42, point 4「BIMI 対応」: a pure, `CoreGraphics`-free model of "the
/// small subset of SVG this app knows how to draw", produced by
/// `BIMISVGParser` and consumed by the app-layer `BIMISVGRenderer`
/// (`apps/Otegami/Sources/Support/`). Kept Apple-independent (like the rest
/// of this target) purely so the parsing logic — the part with actual
/// decisions to get right or wrong (arc/curve math, attribute parsing,
/// color parsing) — stays unit-testable via `make test` without an
/// iOS/macOS Simulator or a `CGContext`.
public struct BIMIVectorImage: Sendable, Equatable {
    /// The SVG's `viewBox` width/height (or, absent a `viewBox`, its
    /// `width`/`height` attributes) — the coordinate space every
    /// `BIMIPathCommand` point is expressed in. The renderer scales this
    /// rectangle to whatever pixel size it wants to rasterize at.
    public var width: Double
    public var height: Double
    public var shapes: [BIMIVectorShape]

    public init(width: Double, height: Double, shapes: [BIMIVectorShape]) {
        self.width = width
        self.height = height
        self.shapes = shapes
    }
}

/// One filled shape: a path (already flattened from whichever source
/// element — `<path>`, `<rect>`, `<circle>`, `<ellipse>`, `<polygon>`,
/// `<polyline>`, `<line>` — it came from) plus a solid fill color.
/// **Stroke is not modeled at all** — deliberately out of scope for this
/// batch's effort/fidelity trade-off (see `BIMISVGParser`'s doc comment);
/// a BIMI logo that relies on strokes for its shape renders incompletely
/// (missing outlines) rather than not at all, which was judged an
/// acceptable degradation for a small avatar-sized mark.
public struct BIMIVectorShape: Sendable, Equatable {
    public var path: [BIMIPathCommand]
    /// `nil` means "no fill" (`fill="none"`, or an unrecognized paint server
    /// like a gradient/pattern reference — `BIMISVGParser` rejects the whole
    /// document rather than silently dropping just the fill in that case;
    /// see that type's doc comment) — a shape with `nil` fill is never
    /// actually produced by the parser today, but the renderer still
    /// handles it (skips drawing) for forward-compatibility with a future
    /// parser change that *does* preserve fill-less shapes.
    public var fillColor: BIMIColor?

    public init(path: [BIMIPathCommand], fillColor: BIMIColor?) {
        self.path = path
        self.fillColor = fillColor
    }
}

/// Every point is already in absolute user-space coordinates (any
/// relative/absolute SVG path-command distinction is resolved during
/// parsing, not preserved here) — the renderer never needs to track "current
/// point" itself.
public enum BIMIPathCommand: Sendable, Equatable {
    case moveTo(x: Double, y: Double)
    case lineTo(x: Double, y: Double)
    /// Cubic Bézier — SVG's `C`/`c` command (`S`/`s`, the smooth/reflected
    /// variant, is also supported and reduces to this same case — see
    /// `BIMIPathDataParser`'s doc comment). `Q`/`T`/`A` are not supported;
    /// see `BIMISVGParser`'s doc comment for why encountering one rejects
    /// the whole document instead of approximating it.
    case curveTo(cx1: Double, cy1: Double, cx2: Double, cy2: Double, x: Double, y: Double)
    case closePath
}

public struct BIMIColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
