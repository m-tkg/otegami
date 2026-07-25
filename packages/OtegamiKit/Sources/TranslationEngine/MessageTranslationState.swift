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

    public var isTranslating: Bool {
        if case .translating = self { return true }
        return false
    }

    public var translatedRecord: MessageTranslationRecord? {
        if case .translated(let record) = self { return record }
        return nil
    }
}
