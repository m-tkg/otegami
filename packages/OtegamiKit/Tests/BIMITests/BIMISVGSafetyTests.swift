import Foundation
import Testing
@testable import BIMI

@Suite("BIMISVGSafety")
struct BIMISVGSafetyTests {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test
    func isSafeAcceptsAPlainSVGWithAPathAndSolidFill() {
        let svg = "<svg viewBox=\"0 0 100 100\"><path d=\"M0 0 L100 0 L100 100 Z\" fill=\"#336699\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == true)
    }

    @Test
    func isSafeRejectsAScriptTag() {
        let svg = "<svg><script>alert(1)</script><path d=\"M0 0Z\" fill=\"red\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsAnEventHandlerAttribute() {
        let svg = "<svg><path d=\"M0 0Z\" fill=\"red\" onload=\"alert(1)\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsAJavascriptURI() {
        let svg = "<svg><a href=\"javascript:alert(1)\"><path d=\"M0 0Z\" fill=\"red\"/></a></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsAnEmbeddedRasterImage() {
        let svg = "<svg><image href=\"https://example.com/x.png\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsAnExternalHref() {
        let svg = "<svg><use href=\"https://example.com/other.svg#icon\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeAllowsAnInternalFragmentHref() {
        let svg = "<svg><defs><path id=\"p\" d=\"M0 0Z\"/></defs><use href=\"#p\" fill=\"red\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == true)
    }

    @Test
    func isSafeRejectsAStyleElement() {
        let svg = "<svg><style>.a{fill:red}</style><path class=\"a\" d=\"M0 0Z\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsAnExternalEntityDeclaration() {
        let svg = "<?xml version=\"1.0\"?><!DOCTYPE svg [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><svg><path d=\"M0 0Z\"/></svg>"
        #expect(BIMISVGSafety.isSafe(data(svg)) == false)
    }

    @Test
    func isSafeRejectsDataLargerThanTheSizeCap() {
        let oversized = String(repeating: "a", count: BIMISVGSafety.maxByteSize + 1)
        #expect(BIMISVGSafety.isSafe(data(oversized)) == false)
    }

    @Test
    func isSafeRejectsEmptyData() {
        #expect(BIMISVGSafety.isSafe(Data()) == false)
    }

    @Test
    func isSafeRejectsUndecodableData() {
        #expect(BIMISVGSafety.isSafe(Data([0xFF, 0xFE, 0x00, 0xFF])) == false)
    }
}
