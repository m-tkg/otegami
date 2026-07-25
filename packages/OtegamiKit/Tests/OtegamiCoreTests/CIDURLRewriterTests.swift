import Foundation
import Testing
@testable import OtegamiCore

@Suite("CIDURLRewriter")
struct CIDURLRewriterTests {
    @Test("rewrites a double-quoted cid: src to the otegami-cid scheme")
    func rewritesDoubleQuoted() {
        // `@` is percent-encoded (`%40`) rather than passed through literally
        // — see `percentEncodesAtSign` below for why (an unencoded `@` here
        // was the actual M8 cid-inline-image production bug).
        let html = #"<p>hi</p><img src="cid:logo@otegami.test">"#
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == #"<p>hi</p><img src="otegami-cid://logo%40otegami.test">"#)
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
        #expect(rewritten == #"<img src="otegami-cid://one%40x"><img src="otegami-cid://two%40x">"#)
    }

    @Test("percent-encodes an @ in the content id so URL.host doesn't truncate it")
    func percentEncodesAtSign() {
        // A real Content-ID is almost always `<unique-part>@<domain>` (RFC
        // 2392). An unencoded `@` after `scheme://` is parsed by `URL` as
        // the userinfo separator, silently truncating `.host` down to just
        // the domain part — this was the actual production bug (M8's cid
        // inline images never resolved). Assert both that the rewrite
        // encodes it, and that decoding the resulting URL's `.host` round-trips
        // back to the original content id, which is the actual contract
        // `CIDSchemeHandler.contentId(from:)` depends on.
        let html = #"<img src="cid:otegami-logo@otegami.test">"#
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == #"<img src="otegami-cid://otegami-logo%40otegami.test">"#)

        let url = URL(string: "otegami-cid://otegami-logo%40otegami.test")
        #expect(url?.host == "otegami-logo@otegami.test")
    }

    @Test("percent-encodes other URL-structural characters in a content id")
    func percentEncodesOtherStructuralCharacters() {
        // `/`, `?`, `#`, and space are all structural in a URL's authority
        // component; a content id containing one (unusual, but not
        // prohibited by any client-side validation this app performs on
        // received mail) must round-trip through the same encode/decode
        // contract as the `@` case above rather than corrupting the URL or
        // being silently dropped.
        let html = #"<img src="cid:weird id/with space?and#hash">"#
        let rewritten = CIDURLRewriter.rewrite(html: html)
        #expect(rewritten == #"<img src="otegami-cid://weird%20id%2Fwith%20space%3Fand%23hash">"#)

        let url = URL(string: "otegami-cid://weird%20id%2Fwith%20space%3Fand%23hash")
        #expect(url?.host == "weird id/with space?and#hash")
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
