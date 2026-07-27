import Foundation
import Testing
@testable import OtegamiCore

@Suite("MailtoURLParser")
struct MailtoURLParserTests {
    // MARK: - Scheme handling

    @Test("returns nil for a non-mailto scheme")
    func rejectsNonMailtoScheme() {
        #expect(MailtoURLParser.parse("https://example.com") == nil)
    }

    @Test("is case-insensitive on the scheme")
    func acceptsUppercaseScheme() {
        let result = MailtoURLParser.parse("MAILTO:foo@example.com")
        #expect(result?.to == ["foo@example.com"])
    }

    @Test("a bare 'mailto:' with nothing else parses to an all-empty result, not nil")
    func bareSchemeParsesToEmptyResult() {
        let result = MailtoURLParser.parse("mailto:")
        #expect(result == MailtoURLParser.Result())
    }

    // MARK: - `to` from the path component

    @Test("a single address in the path")
    func singleAddressInPath() {
        let result = MailtoURLParser.parse("mailto:foo@example.com")
        #expect(result?.to == ["foo@example.com"])
        #expect(result?.cc == [])
        #expect(result?.bcc == [])
        #expect(result?.subject == "")
        #expect(result?.body == "")
    }

    @Test("multiple comma-separated addresses in the path")
    func multipleAddressesInPath() {
        let result = MailtoURLParser.parse("mailto:a@example.com,b@example.com")
        #expect(result?.to == ["a@example.com", "b@example.com"])
    }

    @Test("addresses in the path are percent-decoded")
    func pathAddressIsPercentDecoded() {
        // A quoted local-part with an escaped space, matching RFC 6068 §2's
        // own example shape.
        let result = MailtoURLParser.parse("mailto:%22John%20Doe%22@example.com")
        #expect(result?.to == ["\"John Doe\"@example.com"])
    }

    // MARK: - `to`/`cc`/`bcc` query hfields

    @Test("empty path with a 'to' hfield")
    func emptyPathWithToHfield() {
        let result = MailtoURLParser.parse("mailto:?to=a@example.com,b@example.com")
        #expect(result?.to == ["a@example.com", "b@example.com"])
    }

    @Test("path address and 'to' hfield combine (RFC 6068 §2's equivalence example)")
    func pathAndToHfieldCombine() {
        let result = MailtoURLParser.parse("mailto:addr1@example.com?to=addr2@example.com")
        #expect(result?.to == ["addr1@example.com", "addr2@example.com"])
    }

    @Test("cc and bcc hfields")
    func ccAndBccHfields() {
        let result = MailtoURLParser.parse("mailto:a@example.com?cc=b@example.com&bcc=c@example.com,d@example.com")
        #expect(result?.to == ["a@example.com"])
        #expect(result?.cc == ["b@example.com"])
        #expect(result?.bcc == ["c@example.com", "d@example.com"])
    }

    @Test("hfield keys are case-insensitive")
    func hfieldKeysAreCaseInsensitive() {
        let result = MailtoURLParser.parse("mailto:?TO=a@example.com&Subject=hi&BODY=there")
        #expect(result?.to == ["a@example.com"])
        #expect(result?.subject == "hi")
        #expect(result?.body == "there")
    }

    // MARK: - subject/body

    @Test("subject and body are percent-decoded, including spaces and newlines")
    func subjectAndBodyDecoded() {
        let result = MailtoURLParser.parse("mailto:a@example.com?subject=Hello%20There&body=Line%201%0ALine%202")
        #expect(result?.subject == "Hello There")
        #expect(result?.body == "Line 1\nLine 2")
    }

    @Test("Japanese subject and body round-trip through UTF-8 percent-encoding")
    func japaneseSubjectAndBodyDecoded() {
        let subject = "件名です"
        let body = "本文です\n二行目"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "a@example.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        // Build the raw string ourselves rather than trusting
        // `URLComponents.percentEncodedQuery` end to end — this test's job
        // is to check *our* decoding, using a hand-built RFC 3986-style
        // percent-encoded string as the input.
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let raw = "mailto:a@example.com?subject=\(encodedSubject)&body=\(encodedBody)"

        let result = MailtoURLParser.parse(raw)
        #expect(result?.subject == subject)
        #expect(result?.body == body)
    }

    @Test("a '+' in a query value stays literal (mailto isn't form-encoded)")
    func plusStaysLiteral() {
        let result = MailtoURLParser.parse("mailto:a@example.com?subject=1%2B1")
        #expect(result?.subject == "1+1")
    }

    @Test("a raw '+' (not percent-encoded) also stays literal")
    func rawPlusStaysLiteral() {
        let result = MailtoURLParser.parse("mailto:a@example.com?subject=a+b")
        #expect(result?.subject == "a+b")
    }

    @Test("a later duplicate hfield wins over an earlier one")
    func laterDuplicateHfieldWins() {
        let result = MailtoURLParser.parse("mailto:?subject=first&subject=second")
        #expect(result?.subject == "second")
    }

    // MARK: - Malformed / unsupported input, handled without crashing

    @Test("a malformed percent-escape in an address is dropped, not crashed on")
    func malformedPercentEscapeInAddressIsDropped() {
        let result = MailtoURLParser.parse("mailto:%zz@example.com,good@example.com")
        #expect(result?.to == ["good@example.com"])
    }

    @Test("an unsupported hfield is ignored")
    func unsupportedHfieldIsIgnored() {
        let result = MailtoURLParser.parse("mailto:a@example.com?in-reply-to=%3Cid@example.com%3E&keywords=x,y")
        #expect(result?.to == ["a@example.com"])
        #expect(result?.subject == "")
        #expect(result?.body == "")
    }

    @Test("an empty hfield value parses to an empty string, not a crash")
    func emptyHfieldValue() {
        let result = MailtoURLParser.parse("mailto:a@example.com?subject=")
        #expect(result?.subject == "")
    }

    @Test("a trailing '&' with an empty pair is ignored")
    func trailingAmpersandIgnored() {
        let result = MailtoURLParser.parse("mailto:a@example.com?subject=hi&")
        #expect(result?.subject == "hi")
    }

    @Test("URL(string:) entry point matches the String entry point")
    func urlEntryPointMatchesStringEntryPoint() throws {
        let string = "mailto:a@example.com?subject=hi"
        let url = try #require(URL(string: string))
        #expect(MailtoURLParser.parse(url) == MailtoURLParser.parse(string))
    }
}
