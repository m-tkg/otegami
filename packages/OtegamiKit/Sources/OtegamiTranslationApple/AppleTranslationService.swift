import Foundation
import OtegamiTranslation
import Translation

/// Task #159 (メール翻訳を Apple Translation フレームワークの専用 NMT へ切替):
/// the `TranslationOnlyService` conformer backed by `Translation
/// .TranslationSession` — a dedicated on-device machine-translation model
/// (iOS 18+/macOS 15+; this app's own floor is already 26+), as opposed to
/// `FoundationModelsTranslationService`'s general-purpose on-device LLM
/// (`OtegamiTranslationFoundationModels`, unchanged — still used for
/// summarization via `HybridTranslationService`, `OtegamiTranslation`).
///
/// **Session bridging**: `TranslationSession` has no public initializer, and
/// (confirmed against the actual SDK) isn't `Sendable` — this type never
/// touches a `TranslationSession` value directly at all. Every actual session
/// use lives inside `TranslationSessionCoordinator` (`@MainActor`), whose
/// public API takes/returns only plain `Sendable` types; see that type's doc
/// comment for the full `.translationTask` handshake this relies on.
///
/// **Source language is always auto-detected, never the caller's `source`
/// argument** (Task #159 point 4 — real-device report: `NLLanguageRecognizer`
/// confidently mis-detected an English notification mail as Polish, and
/// `MessageView.kickoffTranslationIfNeeded`'s auto-translate gate trusts that
/// stored guess). Every call site in this codebase passes `.english`
/// unconditionally (`MessageView.requestTranslation`) — honoring it verbatim
/// here would just re-encode the same "assume English" premise that made a
/// wrong guess upstream produce a silently-wrong (or silently-skipped)
/// translation. `TranslationSessionCoordinator.translate`/`translateBatch`
/// always configure the session with `source: nil` instead, letting the
/// Translation framework's own detector — a different, translation-purpose-
/// built model, not `NLLanguageRecognizer` — decide the real source at the
/// moment of translation, so the *actual* language of the text always drives
/// the result regardless of what any upstream heuristic guessed. This is
/// what Task #159's own wording ("自動翻訳の言語判定も Translation 側の判定へ
/// 寄せ") means in practice — see `docs/translation.md`'s Task #159 section
/// for the full writeup, including the one thing this change does *not* fix
/// (`MessageView.kickoffTranslationIfNeeded`'s upstream gate still decides
/// *whether* to auto-kick a translation off at all; this only fixes what
/// happens once one actually runs).
///
/// The one place `source` is actually read: `source == target` short-
/// circuits to the input text unchanged, without engaging the engine at all
/// — translating a language into itself is never meaningful, and this keeps
/// that check honest even though it can't currently trigger (every call site
/// passes `.english`/`.japanese`, never the same value twice).
@available(iOS 18.0, macOS 15.0, *)
public struct AppleTranslationService: TranslationOnlyService {
    private let coordinator: TranslationSessionCoordinator

