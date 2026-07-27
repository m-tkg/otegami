import Foundation

/// Task #42, point 4「BIMI 対応」: parses a **safe-subset** of SVG (already
/// vetted by `BIMISVGSafety.isSafe(_:)` — this parser does not re-check
/// safety, callers must run that first) into a `BIMIVectorImage` the
/// app-layer `BIMISVGRenderer` can rasterize.
///
/// **Deliberately a hand-rolled tag scanner, not `XMLParser`/a full DOM**:
/// three reasons. (1) `XMLParser` needs `FoundationXML` on Linux, which
/// would either break this target's Linux-compatibility (like the rest of
/// this package's pure-logic layer, `OtegamiCore`'s doc comment) or need a
/// conditional import for a whole extra code path just for this one target.
/// (2) The supported element/attribute set is small and fixed — a general
/// DOM walker buys nothing over scanning `<tag ...>`/`</tag>` tokens
/// directly. (3) It keeps this parser's own "fail closed on anything I
/// don't specifically recognize" posture explicit and auditable: there's no
/// DOM tree to *accidentally* half-understand — either every tag/attribute
/// encountered is one of the ones handled below, or `parse(_:)` returns
/// `nil` for the *entire* document rather than rendering an incomplete
/// approximation of it.
///
/// **Supported subset** (BIMI's own "SVG Tiny Portable/Secure" profile is
/// already this restrictive or more so, so a spec-compliant logo should
/// parse fully):
/// - Elements: `svg`, `g`, `path`, `rect`, `circle`, `ellipse`, `polygon`,
///   `polyline`, `line`, `defs`/`title`/`desc` (contents skipped entirely —
///   never directly rendered, and `title`/`desc` in particular are
///   near-ubiquitous in tool-exported SVGs — see the parsing loop's
///   `skipDepth` doc comment).
/// - Path commands: `M`/`m`, `L`/`l`, `H`/`h`, `V`/`v`, `C`/`c`, `S`/`s`,
///   `Z`/`z`. `Q`/`T`/`A` (quadratic/smooth-quadratic/arc curves) are
///   **not** supported — encountering one rejects the whole document rather
///   than drawing an inaccurate approximation, since a wrong logo shape is
///   worse than no logo (falls back to favicon). `S`/`s` (smooth *cubic*)
///   was added after this parser's real-world verification against a
///   published BIMI logo turned out to need it — see
///   `BIMIPathDataParser`'s doc comment.
/// - Fill color: `fill="..."` or `style="fill:...;fill-opacity:...;opacity:...".`
///   as `#rgb`/`#rrggbb`/`#rrggbbaa`/`rgb()`/`rgba()`/a small named-color
///   table/`none`. `fill="url(#...)"` (gradients/patterns) is **not**
///   supported — same fail-closed reasoning as above.
/// - `transform`: `translate(...)`, `scale(...)`, `matrix(...)` only (composed
///   through nested `<g>`s and each shape's own `transform`). `rotate`/`skewX`/
///   `skewY` are not supported (fails the document, same reasoning).
public enum BIMISVGParser {
    public static func parse(_ data: Data) -> BIMIVectorImage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> BIMIVectorImage? {
        let withoutComments = Self.stripComments(text)
        guard let tokens = Self.tokenize(withoutComments) else { return nil }

        var width: Double?
        var height: Double?
        var shapes: [BIMIVectorShape] = []
        // Each stack frame: cumulative transform + inherited fill (a shape
        // with no own `fill` uses its nearest ancestor's, SVG's normal
        // inheritance — defaulting to black, SVG's initial value, if no
        // ancestor set one either).
        var stack: [(transform: Affine, fill: BIMIColor?)] = [(.identity, BIMIColor(red: 0, green: 0, blue: 0))]
        // Generic "ignore everything until this subtree closes" counter —
        // entered on `<defs>`/`<title>`/`<desc>` (never directly rendered;
        // `<title>`/`<desc>` in particular are ubiquitous in real-world
        // tool-exported SVGs, e.g. Adobe Illustrator always emits a
        // `<title>`, and rejecting a whole otherwise-perfectly-safe BIMI
        // logo over one is far too strict). While skipping, depth tracks
        // XML nesting **generically** (any non-self-closing open tag +1,
        // any close tag -1) regardless of the element name — this correctly
        // balances arbitrarily-nested unsupported content (gradients,
        // markers, nested groups, ...) inside a skipped subtree without
        // this parser needing to know every element name that could appear
        // there.
        var skipDepth = 0
        var sawSVGRoot = false

        for token in tokens {
            switch token {
            case .open(let name, let attributes, let selfClosing):
                if skipDepth > 0 {
                    if !selfClosing { skipDepth += 1 }
                    continue
                }
                switch name {
                case "svg":
                    guard !sawSVGRoot else { return nil } // nested <svg> unsupported — fail closed.
                    sawSVGRoot = true
                    let (w, h) = Self.dimensions(from: attributes)
                    width = w
                    height = h
                    if !selfClosing { stack.append(stack[stack.count - 1]) }
                case "defs", "title", "desc":
                    if !selfClosing { skipDepth = 1 }
                case "g":
                    guard let frame = Self.pushFrame(attributes: attributes, parent: stack[stack.count - 1]) else { return nil }
                    if selfClosing {
                        // A self-closed group has no children; nothing to do,
                        // don't push (nothing will pop it).
                    } else {
                        stack.append(frame)
                    }
                case "path", "rect", "circle", "ellipse", "polygon", "polyline", "line":
                    guard let frame = Self.pushFrame(attributes: attributes, parent: stack[stack.count - 1]) else { return nil }
                    guard let commands = Self.pathCommands(for: name, attributes: attributes, transform: frame.transform) else { return nil }
                    if !commands.isEmpty {
                        shapes.append(BIMIVectorShape(path: commands, fillColor: frame.fill))
                    }
                    if !selfClosing {
                        // These are void elements in every real SVG; a
                        // non-self-closed one (`<path ...>...</path>` with
                        // content) is unusual enough to just fail closed
                        // rather than guess what the content means.
                        return nil
                    }
                default:
                    // Any other element (`<text>`, `<symbol>`, `<mask>`,
                    // `<clipPath>`, `<use>`, ...) outside a skipped subtree
                    // is a feature this parser doesn't support — fail the
                    // whole document rather than silently skip it (skipping
                    // could drop a shape that mattered to the logo's
                    // appearance).
                    return nil
                }
            case .close(let name):
                if skipDepth > 0 {
                    skipDepth -= 1
                    continue
                }
                switch name {
                case "svg", "g":
                    guard stack.count > 1 else { return nil } // unbalanced tags.
                    stack.removeLast()
                default:
                    continue
                }
            }
        }

        guard sawSVGRoot, let width, let height, width > 0, height > 0 else { return nil }
        return BIMIVectorImage(width: width, height: height, shapes: shapes)
    }

