import Foundation

/// Parses an SVG `<path d="...">` value into `BIMIPathCommand`s, already
/// transformed by `transform` into final coordinates (see `Affine`'s doc
/// comment for why the transform is baked in here rather than carried
/// forward). Supports `M`/`m`, `L`/`l`, `H`/`h`, `V`/`v`, `C`/`c`, `S`/`s`,
/// `Z`/`z` — `Q`/`T`/`A` (in either case) make this return `nil` (failing
/// the whole document) instead of an approximation; see
/// `BIMISVGParser`'s doc comment.
///
/// **`S`/`s` (smooth cubic Bézier) is supported**, unlike `Q`/`T`/`A` —
/// added after manually verifying this parser against a real published
/// BIMI logo (PayPal's, during this batch's required one-time real-domain
/// verification step) that turned out to use `s` for one of its path
/// segments. `S`'s first control point is derived (reflected across the
/// current point from the previous curve's second control point) rather
/// than read from `d` — no approximation risk, this is exact per the SVG
/// spec, unlike the genuinely-different math `Q`/`T`/`A` would need.
enum BIMIPathDataParser {
    /// Sender-domain-controlled BIMI logo `d` values are already capped
    /// at `BIMISVGSafety.maxByteSize` (64KB) upstream, but that's a size
    /// limit on the whole SVG document, not a limit on how many commands
    /// a `d` value can decode to — cap it independently here too, purely
    /// as defense in depth (Task #168 / SEC-C, `CLAUDE-SECURITY` F7).
    private static let maxCommands = 200_000

    static func parse(_ d: String, transform: Affine) -> [BIMIPathCommand]? {
        var scanner = Scanner(d)
        var commands: [BIMIPathCommand] = []
        var current: (x: Double, y: Double) = (0, 0)
        var subpathStart: (x: Double, y: Double) = (0, 0)
        var lastCommand: Character?
        /// The absolute second control point of the immediately-preceding
        /// `C`/`c`/`S`/`s` curve, or `nil` if the previous command wasn't a
        /// cubic curve at all — per spec, `S`'s implicit first control
        /// point is the reflection of this across `current` only when the
        /// previous command was itself a cubic curve; otherwise it just
        /// equals `current` (no reflection).
        var previousCubicControl2: (x: Double, y: Double)?

        func emitMove(_ point: (x: Double, y: Double)) {
            let transformed = transform.apply(point)
            commands.append(.moveTo(x: transformed.x, y: transformed.y))
        }
        func emitLine(_ point: (x: Double, y: Double)) {
            let transformed = transform.apply(point)
            commands.append(.lineTo(x: transformed.x, y: transformed.y))
        }
        func emitCurve(_ c1: (x: Double, y: Double), _ c2: (x: Double, y: Double), _ end: (x: Double, y: Double)) {
            let t1 = transform.apply(c1)
            let t2 = transform.apply(c2)
            let te = transform.apply(end)
            commands.append(.curveTo(cx1: t1.x, cy1: t1.y, cx2: t2.x, cy2: t2.y, x: te.x, y: te.y))
        }

        while true {
            scanner.skipSeparators()
            guard !scanner.isAtEnd else { break }

            // Every iteration must consume at least one character from
            // the scanner. Without this guard, `Z`/`z` (the only command
            // that reads no arguments) could be implicitly repeated
            // forever when the character right after it is neither a
            // separator nor a command letter — e.g. `d="M0 0Z0"` — since
            // nothing about that repetition path advances `scanner`
            // (Task #168 / SEC-C, `CLAUDE-SECURITY` F7: this used to be
            // an unbounded `while true` with `commands` growing without
            // limit, hanging the calling actor and eventually OOMing).
            let iterationStartIndex = scanner.currentIndex

            let command: Character
            if let letter = scanner.peekLetter() {
                command = letter
                scanner.advanceOne()
            } else if let last = lastCommand {
                // Implicit repetition of the previous command for
                // additional coordinate groups (standard SVG path syntax,
                // e.g. "M0,0 10,10 20,20" — the second/third pairs are
                // implicit lineto). A repeated `M`/`m` becomes implicit
                // `L`/`l` per spec.
                //
                // `Z`/`z` (closepath) takes no parameters per the SVG
                // spec, so there is nothing valid to implicitly repeat —
                // a bare token right after a `Z`/`z` that isn't itself a
                // new command letter is malformed; fail closed rather
                // than loop.
                guard last != "Z", last != "z" else { return nil }
                command = (last == "M") ? "L" : (last == "m") ? "l" : last
            } else {
                return nil // numbers with no command at all — malformed.
            }

            switch command {
            case "M", "m":
                guard let (x, y) = scanner.readPoint() else { return nil }
                current = (command == "m") ? (current.x + x, current.y + y) : (x, y)
                subpathStart = current
                emitMove(current)
            case "L", "l":
                guard let (x, y) = scanner.readPoint() else { return nil }
                current = (command == "l") ? (current.x + x, current.y + y) : (x, y)
                emitLine(current)
            case "H", "h":
                guard let x = scanner.readNumber() else { return nil }
                current = (command == "h") ? (current.x + x, current.y) : (x, current.y)
                emitLine(current)
            case "V", "v":
                guard let y = scanner.readNumber() else { return nil }
                current = (command == "v") ? (current.x, current.y + y) : (current.x, y)
                emitLine(current)
            case "C", "c":
                guard let p1 = scanner.readPoint(), let p2 = scanner.readPoint(), let end = scanner.readPoint() else { return nil }
                let c1 = (command == "c") ? (current.x + p1.0, current.y + p1.1) : p1
                let c2 = (command == "c") ? (current.x + p2.0, current.y + p2.1) : p2
                let e = (command == "c") ? (current.x + end.0, current.y + end.1) : end
                emitCurve(c1, c2, e)
                current = e
                previousCubicControl2 = c2
            case "S", "s":
                guard let p2 = scanner.readPoint(), let end = scanner.readPoint() else { return nil }
                let c2 = (command == "s") ? (current.x + p2.0, current.y + p2.1) : p2
                let e = (command == "s") ? (current.x + end.0, current.y + end.1) : end
                let c1: (Double, Double)
                if let reflected = previousCubicControl2 {
                    c1 = (2 * current.x - reflected.x, 2 * current.y - reflected.y)
                } else {
                    c1 = current
                }
                emitCurve(c1, c2, e)
                current = e
                previousCubicControl2 = c2
            case "Z", "z":
                commands.append(.closePath)
                current = subpathStart
            default:
                return nil
            }
            if command != "C", command != "c", command != "S", command != "s" {
                previousCubicControl2 = nil
            }
            lastCommand = command

            guard scanner.currentIndex > iterationStartIndex else { return nil } // no progress — fail closed rather than loop.
            guard commands.count <= maxCommands else { return nil } // defense in depth; see maxCommands's doc comment.
        }
        return commands
    }

