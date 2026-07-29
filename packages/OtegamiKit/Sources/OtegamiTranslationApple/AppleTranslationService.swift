import Foundation
import OtegamiTranslation
import Translation
import os

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
        // 2026-07-30 (Phase 5, 実機ログ dd58453 で確定した真因の切り分け用):
        // 本文そのものは出さず、件数/文字数だけを記録 — F15 の趣旨を新規ログ
        // にも適用。
        Self.logger.notice("translate: chars=\(text.count, privacy: .public) source=\(source.rawValue, privacy: .public) target=\(target.rawValue, privacy: .public)")
        let needsDownload = try await ensureLanguagePairSupported(from: source, to: target)
        try await prepareTranslationOrThrow(to: target, knownNotDownloaded: needsDownload)
        do {
            return try await coordinator.translate(text, to: target.locale)
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            Self.logError(error, at: "translate")
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
        // 2026-07-30 (Phase 5): 実機ログ dd58453 で確認された真因は「翻訳対象
        // 0件の配列をそのままバッチ翻訳へ渡していた」こと (`com.apple
        // .Translation:TextAPI`: "Client asked to translate batch of 0
        // inputs" → preflight失敗 → `TranslationErrorDomain Code=21`)。ここは
        // `!paragraphs.isEmpty`で0件を弾いているので直接の再発はしないが、
        // 空白/不可視文字だけの要素が混ざったまま渡ると `TranslationChunker
        // .chunk`側の対応漏れで同じ症状が起きうる — 呼び出し時点の件数/文字数
        // を記録しておく (本文そのものは出さない、F15参照)。
        Self.logger.notice("translateParagraphs: count=\(paragraphs.count, privacy: .public) totalChars=\(paragraphs.reduce(0) { $0 + $1.count }, privacy: .public) source=\(source.rawValue, privacy: .public) target=\(target.rawValue, privacy: .public)")
        let needsDownload = try await ensureLanguagePairSupported(from: source, to: target)
        try await prepareTranslationOrThrow(to: target, knownNotDownloaded: needsDownload)
        do {
            return try await coordinator.translateBatch(paragraphs, to: target.locale)
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            Self.logError(error, at: "translateParagraphs")
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
    /// Returns whether the pair is confirmed *not yet downloaded*
    /// (`status == .supported`) — the one signal `prepareTranslationOrThrow`
    /// below is allowed to treat as a genuine "needs download" case if the
    /// download prompt it triggers still fails. Throws only for `.unsupported`
    /// (no amount of downloading would help).
    private func ensureLanguagePairSupported(from source: TranslationLanguage, to target: TranslationLanguage) async throws -> Bool {
        let status = await LanguageAvailability().status(from: source.locale, to: target.locale)
        // Phase 5 (2026-07-30): this is now the *only* place in this type
        // allowed to claim "language pack not downloaded" — see
        // `TranslationUnavailableReason.languagePackNotDownloaded`'s doc
        // comment for why a translate-time engine failure must never make
        // that claim on its own. Logged at notice so a future report can
        // confirm whether this check itself is what's wrong (e.g. reporting
        // `.supported` for a pair the system's own Translate app already
        // shows as installed) versus something failing downstream of it.
        Self.logger.notice("languagePairStatus: source=\(source.rawValue, privacy: .public) target=\(target.rawValue, privacy: .public) status=\(String(describing: status), privacy: .public)")
        switch status {
        case .unsupported:
            throw TranslationServiceError.unavailable(.languagePairUnsupported)
        case .installed:
            return false
        case .supported:
            // Not yet installed — deliberately not treated as a failure
            // here. `prepareTranslationOrThrow` right after this call is
            // what turns that into the system's own visible download
            // prompt, which is a strictly better experience than a dead-end
            // error message (Task #159 point 3). The caller still learns
            // this via the returned `true`, in case that prompt itself
            // fails.
            return true
        @unknown default:
            return false
        }
    }

    /// `TranslationSessionCoordinator.prepareTranslation(to:)` — Apple's
    /// documented way to proactively trigger the system's language-download
    /// prompt — is a no-op if the pack is already installed, so this costs
    /// nothing in the common (already-downloaded) case and turns a first-use
    /// download into an explicit, visible OS flow instead of a confusing
    /// mid-translation failure.
    ///
    /// 2026-07-30 (Phase 5, real-device log `dd58453`): this used to
    /// unconditionally wrap *any* failure here as "language data needs
    /// downloading" plus a hardcoded Settings path — both wrong on the
    /// device that reported it (the language pack was already installed,
    /// and the Settings path had already moved in a previous iOS release).
    /// Now the "needs download" claim is only made when `knownNotDownloaded`
    /// (from `ensureLanguagePairSupported`'s own `LanguageAvailability`
    /// check, the sole source of truth for that claim — see
    /// `TranslationUnavailableReason.languagePackNotDownloaded`'s doc
    /// comment) says so; any other failure here gets the same neutral
    /// mapping every other engine-call failure uses, so it's never a more
    /// confident (and potentially wrong) claim than `translate`/
    /// `translateParagraphs` themselves would make.
    private func prepareTranslationOrThrow(to target: TranslationLanguage, knownNotDownloaded: Bool) async throws {
        do {
            try await coordinator.prepareTranslation(to: target.locale)
        } catch let error as TranslationServiceError {
            throw error
        } catch {
            Self.logError(error, at: "prepareTranslation")
            if knownNotDownloaded {
                throw TranslationServiceError.unavailable(.languagePackNotDownloaded)
            }
            throw Self.mapEngineError(error)
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
            return .unavailable(.languagePairUnsupported)
        case TranslationError.unableToIdentifyLanguage:
            return .failed(message: "翻訳元の言語を判定できませんでした")
        case TranslationError.nothingToTranslate:
            return .failed(message: "翻訳する本文がありませんでした")
        default:
            break
        }
        // 2026-07-30 (Phase 5, real-device log `dd58453`): this branch used
        // to special-case `TranslationError.notInstalled` (`@available` iOS
        // 26/macOS 26, this app's actual floor) as "language pack not
        // downloaded" with a hardcoded Settings path. The captured device
        // log showed that case firing for a completely unrelated failure —
        // an empty-input preflight error (`TranslationErrorDomain Code=21`,
        // "Client asked to translate batch of 0 inputs") — on a device
        // where both languages were already confirmed "Available Offline".
        // Apple's `.notInstalled` evidently isn't a reliable enough signal
        // on its own to justify telling the user their language pack is
        // missing when it might not be; `ensureLanguagePairSupported`'s own
        // `LanguageAvailability` check above is the only place in this type
        // still allowed to make that specific claim (see
        // `TranslationUnavailableReason.languagePackNotDownloaded`'s doc
        // comment). Everything that reaches here — including
        // `.notInstalled` — gets the same neutral, retry-oriented message
        // instead of a possibly-wrong diagnosis.
        return .failed(message: "翻訳に失敗しました（時間をおいて再試行してください）")
    }

    // MARK: - Diagnostics (Phase 5, 2026-07-30)

    /// notice レベル固定 (`docs/verify.md`: debug/info は `log collect`/
    /// sysdiagnose に残らない) — 本文は一切含めない (F15 の趣旨)。domain/code
    /// だけで、実機ログ1本から失敗の種類を切り分けられるようにするための
    /// もの。
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "AppleTranslationService")

    private static func logError(_ error: Error, at site: String) {
        let nsError = error as NSError
        logger.notice("\(site, privacy: .public) failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) type=\(String(describing: Swift.type(of: error)), privacy: .public)")
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
