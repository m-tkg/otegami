import Foundation

/// Reads the M9 App Group id / Keychain Access Group out of Info.plist
/// (`OtegamiAppGroupIdentifier`/`OtegamiKeychainAccessGroup`, set from the
/// `OTEGAMI_APP_GROUP`/`OTEGAMI_KEYCHAIN_GROUP` xcconfig variables — see
/// `Config/Shared.xcconfig`'s doc comment). `Bundle.main` inside an app
/// extension is the extension's own bundle, not the containing app's, so
/// `NotificationService/NotificationService.swift` has its own
/// identically-named copy of this rather than importing this file (the two
/// targets don't share a `sources:` directory).
///
/// **App Group stays iOS-only despite Info.plist advertising it on every
/// platform** (M10 fix): `Config/Otegami-iOS.entitlements` is the only
/// entitlements file carrying `com.apple.security.application-groups` —
/// macOS has no `NotificationService` Extension to share a database file
/// with in the first place, M9's whole reason that capability exists.
/// Before the M10 fix, `AppEnvironment.init()` still read a non-`nil` App
/// Group identifier out of Info.plist on macOS and tried
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// against it anyway — which requires the entitlement to actually succeed,
/// entitlement or not, on modern macOS. Without one, the container
/// directory creation failed with `NSPOSIXErrorDomain Code=1 "Operation not
/// permitted"`, which `AppEnvironment.init()`'s `assertionFailure` on that
/// path turns into an immediate crash on every macOS launch — never caught
/// before M10 because macOS verification up to that point was `make mac`
/// (compiles) only, never an actual launch (docs/verify.md's M10 section).
/// Returning `nil` on macOS makes `AppDatabase.makeShared` fall back to its
/// pre-M9, non-shared default (plain Application Support) exactly as
/// already documented for "no App Group entitlement configured" builds.
///
/// **Keychain Access Group *is* shared with macOS** (実機バグ修正
/// 2026-07-29「mac では、iCloud で同期されたアカウントの認証が切れている
/// が再認証できない」— see `Otegami-macOS.entitlements`'s doc comment for
/// the full root-cause writeup): unlike the App Group above, this one isn't
/// only about `NotificationService` sharing — `KeychainCredentialStore`
/// (the app's `.password`-kind IMAP/SMTP credential store) uses whatever
/// this returns as `kSecAttrAccessGroup` on every Keychain query, and a
/// `nil` here means "macOS's implicit default access group," which is a
/// *different* group than iOS's explicit one — so a password Keychain item
/// iOS wrote (and iCloud Keychain genuinely synced down to the Mac) was
/// invisible to macOS's own queries, leaving password-kind accounts synced
/// from iOS permanently stuck on `needsReauth` there. Returning the same
/// non-`nil` group on both platforms fixes that; macOS now carries the
/// matching `keychain-access-groups` entitlement to make good on it.
enum OtegamiAppGroup {
    static var identifier: String? {
        #if os(macOS)
        return nil
        #else
        return Bundle.main.object(forInfoDictionaryKey: "OtegamiAppGroupIdentifier") as? String
        #endif
    }

    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiKeychainAccessGroup") as? String
    }
}
