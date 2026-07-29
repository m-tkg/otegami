import Foundation
import OtegamiStore

/// The per-message translation state the design handoff's "State
/// Management" section names directly: `translationState[messageID]`:
/// `.none | .translating | .translated(text) | .failed`, plus
/// `showOriginal: Bool`. Owned here (not in the app target) so the eventual
/// UI phase only has to observe `MessageTranslator`'s output — it doesn't
/// need to reinvent this shape or decide what "failed" carries.
///
/// `.translated` carries the full `MessageTranslationRecord`, not just a
/// `String` — 1i's "段落長押しでその段落だけ原文表示" needs
/// `.paragraphs`, and a re-render after `showOriginal` toggles needs
/// `.translatedText`/the source text both still at hand, not just whichever
/// one was current when the state was captured.
public enum MessageTranslationState: Sendable, Equatable {
    /// No translation exists yet and none has been requested — the default
    /// for every message until something (an explicit tap, or 1l's
    /// "英文を自動で翻訳" setting) asks for one.
    case none
    /// A translation is in flight (`MessageTranslator.translate` was
    /// called and hasn't resolved). A caller driving `translateStream`
    /// instead may layer its own "partial text so far" on top of this case
    /// rather than this enum growing an associated value for it — the
    /// streaming text is transient UI state, not something worth caching
    /// or reasoning about at this layer.
    case translating
    case translated(MessageTranslationRecord)
    /// `message` is `TranslationServiceError.errorDescription` (or an
    /// equivalent short description) — no associated `Error` value, since
    /// this type needs to be `Equatable` for state-transition assertions
    /// in tests, and most `Error`-conforming types aren't.
    case failed(message: String)
    /// 2026-07-30 (Phase 5続報): `TranslationServiceError.insufficientInput`
    /// の写し — 「入力自体が翻訳しようがなかった」ことを`.failed`から区別
    /// できる独立ケースにしたのは、`MessageView.requestTranslation`のHTML
    /// 経路が**この理由の失敗だけ**を検知して plain 本文へ自動フォール
    /// バックするため。文字列比較 (以前の実装、特定の文言と完全一致するか
    /// どうかで判定) は、Apple側のエンジンが同じ根本原因 (実質空の入力)
    /// を別の文言 ("翻訳元の言語を判定できませんでした" 等) で表面化させた
    /// 実機ケースをすり抜けた — ケース自体で判定できるようにして再発を防ぐ。
    case insufficientInput(message: String)

    public var isTranslating: Bool {
        if case .translating = self { return true }
        return false
    }

    /// `.failed`同様、`Error`本体ではなくメッセージだけを運ぶ — 呼び出し側
    /// (`MessageDetailFooterToolbar`) が`.failed`/`.insufficientInput`を
    /// 同じ「失敗として表示する」トーンで扱いたい場面で、都度2ケースを
    /// 書き分けずに済むようにするための共通アクセサ。
    public var failureMessage: String? {
        switch self {
        case .failed(let message), .insufficientInput(let message):
            return message
        case .none, .translating, .translated:
            return nil
        }
    }

    public var translatedRecord: MessageTranslationRecord? {
        if case .translated(let record) = self { return record }
        return nil
    }
}