    /// A minimal SVG path-data number scanner — handles the syntax's
    /// permissive number packing (no separator required between numbers
    /// when a sign or `.` disambiguates them, e.g. `"1-1"` == `"1,-1"` and
    /// `"1.5.5"` == `"1.5,0.5"`), which real-world (especially tool-exported)
    /// path data relies on routinely.
    private struct Scanner {
        private let characters: [Character]
        private var index = 0

        init(_ string: String) {
            characters = Array(string)
        }

        var isAtEnd: Bool { index >= characters.count }

        /// Exposed only so the caller can assert that each loop
        /// iteration consumed at least one character (Task #168 / SEC-C
        /// fix for F7 — see `parse`'s per-iteration progress guard).
        var currentIndex: Int { index }

        mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "," || characters[index] == "\n" || characters[index] == "\t" || characters[index] == "\r" {
                index += 1
            }
        }

        func peekLetter() -> Character? {
            guard index < characters.count, characters[index].isLetter else { return nil }
            return characters[index]
        }

        mutating func advanceOne() {
            index += 1
        }

        mutating func readNumber() -> Double? {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            var sawDigitOrDot = false
            var sawDot = false
            while index < characters.count {
                let ch = characters[index]
                if ch.isNumber {
                    sawDigitOrDot = true
                    index += 1
                } else if ch == "." && !sawDot {
                    sawDot = true
                    sawDigitOrDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigitOrDot else { index = start; return nil }
            // Optional exponent, e.g. "1e-3".
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                let expStart = index
                var lookahead = index + 1
                if lookahead < characters.count, characters[lookahead] == "+" || characters[lookahead] == "-" { lookahead += 1 }
                var sawExpDigit = false
                while lookahead < characters.count, characters[lookahead].isNumber {
                    sawExpDigit = true
                    lookahead += 1
                }
                if sawExpDigit { index = lookahead } else { index = expStart }
            }
            let substring = String(characters[start..<index])
            return Double(substring)
        }

        mutating func readPoint() -> (Double, Double)? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return (x, y)
        }
    }
}
