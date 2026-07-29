import Foundation
import Observation
import OtegamiTranslation
// `@preconcurrency`: `Translation.TranslationSession` isn't (yet) declared
// `Sendable` by Apple. This coordinator is the *only* place in this package
// that ever holds or touches a `TranslationSession` value — every public
// method below takes/returns only plain `Sendable` types (`String`,
// `Locale.Language`, ...), so the session itself never has to cross an
// actor boundary at all. `@preconcurrency` here just quiets the compiler
// about a type this package doesn't own and can't annotate; it isn't load-
// bearing for the actual safety of this design (see this type's own doc
// comment for why the session never leaves the main actor by construction,
// not by suppressed diagnostics).
@preconcurrency import Translation

/// Task #159: bridges the Translation framework's SwiftUI-only
/// `TranslationSession` (Apple provides no public initializer for it — the
/// only supported way to obtain one is the `.translationTask(_:action:)`
/// view modifier) to `AppleTranslationService`'s plain-`async` API, which has
/// no SwiftUI/View of its own to attach that modifier to.
///
/// **The handshake**: this type owns `configuration` (read by a hosting view
/// living at the app layer — `apps/Otegami/Sources/Features/ThreadDetail
/// /TranslationSessionHostView.swift`, since this package has no SwiftUI
/// dependency and shouldn't need one just to host one modifier call). That
/// view's body reads `configuration` and passes it straight to
/// `.translationTask(_:action:)`; whenever this coordinator changes it (from
/// `obtainSession(target:)` below), SwiftUI notices (this class is
/// `@Observable`) and invokes the hosting view's action closure with a fresh
/// `TranslationSession` shortly after, which the hosting view forwards here
/// via `attach(_:)`.
///
/// **Every public method here takes/returns only `Sendable` types, never a
/// `TranslationSession` itself** — `Translation.TranslationSession` is not
/// `Sendable` (confirmed against the actual SDK: an earlier revision of this
/// type that returned a session directly to `AppleTranslationService` failed
/// to compile with exactly that diagnostic), so `translate(_:to:)`/
/// `translateBatch(_:to:)`/`prepareTranslation(to:)` below each obtain the
/// session, use it, and extract a plain result *entirely within this
/// `@MainActor`-isolated type* — the session's whole lifetime stays on the
/// main actor, satisfying `TranslationOnlyService: Sendable` without ever
/// needing an unsafe cast or `@unchecked Sendable`.
///
/// A session for a `target` language that's already current is reused
/// immediately with no re-suspension — reused across every message
/// translated in the same app session (not recreated per call the way
/// `FoundationModelsTranslationService` deliberately creates a fresh
/// `LanguageModelSession` per call, see that type's doc comment for why that
/// engine wants the opposite) so the system's language-pack download
/// prompt/`prepareTranslation()` overhead is paid at most once per language
/// pair per app launch, not once per message.
///
/// `@MainActor` (not an `actor`): `.translationTask`'s action closure and
/// SwiftUI's own re-render of the hosting view both run on the main actor,
/// and `configuration`'s writes/reads need to interleave with those, not
/// with some other executor.
@available(iOS 18.0, macOS 15.0, *)
@MainActor
@Observable
public final class TranslationSessionCoordinator {
    public init() {}

    /// Read by `TranslationSessionHostView.body` and passed straight to
    /// `.translationTask(_:action:)` — `private(set)` because only
    /// `obtainSession(target:)` below decides when a new session is
    /// actually needed; nothing outside this type should be able to force a
    /// reset.
    public private(set) var configuration: TranslationSession.Configuration?

    private var currentSession: TranslationSession?
    private var currentTarget: Locale.Language?
    private var pendingTarget: Locale.Language?
    private var pendingContinuations: [CheckedContinuation<TranslationSession, Never>] = []

    /// Translates `text`, auto-detecting the source language (`Configuration
    /// (source: nil, target:)` — see `AppleTranslationService`'s doc comment,
    /// Task #159 point 4, for why the source is never forced). Returns the
    /// plain translated string — `TranslationSession.Response` itself never
    /// leaves this method, let alone this type.
    public func translate(_ text: String, to target: Locale.Language) async throws -> String {
        let session = await obtainSession(target: target)
        let response = try await session.translate(text)
        return response.targetText
    }

    /// Batches every element of `texts` into one `session.translations(from:)`
    /// call (rather than looping `translate(_:to:)`) — see
    /// `AppleTranslationService.translateParagraphs`'s doc comment for why
    /// this is a pure efficiency win here (unlike
    /// `FoundationModelsTranslationService`, `TranslationSession` carries no
    /// conversation history a shared batch call could leak between
    /// paragraphs). Returns results in the same order as `texts`; throws
    /// `TranslationServiceError.failed` if the response count doesn't match
    /// (a genuine engine-level anomaly, not expected in practice).
    public func translateBatch(_ texts: [String], to target: Locale.Language) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let session = await obtainSession(target: target)
        let responses = try await session.translations(from: Self.makeRequests(for: texts))
        var byIndex: [Int: String] = [:]
        byIndex.reserveCapacity(responses.count)
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id) else { continue }
            byIndex[index] = response.targetText
        }
        guard byIndex.count == texts.count else {
            throw TranslationServiceError.failed(message: "translation response count mismatch (\(byIndex.count)/\(texts.count))")
        }
        return texts.indices.map { byIndex[$0] ?? "" }
    }

    /// `nonisolated`/`static`, deliberately: building `[TranslationSession
    /// .Request]` inside `translateBatch` itself (a main-actor-isolated
    /// method) made the region-isolation checker treat the array as tied to
    /// the main actor's region, which `session.translations(from:)` — an
    /// `@concurrent` method that hops off the main actor internally —
    /// rejected as an unsafe `sending` argument. Building the same array in
    /// a free-standing, non-actor-isolated function first (its input/output
    /// are both plain `Sendable` values — `String`s in, `Request`s out) sidesteps
    /// that region-isolation false positive entirely.
    private nonisolated static func makeRequests(for texts: [String]) -> [TranslationSession.Request] {
        texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
    }

    /// Apple's documented way to proactively trigger the system's language-
    /// download prompt — a no-op if `target`'s pack is already installed.
    /// `AppleTranslationService` calls this before every `translate`/
    /// `translateBatch` so a first-use download shows up as an explicit,
    /// visible OS flow rather than a confusing mid-translation failure (Task
    /// #159 point 3).
    public func prepareTranslation(to target: Locale.Language) async throws {
        let session = await obtainSession(target: target)
        try await session.prepareTranslation()
    }

    /// Returns the session for `target`, requesting source-language auto-
    /// detection — reused immediately (no suspension) if already current for
    /// this `target`; otherwise updates `configuration`, which causes
    /// SwiftUI to invoke the hosting view's `.translationTask` action with a
    /// fresh session shortly after, delivered back here via `attach(_:)`.
    private func obtainSession(target: Locale.Language) async -> TranslationSession {
        if let currentSession, currentTarget == target {
            return currentSession
        }
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
            pendingTarget = target
            configuration = TranslationSession.Configuration(source: nil, target: target)
        }
    }

    /// Called by `TranslationSessionHostView`'s `.translationTask` action
    /// closure with the session SwiftUI just created for whatever
    /// `configuration` this coordinator most recently set. Resolves every
    /// continuation currently queued for that target — ordinarily just one,
    /// but `translateBatch`/two messages opened in quick succession could
    /// enqueue a few before the first one resolves.
    public func attach(_ session: TranslationSession) {
        currentSession = session
        currentTarget = pendingTarget
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: session)
        }
    }
}