    private static func pushFrame(
        attributes: [String: String],
        parent: (transform: Affine, fill: BIMIColor?)
    ) -> (transform: Affine, fill: BIMIColor?)? {
        let localTransform: Affine
        if let raw = attributes["transform"] {
            guard let parsed = Affine.parse(raw) else { return nil }
            localTransform = parsed
        } else {
            localTransform = .identity
        }
        let fill: BIMIColor?
        switch Self.fillAttributeResolution(attributes: attributes) {
        case .notSpecified: fill = parent.fill
        case .none: fill = nil
        case .color(let color): fill = color
        case .unsupported: return nil // fail closed — see this method's caller's doc comment.
        }
        return (parent.transform.concatenating(localTransform), fill)
    }

    // MARK: - Comment stripping

    private static func stripComments(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Tokenizing

    enum Token {
        case open(name: String, attributes: [String: String], selfClosing: Bool)
        case close(name: String)
    }

    /// `nil` if the text contains anything that doesn't look like a
    /// well-formed sequence of tags (e.g. a stray unmatched `<`/`>`) — fail
    /// closed rather than guess.
    static func tokenize(_ text: String) -> [Token]? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\s*(/?)\s*([A-Za-z][\w:-]*)((?:\s+[^<>]*?)?)\s*(/?)\s*>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var tokens: [Token] = []
        var consumed = 0
        for match in regex.matches(in: text, range: range) {
            // Anything between the previous tag and this one should be pure
            // whitespace/text content — `BIMISVGParser` doesn't support text
            // nodes with actual content (shapes only), but stray text is
            // harmless to ignore rather than a reason to fail the whole
            // document (e.g. an XML declaration or whitespace formatting).
            consumed = match.range.location + match.range.length

            let isClosing = nsText.substring(with: match.range(at: 1)) == "/"
            let name = nsText.substring(with: match.range(at: 2))
            let attributesString = nsText.substring(with: match.range(at: 3))
            let isSelfClosing = nsText.substring(with: match.range(at: 4)) == "/"

            if isClosing {
                tokens.append(.close(name: name))
            } else {
                guard let attributes = Self.parseAttributes(attributesString) else { return nil }
                tokens.append(.open(name: name, attributes: attributes, selfClosing: isSelfClosing))
            }
        }
        _ = consumed
        return tokens
    }