    public init(coordinator: TranslationSessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Task #159 point 3: unlike `FoundationModelsTranslationService`
    /// (`SystemLanguageModel.default.availability`, a real synchronous
    /// device-eligibility check), the Translation framework has no
    /// synchronous "can this engine translate at all right now" property —
    /// per-language-pair readiness (`LanguageAvailability.status(from:to:)`,
    /// used by `ensureLanguagePairSupported` below) is inherently async and
    /// only answerable once a pair is known. Always reporting `.available`
    /// here is deliberate, not a stub: the framework itself is
    /// unconditionally present on this app's iOS/macOS 26+ floor, and Task
    /// #159's own spec ("翻訳ボタンは常時有効の現仕様維持") wants the translate
    /// button to stay enabled regardless of per-language-pack download
    /// state. An undownloaded pack surfaces instead as a specific,
    /// actionable `TranslationServiceError` from `translate`/
    /// `translateParagraphs` themselves — the same "fail at the actual call,
    /// not at the gate" philosophy `docs/translation.md`'s Task #138 section
    /// already established for the button-*visibility* gate (language-
    /// independent since then), now extended to the button's *availability*
    /// gate too.
    public var availability: TranslationAvailability { .available }

    public func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> String {
        guard source != target else { return text }
        try await ensureLanguagePairSupported(from: source, to: target)
        try await prepareTranslationOrThrow(to: target)
        do {
            return try await coordinator.translate(text, to: target.locale)
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    /// Batches every paragraph into one `TranslationSessionCoordinator
    /// .translateBatch` call rather than looping `translate(_:from:to:)` per
    /// paragraph the way `FoundationModelsTranslationService.translateParagraphs`
    /// loops `LanguageModelSession.respond` — that type deliberately wants
    /// one fresh session per paragraph (its own doc comment: no shared
    /// conversation context to bias later paragraphs), a concern that
    /// doesn't apply here since `TranslationSession` carries no conversation
    /// history at all; batching is strictly an efficiency win with no
    /// correctness downside.
    public func translateParagraphs(_ paragraphs: [String], from source: TranslationLanguage, to target: TranslationLanguage) async throws -> [String] {
        guard !paragraphs.isEmpty else { return [] }
        guard source != target else { return paragraphs }
        try await ensureLanguagePairSupported(from: source, to: target)
        try await prepareTranslationOrThrow(to: target)
        do {
            return try await coordinator.translateBatch(paragraphs, to: target.locale)
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            throw Self.mapEngineError(error)
        }
    }

    /// See `TranslationOnlyService.translateStream`'s doc comment: the
    /// Translation framework's NMT has no incremental output to stream, so
    /// this yields `translate(_:from:to:)`'s single, already-final result
    /// once and finishes — a valid (if degenerate) conformance to the
    /// "cumulative snapshot, caller renders the latest" contract.
    public func translateStream(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await translate(text, from: source, to: target)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Language pack readiness (Task #159 point 3)

    /// Checks `LanguageAvailability.status(from:to:)` for the caller's
    /// *nominal* `source`/`target` pair — a best-effort proxy for the
    /// session's real (auto-detected) pair, good enough because every actual
    /// call site's nominal pair (English→Japanese) matches the overwhelming
    /// common case. `.unsupported` fails fast with a clear, actionable
    /// message before even obtaining a session; `.supported`/`.installed`
    /// both just return, letting `TranslationSessionCoordinator
    /// .prepareTranslation(to:)` (called right after, at each call site)
    /// handle an install that hasn't finished yet.
    private func ensureLanguagePairSupported(from source: TranslationLanguage, to target: TranslationLanguage) async throws {
        let status = await LanguageAvailability().status(from: source.locale, to: target.locale)
        switch status {
        case .unsupported:
            throw TranslationServiceError.unavailable(.other("この端末は\(source.displayName)から\(target.displayName)への翻訳に対応していません"))
        case .installed, .supported:
            return
        @unknown default:
            return
        }
    }

    /// `TranslationSessionCoordinator.prepareTranslation(to:)` — Apple's
    /// documented way to proactively trigger the system's language-download
    /// prompt — is a no-op if the pack is already installed, so this costs
    /// nothing in the common (already-downloaded) case and turns a first-use
    /// download into an explicit, visible OS flow instead of a confusing
    /// mid-translation failure. Wraps any failure into a specific,
    /// actionable message (rather than falling through to `mapEngineError`'s
    /// generic one) since this is the one step in the pipeline that's
    /// actually *about* language-pack readiness.
    private func prepareTranslationOrThrow(to target: TranslationLanguage) async throws {
        do {
            try await coordinator.prepareTranslation(to: target.locale)
        } catch {
            throw TranslationServiceError.unavailable(.other("翻訳用の言語データのダウンロードが必要です（\(error.localizedDescription)）。設定 > 一般 > 言語と地域 から翻訳言語をダウンロードしてください"))
        }
    }

    /// Maps `Translation.TranslationError` (verified against the actual SDK's
    /// `.swiftinterface` — not from memory) onto specific
    /// `TranslationServiceError` cases where a clearer, actionable message
    /// helps (Task #159 point 3); everything else (a plain
    /// `error.localizedDescription`, same as before this mapping existed)
    /// falls through to `.failed`. `TranslationError`'s custom `~=` operator
    /// (its own declaration) is what makes `case TranslationError.xxx:`
    /// valid here even though `error` is a plain `any Error`, not already
    /// known to be a `TranslationError`.
    private static func mapEngineError(_ error: Error) -> TranslationServiceError {
        switch error {
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
            return .unavailable(.other("この端末はこの言語の翻訳に対応していません"))
        case TranslationError.unableToIdentifyLanguage:
            return .failed(message: "翻訳元の言語を判定できませんでした")
        case TranslationError.nothingToTranslate:
            return .failed(message: "翻訳する本文がありませんでした")
        default:
            break
        }
        // `.notInstalled`/`.alreadyCancelled` are themselves `@available(iOS
        // 26.0, macOS 26.0, *)` cases on an otherwise iOS 18/macOS 15 type —
        // this app's floor is already 26+ (`project.yml`) so this branch
        // always runs in practice, but the `#available` guard keeps this
        // file honest about what this package's own (lower) platform floor
        // actually guarantees, mirroring
        // `FoundationModelsTranslationService.mapEngineError`'s same
        // "declared floor vs. this app's actual floor" split.
        if #available(iOS 26.0, macOS 26.0, *), case TranslationError.notInstalled = error {
            return .unavailable(.other("翻訳用の言語データが未ダウンロードです。設定 > 一般 > 言語と地域 から翻訳言語をダウンロードしてください"))
        }
        return .failed(message: error.localizedDescription)
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension TranslationLanguage {
    /// `TranslationSession.Configuration`/`LanguageAvailability` both speak
    /// `Locale.Language`, not this app's closed two-case enum — this is the
    /// one seam between them, mirroring `FoundationModelsTranslationService`
    /// keeping all of its Apple-type mapping private to itself.
    var locale: Locale.Language {
        switch self {
        case .english: Locale.Language(languageCode: .english)
        case .japanese: Locale.Language(languageCode: .japanese)
        }
    }
}
