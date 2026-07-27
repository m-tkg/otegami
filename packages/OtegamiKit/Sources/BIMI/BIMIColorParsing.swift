import Foundation

/// Parses the small subset of CSS/SVG color syntax `BIMISVGParser` supports
/// for `fill`/`style="fill:..."` values: hex (`#rgb`/`#rrggbb`/`#rrggbbaa`),
/// `rgb()`/`rgba()`, a fixed table of common named colors, and `none`.
/// **Does not support** `url(#...)` (gradient/pattern references) or `hsl()`
/// — either causes the whole document to fail parsing (`BIMISVGParser`'s
/// fail-closed posture), not a fallback color.
enum BIMIColorParsing {
    static func parse(_ raw: String) -> BIMIColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased() != "none" else { return nil }

        if trimmed.hasPrefix("#") {
            return parseHex(trimmed)
        }
        if trimmed.lowercased().hasPrefix("rgba(") || trimmed.lowercased().hasPrefix("rgb(") {
            return parseFunctional(trimmed)
        }
        if trimmed.lowercased().hasPrefix("url(") {
            // Gradient/pattern reference — unsupported, causes the caller
            // (`BIMISVGParser.fillColor`) to return `nil`, which
            // `BIMISVGParser.parse` treats as "fail the whole document"
            // wherever a fill is actually required.
            return nil
        }
        return namedColors[trimmed.lowercased()]
    }

    private static func parseHex(_ raw: String) -> BIMIColor? {
        let hex = String(raw.dropFirst())
        func component(_ substring: Substring) -> Double? {
            guard let value = UInt8(substring, radix: 16) else { return nil }
            return Double(value) / 255
        }
        switch hex.count {
        case 3:
            let chars = Array(hex)
            guard let r = component(Substring(String(repeating: chars[0], count: 2))),
                  let g = component(Substring(String(repeating: chars[1], count: 2))),
                  let b = component(Substring(String(repeating: chars[2], count: 2)))
            else { return nil }
            return BIMIColor(red: r, green: g, blue: b)
        case 6:
            guard let r = component(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2)]),
                  let g = component(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)]),
                  let b = component(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)])
            else { return nil }
            return BIMIColor(red: r, green: g, blue: b)
        case 8:
            guard let r = component(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2)]),
                  let g = component(hex[hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4)]),
                  let b = component(hex[hex.index(hex.startIndex, offsetBy: 4)..<hex.index(hex.startIndex, offsetBy: 6)]),
                  let a = component(hex[hex.index(hex.startIndex, offsetBy: 6)..<hex.index(hex.startIndex, offsetBy: 8)])
            else { return nil }
            return BIMIColor(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    private static func parseFunctional(_ raw: String) -> BIMIColor? {
        guard let openParen = raw.firstIndex(of: "("), let closeParen = raw.lastIndex(of: ")") else { return nil }
        let inner = raw[raw.index(after: openParen)..<closeParen]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        guard let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        let alpha = parts.count == 4 ? Double(parts[3]) ?? 1 : 1
        return BIMIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }

    private static let namedColors: [String: BIMIColor] = [
        "black": BIMIColor(red: 0, green: 0, blue: 0),
        "white": BIMIColor(red: 1, green: 1, blue: 1),
        "red": BIMIColor(red: 1, green: 0, blue: 0),
        "green": BIMIColor(red: 0, green: 128.0 / 255, blue: 0),
        "blue": BIMIColor(red: 0, green: 0, blue: 1),
        "yellow": BIMIColor(red: 1, green: 1, blue: 0),
        "orange": BIMIColor(red: 1, green: 165.0 / 255, blue: 0),
        "purple": BIMIColor(red: 128.0 / 255, green: 0, blue: 128.0 / 255),
        "gray": BIMIColor(red: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255),
        "grey": BIMIColor(red: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255),
        "silver": BIMIColor(red: 192.0 / 255, green: 192.0 / 255, blue: 192.0 / 255),
        "navy": BIMIColor(red: 0, green: 0, blue: 128.0 / 255),
        "teal": BIMIColor(red: 0, green: 128.0 / 255, blue: 128.0 / 255),
        "transparent": BIMIColor(red: 0, green: 0, blue: 0, alpha: 0),
    ]
}