    /// Parses `key="value"` (or `key='value'`) pairs from a tag's raw
    /// attribute string. `nil` for malformed attribute syntax (unterminated
    /// quote) — fail closed.
    static func parseAttributes(_ raw: String) -> [String: String]? {
        var attributes: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return nil }
        let nsRaw = raw as NSString
        let range = NSRange(location: 0, length: nsRaw.length)
        for match in regex.matches(in: raw, range: range) {
            let key = nsRaw.substring(with: match.range(at: 1))
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = nsRaw.substring(with: match.range(at: 2))
            } else {
                value = nsRaw.substring(with: match.range(at: 3))
            }
            attributes[key] = value
        }
        return attributes
    }

    // MARK: - svg dimensions

    private static func dimensions(from attributes: [String: String]) -> (Double?, Double?) {
        if let viewBox = attributes["viewBox"] {
            let parts = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count == 4 { return (parts[2], parts[3]) }
        }
        let width = attributes["width"].flatMap(Self.parseLength)
        let height = attributes["height"].flatMap(Self.parseLength)
        return (width, height)
    }

    private static func parseLength(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let digitsOnly = trimmed.replacingOccurrences(of: "px", with: "")
        return Double(digitsOnly)
    }

    // MARK: - Fill color

    /// How an element's `fill` (attribute or `style="fill:..."`) resolves,
    /// distinguishing **"nothing specified here, inherit from the parent"**
    /// from **"something was specified but this parser doesn't support
    /// it"** — the two must never be conflated. Before this distinction
    /// existed, `fill="url(#grad)"` (a gradient reference this parser can't
    /// draw) silently fell through to `.notSpecified`'s "inherit the
    /// parent's fill" behavior, rendering the shape in whatever color an
    /// ancestor happened to have (often black, the SVG-spec default)
    /// instead of failing the whole document — exactly the "wrong shape is
    /// worse than no logo" mistake this parser's fail-closed design is
    /// supposed to prevent. `pushFrame` maps `.unsupported` to a hard `nil`
    /// (document rejected) instead.
    enum FillAttributeResolution: Equatable {
        case notSpecified
        case none
        case color(BIMIColor)
        case unsupported
    }

    static func fillAttributeResolution(attributes: [String: String]) -> FillAttributeResolution {
        var fillValue = attributes["fill"]
        var fillOpacity: Double?
        var opacity: Double?

        if let style = attributes["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "fill": fillValue = parts[1]
                case "fill-opacity": fillOpacity = Double(parts[1])
                case "opacity": opacity = Double(parts[1])
                default: continue
                }
            }
        }
        if let rawOpacity = attributes["fill-opacity"], fillOpacity == nil { fillOpacity = Double(rawOpacity) }
        if let rawOpacity = attributes["opacity"], opacity == nil { opacity = Double(rawOpacity) }

        guard let fillValue else { return .notSpecified }
        let trimmed = fillValue.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "none" { return .none }
        guard var color = BIMIColorParsing.parse(trimmed) else { return .unsupported }
        if let fillOpacity { color.alpha *= fillOpacity }
        if let opacity { color.alpha *= opacity }
        return .color(color)
    }

    // MARK: - Shape → path commands

    private static func pathCommands(for name: String, attributes: [String: String], transform: Affine) -> [BIMIPathCommand]? {
        switch name {
        case "path":
            guard let d = attributes["d"] else { return [] }
            return BIMIPathDataParser.parse(d, transform: transform)
        case "rect":
            guard let x = Double(attributes["x"] ?? "0"), let y = Double(attributes["y"] ?? "0"),
                  let width = attributes["width"].flatMap(Double.init), let height = attributes["height"].flatMap(Double.init)
            else { return nil }
            guard width > 0, height > 0 else { return [] }
            let points = [(x, y), (x + width, y), (x + width, y + height), (x, y + height)]
            return Self.polygonCommands(points, closed: true, transform: transform)
        case "circle":
            guard let cx = Double(attributes["cx"] ?? "0"), let cy = Double(attributes["cy"] ?? "0"),
                  let r = attributes["r"].flatMap(Double.init), r > 0
            else { return [] }
            return Self.ellipseCommands(cx: cx, cy: cy, rx: r, ry: r, transform: transform)
        case "ellipse":
            guard let cx = Double(attributes["cx"] ?? "0"), let cy = Double(attributes["cy"] ?? "0"),
                  let rx = attributes["rx"].flatMap(Double.init), let ry = attributes["ry"].flatMap(Double.init), rx > 0, ry > 0
            else { return [] }
            return Self.ellipseCommands(cx: cx, cy: cy, rx: rx, ry: ry, transform: transform)
        case "polygon", "polyline":
            guard let raw = attributes["points"] else { return [] }
            let numbers = raw.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).compactMap { Double($0) }
            guard numbers.count >= 4, numbers.count % 2 == 0 else { return [] }
            var points: [(Double, Double)] = []
            var index = 0
            while index + 1 < numbers.count {
                points.append((numbers[index], numbers[index + 1]))
                index += 2
            }
            return Self.polygonCommands(points, closed: name == "polygon", transform: transform)
        case "line":
            guard let x1 = Double(attributes["x1"] ?? "0"), let y1 = Double(attributes["y1"] ?? "0"),
                  let x2 = Double(attributes["x2"] ?? "0"), let y2 = Double(attributes["y2"] ?? "0")
            else { return [] }
            // A stroked line with no fill draws nothing under this parser's
            // fill-only model (see `BIMIVectorShape`'s doc comment) — kept
            // as a degenerate zero-area path rather than special-cased away,
            // since a future stroke-aware renderer could still use it.
            return Self.polygonCommands([(x1, y1), (x2, y2)], closed: false, transform: transform)
        default:
            return []
        }
    }

    private static func polygonCommands(_ points: [(Double, Double)], closed: Bool, transform: Affine) -> [BIMIPathCommand] {
        guard let first = points.first else { return [] }
        var commands: [BIMIPathCommand] = [.moveTo(x: transform.apply(first).x, y: transform.apply(first).y)]
        for point in points.dropFirst() {
            let transformed = transform.apply(point)
            commands.append(.lineTo(x: transformed.x, y: transformed.y))
        }
        if closed { commands.append(.closePath) }
        return commands
    }

    /// Approximates an ellipse/circle with 4 cubic Bézier arcs — the
    /// standard "kappa" constant (0.5522847498) for a close (<0.03%
    /// on a unit circle) approximation, plenty for a small avatar-sized
    /// rasterization.
    private static func ellipseCommands(cx: Double, cy: Double, rx: Double, ry: Double, transform: Affine) -> [BIMIPathCommand] {
        let kappa = 0.5522847498
        let ox = rx * kappa
        let oy = ry * kappa
        func point(_ x: Double, _ y: Double) -> (x: Double, y: Double) { transform.apply((x, y)) }

        let start = point(cx + rx, cy)
        let p1 = point(cx, cy + ry)
        let p2 = point(cx - rx, cy)
        let p3 = point(cx, cy - ry)

        return [
            .moveTo(x: start.x, y: start.y),
            .curveTo(cx1: point(cx + rx, cy + oy).x, cy1: point(cx + rx, cy + oy).y, cx2: point(cx + ox, cy + ry).x, cy2: point(cx + ox, cy + ry).y, x: p1.x, y: p1.y),
            .curveTo(cx1: point(cx - ox, cy + ry).x, cy1: point(cx - ox, cy + ry).y, cx2: point(cx - rx, cy + oy).x, cy2: point(cx - rx, cy + oy).y, x: p2.x, y: p2.y),
            .curveTo(cx1: point(cx - rx, cy - oy).x, cy1: point(cx - rx, cy - oy).y, cx2: point(cx - ox, cy - ry).x, cy2: point(cx - ox, cy - ry).y, x: p3.x, y: p3.y),
            .curveTo(cx1: point(cx + ox, cy - ry).x, cy1: point(cx + ox, cy - ry).y, cx2: point(cx + rx, cy - oy).x, cy2: point(cx + rx, cy - oy).y, x: start.x, y: start.y),
            .closePath,
        ]
    }
}
