import Testing
@testable import OtegamiCore

/// Task #129 (作成画面リッチテキスト化): `RichTextDocument`⇄HTML roundtrip
/// coverage for every first-stage formatting primitive (太字/イタリック/下線/
/// 打ち消し線/番号付きリスト/箇条書きリスト/インデント), plus a couple of
/// structural edge cases (mixed formatting within one paragraph, an empty
/// blank-line paragraph, HTML-special characters).
@Suite struct RichTextHTMLCoderTests {
    @Test func plainParagraphsRoundTrip() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "Hello")]),
            RichTextParagraph(runs: [RichTextRun(text: "こんにちは")]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p>Hello</p><p>こんにちは</p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func boldRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "bold", isBold: true)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><b>bold</b></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func italicRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "italic", isItalic: true)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><i>italic</i></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func underlineRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "underlined", isUnderline: true)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><u>underlined</u></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func strikethroughRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "struck", isStrikethrough: true)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><s>struck</s></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func combinedInlineFormattingOnOneRunRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [
                RichTextRun(text: "everything", isBold: true, isItalic: true, isUnderline: true, isStrikethrough: true),
            ]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><s><u><i><b>everything</b></i></u></s></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func mixedFormattingWithinOneParagraphRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [
                RichTextRun(text: "plain "),
                RichTextRun(text: "bold", isBold: true),
                RichTextRun(text: " and "),
                RichTextRun(text: "italic", isItalic: true),
            ]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func bulletedListRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "one")], listStyle: .bullet),
            RichTextParagraph(runs: [RichTextRun(text: "two")], listStyle: .bullet),
        ])
        let html = RichTextHTMLCoder.encode(document)
        // Consecutive bullet paragraphs share one `<ul>` — required so a
        // real mail client renders them as one list, not two.
        #expect(html == "<ul><li>one</li><li>two</li></ul>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func numberedListRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "first")], listStyle: .ordered),
            RichTextParagraph(runs: [RichTextRun(text: "second")], listStyle: .ordered),
            RichTextParagraph(runs: [RichTextRun(text: "third")], listStyle: .ordered),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<ol><li>first</li><li>second</li><li>third</li></ol>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func aNonListParagraphBetweenTwoListsPreventsThemFromMerging() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "a")], listStyle: .bullet),
            RichTextParagraph(runs: [RichTextRun(text: "middle")]),
            RichTextParagraph(runs: [RichTextRun(text: "b")], listStyle: .bullet),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<ul><li>a</li></ul><p>middle</p><ul><li>b</li></ul>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func indentLevelRoundTripsAsNestedBlockquote() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "indented once")], indentLevel: 1),
            RichTextParagraph(runs: [RichTextRun(text: "indented twice")], indentLevel: 2),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<blockquote><p>indented once</p></blockquote><blockquote><blockquote><p>indented twice</p></blockquote></blockquote>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func indentedListRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "nested item")], listStyle: .bullet, indentLevel: 1),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<blockquote><ul><li>nested item</li></ul></blockquote>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func blankLineParagraphRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "before")]),
            RichTextParagraph(runs: []),
            RichTextParagraph(runs: [RichTextRun(text: "after")]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p>before</p><p><br></p><p>after</p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    // MARK: - Task #161 (#129 第2段): フォントサイズ/文字色/背景色/リンク

    @Test func nonStandardFontSizeRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "large", fontSize: .large)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><span style=\"font-size:20px\">large</span></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func standardFontSizeEmitsNoStyleAttribute() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "plain", fontSize: .standard)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p>plain</p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func textColorRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "red", textColor: .red)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><span style=\"color:#d93025\">red</span></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func backgroundColorRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "highlighted", backgroundColor: .yellow)]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><span style=\"background-color:#f9ab00\">highlighted</span></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func fontSizeColorAndBackgroundCombineIntoOneSpan() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [
                RichTextRun(text: "styled", fontSize: .xlarge, textColor: .blue, backgroundColor: .yellow),
            ]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><span style=\"font-size:26px;color:#1a73e8;background-color:#f9ab00\">styled</span></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func linkRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "click here", linkURL: "https://example.test/a?x=1&y=2")]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><a href=\"https://example.test/a?x=1&amp;y=2\">click here</a></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func linkWithColorPutsStyleDirectlyOnTheAnchor() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "styled link", textColor: .purple, linkURL: "https://example.test")]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(html == "<p><a href=\"https://example.test\" style=\"color:#8430ce\">styled link</a></p>")
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func everyInlineFormattingKindTogetherRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [
                RichTextRun(
                    text: "everything", isBold: true, isItalic: true, isUnderline: true, isStrikethrough: true,
                    fontSize: .large, textColor: .green, backgroundColor: .gray, linkURL: "https://example.test/all"
                ),
            ]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func mixedNewAndOldFormattingWithinOneParagraphRoundTrips() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [
                RichTextRun(text: "plain "),
                RichTextRun(text: "bold", isBold: true),
                RichTextRun(text: " and "),
                RichTextRun(text: "a link", linkURL: "https://example.test"),
                RichTextRun(text: " and "),
                RichTextRun(text: "highlighted", backgroundColor: .yellow),
            ]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    @Test func decodingAnArbitraryFontSizeRoundsToTheNearestPreset() {
        let html = "<p><span style=\"font-size:22px\">near large</span></p>"
        let decoded = RichTextHTMLCoder.decode(html: html)
        #expect(decoded.paragraphs.first?.runs.first?.fontSize == .large)
    }

    @Test func decodingAnUnknownHexColorDropsItRatherThanGuessing() {
        let html = "<p><span style=\"color:#123456\">unknown</span></p>"
        let decoded = RichTextHTMLCoder.decode(html: html)
        #expect(decoded.paragraphs.first?.runs.first?.textColor == nil)
    }

    @Test func htmlSpecialCharactersAreEscapedAndRoundTrip() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "<script>alert(\"a & b\")</script>")]),
        ])
        let html = RichTextHTMLCoder.encode(document)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&amp;"))
        #expect(RichTextHTMLCoder.decode(html: html) == document)
    }

    // MARK: - RichTextDocument.plainText / .plainText(_:)

    @Test func plainTextDerivesReadableMarkersForLists() {
        let document = RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "intro")]),
            RichTextParagraph(runs: [RichTextRun(text: "one")], listStyle: .bullet),
            RichTextParagraph(runs: [RichTextRun(text: "two")], listStyle: .bullet),
            RichTextParagraph(runs: [RichTextRun(text: "first")], listStyle: .ordered),
            RichTextParagraph(runs: [RichTextRun(text: "second")], listStyle: .ordered),
        ])
        #expect(document.plainText == "intro\n• one\n• two\n1. first\n2. second")
    }

    @Test func plainTextFactoryProducesOneRunPerLineWithNoFormatting() {
        let document = RichTextDocument.plainText("line one\nline two")
        #expect(document == RichTextDocument(paragraphs: [
            RichTextParagraph(runs: [RichTextRun(text: "line one")]),
            RichTextParagraph(runs: [RichTextRun(text: "line two")]),
        ]))
        #expect(document.plainText == "line one\nline two")
    }
}
