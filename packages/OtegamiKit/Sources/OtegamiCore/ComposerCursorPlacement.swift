import Foundation

/// Task #125 (作成画面「署名カーソル」): pure cursor-position logic for
/// `ComposerView`'s body `TextEditor` — split out of the view so the
/// placement rule itself is unit-testable without a SwiftUI host (`TextEditor
/// (text:selection:)`'s `TextSelection` wraps a `String.Index` range, which
/// this type also works in directly so the view layer can hand its result
/// straight to a `TextSelection(insertionPoint:)` with no further
/// conversion).
///
/// The rule (仕様):
/// - 署名テンプレートを選択・自動挿入したとき、カーソルは署名の直前
///   (署名の上の空行) に置く — ユーザーがそのまま書き始められるように。
/// - 返信・転送 (本文に引用ブロックが既にある) では、署名がどこに挿入
///   されていてもカーソルは本文の一番上 (引用の上、結果として署名の上でも
///   ある) に置く — 返信の主目的は新しい文面を書くことで、それは常に引用の
///   前に来るため。
public enum ComposerCursorPlacement {
    /// - Parameters:
    ///   - bodyText: the *already-updated* body text (signature text, if
    ///     any, already appended) to compute an index into.
    ///   - signatureBody: the exact signature body string that was just
    ///     appended to `bodyText` (i.e. `SignatureTemplateRecord.body`, not
    ///     including the separator) — `nil` when no signature is currently
    ///     inserted (the "なし" pick). When non-`nil` but `bodyText` doesn't
    ///     actually end with it (a mismatch that shouldn't happen in
    ///     practice), this falls back to `bodyText.endIndex` rather than
    ///     guessing.
    ///   - hasQuoteAboveSignature: `true` for a reply/forward, whose body
    ///     already carries a quoted block above wherever the signature gets
    ///     appended (`ComposerView.updateSignatureText(newId:)` always
    ///     appends at the very end, after any quote).
    /// - Returns: where the cursor should land in `bodyText`.
    public static func cursorIndex(
        in bodyText: String,
        signatureBody: String?,
        hasQuoteAboveSignature: Bool
    ) -> String.Index {
        if hasQuoteAboveSignature {
            return bodyText.startIndex
        }
        if let signatureBody, !signatureBody.isEmpty, bodyText.hasSuffix(signatureBody) {
            return bodyText.index(bodyText.endIndex, offsetBy: -signatureBody.count)
        }
        return bodyText.endIndex
    }
}
