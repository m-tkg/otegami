import Foundation
import MicrosoftOAuth

/// Mirrors `GoogleOAuthConfig` — reads `OTEGAMI_MICROSOFT_CLIENT_ID` from
/// `Info.plist` (itself expanded at build time from the
/// `OTEGAMI_MICROSOFT_CLIENT_ID` xcconfig build setting — `Config
/// /Shared.xcconfig` defines it empty by default; `Config/Local.xcconfig`,
/// git-ignored, is where a builder sets their own value — see
/// `docs/oauth-setup.md`'s Microsoft section). Same "OSS Client ID 問題"
/// rationale as Google's: otegami is OSS, so no Azure app registration
/// Client ID is checked into the repo.
enum MicrosoftOAuthConfig {
    /// `nil` when unset/empty — i.e. no `Local.xcconfig` override was ever
    /// provided.
    static var clientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_MICROSOFT_CLIENT_ID") as? String,
              !value.isEmpty,
              // Mirrors `GoogleOAuthConfig.clientId`'s identical guard — see
              // its doc comment for why an un-expanded `$(...)` placeholder
              // must be treated the same as "unset".
              !value.hasPrefix("$(")
        else {
            return nil
        }
        return value
    }

    static var isConfigured: Bool { clientId != nil }

    static var endpoints: MicrosoftOAuthEndpoints? {
        clientId.map { MicrosoftOAuthEndpoints.standard(clientId: $0) }
    }
}
