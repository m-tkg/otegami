import Testing
@testable import OtegamiCore

@Suite struct ComposerCursorPlacementTests {
    @Test func placesCursorRightBeforeSignatureWhenNoQuote() {
        let signature = "よろしくお願いします。\n山田太郎"
        let body = "本文\n\n" + signature
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: signature, hasQuoteAboveSignature: false)
        #expect(body[index...] == Substring(signature))
        #expect(body[..<index] == "本文\n\n")
    }

    @Test func placesCursorAtStartWhenQuoteIsAboveSignature() {
        let signature = "署名"
        let body = "\n\n> 引用された本文\n\n" + signature
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: signature, hasQuoteAboveSignature: true)
        #expect(index == body.startIndex)
    }

    @Test func placesCursorAtStartWhenQuoteIsAboveButNoSignatureYet() {
        let body = "\n\n> 引用された本文"
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: nil, hasQuoteAboveSignature: true)
        #expect(index == body.startIndex)
    }

    @Test func placesCursorAtEndWhenNoSignatureAndNoQuote() {
        let body = "本文だけ"
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: nil, hasQuoteAboveSignature: false)
        #expect(index == body.endIndex)
    }

    @Test func handlesEmptyBodyWithOnlySignature() {
        let signature = "署名のみ"
        let body = signature
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: signature, hasQuoteAboveSignature: false)
        #expect(index == body.startIndex)
    }

    @Test func fallsBackToEndIndexWhenSignatureBodyDoesNotMatchSuffix() {
        let body = "本文\n\n違う署名"
        let index = ComposerCursorPlacement.cursorIndex(in: body, signatureBody: "存在しない署名", hasQuoteAboveSignature: false)
        #expect(index == body.endIndex)
    }
}
