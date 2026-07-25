import Foundation

/// Whether a `TranslationService` can actually translate right now,
/// mirroring the shape of `FoundationModels.SystemLanguageModel
/// .Availability` (`SystemLanguageModel.default.availability`) without
/// leaking that Apple-only type through the protocol boundary — a
/// `FakeTranslationService` or some future non-Apple engine has no
/// `SystemLanguageModel.UnavailableReason` to report, only a reason of its
/// own.
public enum TranslationAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: TranslationUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Why a `TranslationService` reports `.unavailable`. Named to line up with
/// (but not `import`) `SystemLanguageModel.Availability.UnavailableReason`'s
/// three cases (`deviceNotEligible`/`appleIntelligenceNotEnabled`/
/// `modelNotReady`) — see `FoundationModelsTranslationService.availability`
/// for the mapping. `notSupported` covers everything outside that specific
/// enum (e.g. a hypothetical engine with no on-device model at all).
public enum TranslationUnavailableReason: Sendable, Equatable {
    /// The current device/OS can't run the on-device model at all (e.g.
    /// below the minimum RAM tier Apple Intelligence requires).
    case deviceNotEligible
    /// The device could support it, but the user hasn't turned Apple
    /// Intelligence on in Settings.
    case appleIntelligenceNotEnabled
    /// Eligible and enabled, but the on-device model assets haven't
    /// finished downloading yet.
    case modelNotReady
    /// Any other reason, carrying a short human-readable explanation —
    /// used by engines (including `FakeTranslationService`, when
    /// configured to simulate unavailability) that don't map onto the three
    /// cases above.
    case other(String)
}
