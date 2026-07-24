import Testing
@testable import OtegamiCore

@Suite("CIDURLRewriter")
struct CIDURLRewriterTests {
    @Test("rewrites a double-quoted cid: src to the otegami-cid scheme")
    func rewritesDoubleQuoted() {
        let html = #"<p>hi</p><img src="cid:logo@otegami.test">"#
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == #"<p>hi</p><img src="otegami-cid://logo@otegami.test">"#)
    }

    @Test("rewrites a single-quoted cid: src")
    func rewritesSingleQuoted() {
        let html = "<img src='cid:abc123'>"
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == "<img src='otegami-cid://abc123'>")
    }

    @Test("rewrites multiple cid: references independently")
    func rewritesMultiple() {
        let html = #"<img src="cid:one@x"><img src="cid:two@x">"#
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == #"<img src="otegami-cid://one@x"><img src="otegami-cid://two@x">"#)
    }

    @Test("leaves http(s) and data: src references untouched")
    func leavesNonCIDReferencesUntouched() {
        let html = #"<img src="https://example.test/a.png"><img src="data:image/png;base64,AAAA">"#
        #expect(CIDURLRewriter.rewrite(html: html) == html)
    }

    @Test("html with no cid: references round-trips unchanged")
    func noOp() {
        let html = "<p>本文だけです。</p>"
        #expect(CIDURLRewriter.rewrite(html: html) == html)
    }
}
