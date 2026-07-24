import Foundation
import GoogleOAuth

/// Reads `GOOGLE_OAUTH_CLIENT_ID` from `Info.plist` — itself expanded at
/// build time from the `GOOGLE_OAUTH_CLIENT_ID` xcconfig build setting
/// (`Config/Shared.xcconfig` defines it empty by default;
/// `Config/Local.xcconfig`, git-ignored, is where a builder sets their own
/// value — see `docs/oauth-setup.md`). Centralizes the "is Gmail even
/// available in this build" check so `AppEnvironment` and every Gmail-entry
/// UI (`AccountTypeSelectionView`'s Gmail button) ask the same question the
/// same way.
enum GoogleOAuthConfig {
    /// `nil` when unset/empty — i.e. no `Local.xcconfig` override was ever
    /// provided (the OSS-default state: plan's "OSS Client ID 問題", never
    /// checked into the repo).
    static var clientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_OAUTH_CLIENT_ID") as? String,
              !value.isEmpty,
              // xcodegen leaves the literal `$(GOOGLE_OAUTH_CLIENT_ID)`
              // placeholder in `Info.plist` un-expanded in a couple of edge
              // cases (e.g. a build system that doesn't run the variable
              // substitution build phase at all) — treat that the same as
              // "unset" rather than trying to use it as a real client id.
              !value.hasPrefix("$(")
        else {
            return nil
        }
        return value
    }

    static var isConfigured: Bool { clientId != nil }

    static var endpoints: GoogleOAuthEndpoints? {
        clientId.map { GoogleOAuthEndpoints.standard(clientId: $0) }
    }
}
