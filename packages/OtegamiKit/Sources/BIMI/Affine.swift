import Foundation

/// A 2D affine transform (`[a c e; b d f]`, SVG's own matrix convention),
/// used by `BIMISVGParser` to flatten `transform="..."` attributes (composed
/// through nested `<g>` ancestors) into absolute coordinates at parse time —
/// see `BIMIVectorImage`'s doc comment for why the renderer never needs to
/// deal with transforms itself.
struct Affine: Sendable, Equatable {
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var e: Double
    var f: Double

    static let identity = Affine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    func apply(_ point: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (a * point.x + c * point.y + e, b * point.x + d * point.y + f)
    }

    /// `self` applied first, then `other` — i.e. `other` is the new
    /// (child's own) transform being composed on top of `self` (the
    /// already-accumulated parent transform), matching SVG's "child
    /// transforms are relative to parent" nesting order.
    func concatenating(_ other: Affine) -> Affine {
        Affine(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            e: a * other.e + c * other.f + e,
            f: b * other.e + d * other.f + f
        )
    }

    /// Parses a `transform` attribute value containing one or more
    /// space-separated `translate(...)`/`scale(...)`/`matrix(...)` function
    /// calls, composed left-to-right. `nil` for anything containing a
    /// different function (`rotate`/`skewX`/`skewY`) or malformed syntax —
    /// `BIMISVGParser` fails the whole document on `nil`, per this target's
    /// documented fail-closed posture rather than approximate an
    /// unsupported transform as identity.
    static func parse(_ raw: String) -> Affine? {
        guard let regex = try? NSRegularExpression(pattern: #"(translate|scale|matrix)\s*\(([^)]*)\)"#) else { return nil }
        let nsRaw = raw as NSString
        let range = NSRange(location: 0, length: nsRaw.length)
        let matches = regex.matches(in: raw, range: range)
        guard !matches.isEmpty else { return nil }

        // Reject any characters outside the matched function calls that
        // aren't whitespace or commas — catches an unsupported function
        // name (rotate/skewX/skewY) that the pattern above simply didn't
        // match, which would otherwise be silently ignored.
        var consumedRanges = matches.map(\.range)
        let fullyConsumed = Self.rangesCoverEveryNonWhitespaceCharacter(text: raw, ranges: &consumedRanges)
        guard fullyConsumed else { return nil }

        var result = Affine.identity
        for match in matches {
            let function = nsRaw.substring(with: match.range(at: 1))
            let argsString = nsRaw.substring(with: match.range(at: 2))
            let args = argsString.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            let transform: Affine
            switch function {
            case "translate":
                guard args.count == 1 || args.count == 2 else { return nil }
                transform = Affine(a: 1, b: 0, c: 0, d: 1, e: args[0], f: args.count == 2 ? args[1] : 0)
            case "scale":
                guard args.count == 1 || args.count == 2 else { return nil }
                transform = Affine(a: args[0], b: 0, c: 0, d: args.count == 2 ? args[1] : args[0], e: 0, f: 0)
            case "matrix":
                guard args.count == 6 else { return nil }
                transform = Affine(a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5])
            default:
                return nil
            }
            result = result.concatenating(transform)
        }
        return result
    }

    private static func rangesCoverEveryNonWhitespaceCharacter(text: String, ranges: inout [NSRange]) -> Bool {
        let nsText = text as NSString
        ranges.sort { $0.location < $1.location }
        var cursor = 0
        for range in ranges {
            guard range.location >= cursor else { return false } // overlapping matches, shouldn't happen.
            let gap = nsText.substring(with: NSRange(location: cursor, length: range.location - cursor))
            if !gap.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            cursor = range.location + range.length
        }
        let trailing = nsText.substring(from: cursor)
        return trailing.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
