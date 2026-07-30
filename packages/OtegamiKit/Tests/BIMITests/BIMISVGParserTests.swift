import Foundation
import Testing
@testable import BIMI

@Suite("BIMISVGParser")
struct BIMISVGParserTests {
    @Test
    func parseReadsViewBoxDimensions() throws {
        let svg = "<svg viewBox=\"0 0 120 80\"><path d=\"M0 0 L10 0 L10 10 Z\" fill=\"#ff0000\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.width == 120)
        #expect(image.height == 80)
    }

    @Test
    func parseFallsBackToWidthHeightAttributesWithoutAViewBox() throws {
        let svg = "<svg width=\"64\" height=\"64\"><path d=\"M0 0Z\" fill=\"#000\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.width == 64)
        #expect(image.height == 64)
    }

    @Test
    func parseBuildsAPathShapeWithItsFillColor() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 L10 0 L10 10 L0 10 Z\" fill=\"#336699\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.count == 1)
        let shape = try #require(image.shapes.first)
        #expect(shape.fillColor == BIMIColor(red: Double(0x33) / 255, green: Double(0x66) / 255, blue: Double(0x99) / 255))
        #expect(shape.path == [
            .moveTo(x: 0, y: 0),
            .lineTo(x: 10, y: 0),
            .lineTo(x: 10, y: 10),
            .lineTo(x: 0, y: 10),
            .closePath,
        ])
    }

    @Test
    func parseInheritsFillFromAnAncestorGroup() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><g fill=\"#00ff00\"><path d=\"M0 0 L10 10Z\"/></g></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.first?.fillColor == BIMIColor(red: 0, green: 1, blue: 0))
    }

    @Test
    func parseAppliesATranslateTransformToPathPoints() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 L1 1Z\" fill=\"#000\" transform=\"translate(5,5)\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.first?.path == [.moveTo(x: 5, y: 5), .lineTo(x: 6, y: 6), .closePath])
    }

    @Test
    func parseComposesNestedGroupTransforms() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><g transform=\"translate(1,1)\"><g transform=\"scale(2)\"><path d=\"M0 0Z\" fill=\"#000\"/></g></g></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        // scale(2) applied first (innermost), then translate(1,1): (0,0) *
        // scale(2) = (0,0), then + (1,1) = (1,1).
        #expect(image.shapes.first?.path.first == .moveTo(x: 1, y: 1))
    }

    @Test
    func parseBuildsARectAsAClosedPolygon() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><rect x=\"1\" y=\"2\" width=\"3\" height=\"4\" fill=\"#000\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.first?.path == [
            .moveTo(x: 1, y: 2),
            .lineTo(x: 4, y: 2),
            .lineTo(x: 4, y: 6),
            .lineTo(x: 1, y: 6),
            .closePath,
        ])
    }

    @Test
    func parseSkipsATitleElement() throws {
        // Real-world tool-exported SVGs (Adobe Illustrator in particular)
        // routinely include a `<title>` — verified against a real BIMI logo
        // (PayPal's, fetched during manual verification of this batch) that
        // failed to parse before this parser started treating `<title>`/
        // `<desc>` as skippable, non-rendering elements.
        let svg = "<svg viewBox=\"0 0 10 10\"><title>Example</title><path d=\"M0 0Z\" fill=\"#000\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.count == 1)
    }

    @Test
    func parseHandlesARealWorldBIMILogoWithNestedGroupsCommentsAndATitle() throws {
        // A trimmed-but-structurally-faithful excerpt of PayPal's actual
        // published BIMI logo SVG (fetched live from
        // paypalobjects.com/marketing/web/logos/paypal_ppe.svg during this
        // batch's manual BIMI verification step) — nested `<g>`s, an XML
        // comment, a `<title>`, and a `<rect>` background alongside `<path>`
        // shapes using only `M`/`L`/`C`/`Z` commands.
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" baseProfile="tiny-ps" version="1.2" viewBox="0 0 700 700">
          <!-- Generator comment -->
        <title>PayPal</title>
          <g>
            <g id="Avatar">
              <g id="Circle-Avatar">
                <rect width="700" height="700" fill="#fff"/>
                <g>
                  <path d="M177.6,487h91.3l17.2-111.8,3.6-23.2h0l20.7-135h123.8" fill="#002991"/>
                  <path d="M289.6,352.1l-3.6,23.2-17.2,111.8-14.6,90h90.7l21.3-135h51" fill="#60cdff"/>
                </g>
              </g>
            </g>
          </g>
        </svg>
        """
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.width == 700)
        #expect(image.height == 700)
        // 1 background rect + 2 paths.
        #expect(image.shapes.count == 3)
    }

    @Test
    func parseHandlesTheRealPayPalBIMILogoVerbatim() throws {
        // The complete, unmodified SVG this batch fetched from PayPal's
        // real, currently-published BIMI record during manual verification
        // (`default._bimi.paypal.com` → `v=BIMI1; l=https://www.paypalobjects
        // .com/marketing/web/logos/paypal_ppe.svg`). Kept as a standing
        // regression fixture — this is the actual external artifact this
        // parser must handle, not a synthetic approximation of one.
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" baseProfile="tiny-ps" version="1.2" viewBox="0 0 700 700">
          <!-- Generator: Adobe Illustrator 28.6.0, SVG Export Plug-In . SVG Version: 1.2.0 Build 709)  -->
        <title>PayPal</title>
          <g>
            <g id="Avatar">
              <g id="Circle-Avatar">
                <rect width="700" height="700" fill="#fff"/>
                <g>
                  <path d="M177.6,487h91.3l17.2-111.8,3.6-23.2h0l20.7-135h123.8c20.7,0,39.8,5.1,55.4,13.5h0c.2-12.5-1.8-24.6-5.9-35.7-14.4-39.4-53.6-67.7-103.3-67.7h-147.8l-54.9,359.9h0Z" fill="#002991"/>
                  <path d="M289.6,352.1l-3.6,23.2-17.2,111.8-14.6,90h90.7l21.3-135h51c62.2,0,114.8-45.5,124.9-108,6.7-43.8-15.1-83.8-52.6-103.4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0h0c0,49.6-40,107.2-102.5,119.2-7.7,1.5-15.7,2.3-24,2.3h-73.4Z" fill="#60cdff"/>
                  <path d="M489.6,230.7s0,0,0,0c0-.9,0-1,0,0h0s0,0,0,0Z"/>
                  <path d="M310.3,217.1l-20.7,135h73.4c8.3,0,16.4-.8,24-2.3,62.5-12,102.5-69.6,102.5-119.2h0c-15.7-8.4-34.7-13.5-55.4-13.5h-123.8Z" fill="#008cff"/>
                </g>
              </g>
            </g>
          </g>
        </svg>
        """
        #expect(BIMISVGSafety.isSafe(Data(svg.utf8)) == true)
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.width == 700)
        #expect(image.height == 700)
        // 1 background rect + 4 paths (one of which — the degenerate `s`
        // sliver — has no `fill` attribute, so it inherits black).
        #expect(image.shapes.count == 5)
    }

    @Test
    func parseSkipsContentInsideDefs() throws {
        let svg = "<svg viewBox=\"0 0 10 10\"><defs><path d=\"M0 0Z\" fill=\"#000\"/></defs></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.isEmpty)
    }

    @Test
    func parseReturnsNilForAnUnsupportedQuadraticCurveCommand() {
        let svg = "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 Q5 5 10 10\" fill=\"#000\"/></svg>"
        #expect(BIMISVGParser.parse(svg) == nil)
    }

    @Test
    func parseReturnsNilForAGradientFill() {
        let svg = "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0Z\" fill=\"url(#grad)\"/></svg>"
        #expect(BIMISVGParser.parse(svg) == nil)
    }

    @Test
    func parseReturnsNilForAnUnsupportedElement() {
        let svg = "<svg viewBox=\"0 0 10 10\"><text x=\"0\" y=\"0\">hi</text></svg>"
        #expect(BIMISVGParser.parse(svg) == nil)
    }

    @Test
    func parseReturnsNilForAnUnsupportedTransformFunction() {
        let svg = "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0Z\" fill=\"#000\" transform=\"rotate(45)\"/></svg>"
        #expect(BIMISVGParser.parse(svg) == nil)
    }

    @Test
    func parseReturnsNilWithoutAnSVGRoot() {
        #expect(BIMISVGParser.parse("<g><path d=\"M0 0Z\"/></g>") == nil)
    }

    /// Regression bound for Task #168 (SEC-C, `CLAUDE-SECURITY` F12):
    /// `tokenize`'s regex had four adjacent groups that could all match
    /// the same whitespace run, so an unterminated tag followed by a
    /// long space run (well within the 64KB BIMI logo size cap) made the
    /// engine enumerate every way to split that run before failing.
    /// Confirmed via a standalone repro that the pre-fix regex was still
    /// running after 15s on this exact payload; post-fix it completes in
    /// milliseconds.
    @Test("an unterminated tag followed by tens of thousands of spaces does not hang tokenizing")
    func tokenizeDoesNotHangOnAnUnterminatedTagWithALongWhitespaceRun() {
        let payload = "<svg viewBox=\"0 0 8 8\"/><g" + String(repeating: " ", count: 50_000)
        let start = Date()
        let tokens = BIMISVGParser.tokenize(payload)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(tokens == nil)
    }

    /// Found and fixed alongside F12 (not itself a numbered
    /// `CLAUDE-SECURITY` finding, but the same class of bug in the same
    /// file): `parseAttributes`' regex had a greedy identifier
    /// immediately followed by a required `=` that might never appear,
    /// which made `NSRegularExpression.matches(in:)` retry a shrinking
    /// suffix of the same non-matching identifier from every subsequent
    /// starting position — real, attacker-reachable quadratic cost
    /// (confirmed via a standalone repro to take upward of 8s on 500,000
    /// bytes of a single repeated letter with no `=` anywhere).
    @Test("a long attribute-position span with no '=' anywhere does not hang parseAttributes")
    func parseAttributesDoesNotHangOnALongRunWithNoEquals() {
        let payload = String(repeating: "a", count: 500_000)
        let start = Date()
        _ = BIMISVGParser.parseAttributes(payload)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("parseAttributes still reads ordinary double- and single-quoted attributes")
    func parseAttributesStillParsesOrdinaryAttributes() {
        let attributes = BIMISVGParser.parseAttributes(" d=\"M0 0Z\" fill=\"#336699\" transform='translate(1,1)' ")
        #expect(attributes == ["d": "M0 0Z", "fill": "#336699", "transform": "translate(1,1)"])
    }

    @Test("an XML declaration prologue before the <svg> root is skipped, not fatal")
    func tokenizeSkipsAnXMLDeclarationPrologue() throws {
        // A real published BIMI logo (PayPal's — see this file's other
        // PayPal fixtures) is served with a leading `<?xml ...?>`
        // declaration. `tokenize`'s hand-written scanner must skip
        // constructs that aren't `<name...>`/`</name...>` (this one
        // starts with `?`, not a letter) rather than failing the whole
        // document, matching the original regex-based implementation's
        // behavior (which simply never matched the declaration as a tag).
        let svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg viewBox=\"0 0 10 10\"><path d=\"M0 0Z\" fill=\"#000\"/></svg>"
        let image = try #require(BIMISVGParser.parse(svg))
        #expect(image.shapes.count == 1)
    }

    // MARK: - BIMIPathDataParser

    @Test
    func pathDataParserHandlesImplicitCommandRepetition() {
        let commands = BIMIPathDataParser.parse("M0,0 10,0 10,10", transform: .identity)
        #expect(commands == [.moveTo(x: 0, y: 0), .lineTo(x: 10, y: 0), .lineTo(x: 10, y: 10)])
    }

    @Test
    func pathDataParserHandlesRelativeCommands() {
        let commands = BIMIPathDataParser.parse("m0,0 l10,0 l0,10 z", transform: .identity)
        #expect(commands == [.moveTo(x: 0, y: 0), .lineTo(x: 10, y: 0), .lineTo(x: 10, y: 10), .closePath])
    }

    @Test
    func pathDataParserHandlesPackedNumbersWithoutSeparators() {
        // "1-1" must parse as two numbers (1, -1), and "1.5.5" as (1.5, 0.5).
        let commands = BIMIPathDataParser.parse("M1-1L1.5.5", transform: .identity)
        #expect(commands == [.moveTo(x: 1, y: -1), .lineTo(x: 1.5, y: 0.5)])
    }

    @Test
    func pathDataParserReturnsNilForAnArcCommand() {
        #expect(BIMIPathDataParser.parse("M0 0 A5 5 0 0 1 10 10", transform: .identity) == nil)
    }

    @Test
    func pathDataParserReflectsTheSmoothCubicControlPointAfterAPrecedingCurve() {
        // C0,0 10,0 10,10 then S20,10 20,20 — the S's first control point
        // should be the reflection of (10,0) across (10,10), i.e. (10,20).
        let commands = BIMIPathDataParser.parse("M0,0 C0,0 10,0 10,10 S20,10 20,20", transform: .identity)
        #expect(commands == [
            .moveTo(x: 0, y: 0),
            .curveTo(cx1: 0, cy1: 0, cx2: 10, cy2: 0, x: 10, y: 10),
            .curveTo(cx1: 10, cy1: 20, cx2: 20, cy2: 10, x: 20, y: 20),
        ])
    }

    @Test
    func pathDataParserTreatsSmoothCubicAsUnreflectedWithoutAPrecedingCurve() {
        // No preceding C/S — S's implicit first control point is just the
        // current point (no reflection).
        let commands = BIMIPathDataParser.parse("M5,5 S20,10 20,20", transform: .identity)
        #expect(commands == [
            .moveTo(x: 5, y: 5),
            .curveTo(cx1: 5, cy1: 5, cx2: 20, cy2: 10, x: 20, y: 20),
        ])
    }

    /// Regression bound for Task #168 (SEC-C, `CLAUDE-SECURITY` F7):
    /// `Z`/`z` had no argument, so when the character right after it was
    /// neither a separator nor a command letter, the parser's implicit
    /// command-repetition path re-selected `Z` forever without consuming
    /// any input — a true `while true` infinite loop with `commands`
    /// growing without bound, confirmed via a standalone repro (not
    /// exercised through this file's own history) to still be running
    /// after 10s pre-fix. Post-fix this returns `nil` immediately.
    @Test("a Z immediately followed by a non-separator, non-letter token fails closed instead of looping forever")
    func pathDataParserDoesNotHangOnAnImplicitZRepetition() {
        let start = Date()
        let result = BIMIPathDataParser.parse("M0 0Z0", transform: .identity)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(result == nil)
    }

    @Test
    func pathDataParserHandlesTheRealPayPalBIMILogosDegenerateSCommandSegment() {
        // The literal degenerate path segment from PayPal's real, currently
        // published BIMI logo (`default._bimi.paypal.com` → paypalobjects.com
        // /marketing/web/logos/paypal_ppe.svg, fetched during this batch's
        // required manual verification) — a near-zero-motion sliver that
        // uses lowercase `s`. This parser rejected the whole logo before
        // `S`/`s` support was added; this test pins that real-world case.
        let commands = BIMIPathDataParser.parse("M489.6,230.7s0,0,0,0c0-.9,0-1,0,0h0s0,0,0,0Z", transform: .identity)
        #expect(commands != nil)
    }

    // MARK: - BIMIColorParsing

    @Test
    func colorParsingHandlesShortHex() {
        #expect(BIMIColorParsing.parse("#0f0") == BIMIColor(red: 0, green: 1, blue: 0))
    }

    @Test
    func colorParsingHandlesRGBFunctional() {
        #expect(BIMIColorParsing.parse("rgb(255, 0, 0)") == BIMIColor(red: 1, green: 0, blue: 0))
    }

    @Test
    func colorParsingHandlesRGBAFunctional() {
        #expect(BIMIColorParsing.parse("rgba(0, 0, 255, 0.5)") == BIMIColor(red: 0, green: 0, blue: 1, alpha: 0.5))
    }

    @Test
    func colorParsingHandlesNamedColors() {
        #expect(BIMIColorParsing.parse("black") == BIMIColor(red: 0, green: 0, blue: 0))
    }

    @Test
    func colorParsingReturnsNilForNone() {
        #expect(BIMIColorParsing.parse("none") == nil)
    }

    @Test
    func colorParsingReturnsNilForAGradientReference() {
        #expect(BIMIColorParsing.parse("url(#grad1)") == nil)
    }

    // MARK: - Affine

    @Test
    func affineParsesAMatrixFunction() throws {
        let affine = try #require(Affine.parse("matrix(1,0,0,1,5,10)"))
        #expect(affine.apply((0, 0)) == (5, 10))
    }

    @Test
    func affineReturnsNilForARotateFunction() {
        #expect(Affine.parse("rotate(45)") == nil)
    }
}
