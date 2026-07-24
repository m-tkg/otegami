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
/// **iOS-only despite Info.plist advertising both keys on every platform**
/// (M10 fix): `Config/Otegami-iOS.entitlements` is, by design, the *only*
/// entitlements file in this project (`project.yml`'s
/// `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]`/`[sdk=iphonesimulator*]` —
/// there's no `[sdk=macosx*]` counterpart, since macOS has no
/// `NotificationService` Extension to share a database/Keychain item with
/// in the first place, M9's whole reason either capability exists). Before
/// this fix, `AppEnvironment.init()` still read a non-`nil` App Group
/// identifier out of Info.plist on macOS and tried
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
/// against it anyway — which requires the `com.apple.security
/// .application-groups` entitlement to actually succeed, entitlement or
/// not, on modern macOS. Without one, the container directory creation
/// failed with `NSPOSIXErrorDomain Code=1 "Operation not permitted"`, which
/// `AppEnvironment.init()`'s `assertionFailure` on that path turns into an
/// immediate crash on every macOS launch — never caught before M10 because
/// macOS verification up to this point was `make mac` (compiles) only,
/// never an actual launch (docs/verify.md's M10 section). Returning `nil`
/// on macOS makes `AppDatabase.makeShared`/`KeychainCredentialStore` fall
/// back to their pre-M9, non-shared defaults (plain Application Support /
/// no `kSecAttrAccessGroup`) exactly as already documented for "no App
/// Group entitlement configured" builds.
enum OtegamiAppGroup {
    static var identifier: String? {
        #if os(macOS)
        return nil
        #else
        return Bundle.main.object(forInfoDictionaryKey: "OtegamiAppGroupIdentifier") as? String
        #endif
    }

    static var keychainAccessGroup: String? {
        #if os(macOS)
        return nil
        #else
        return Bundle.main.object(forInfoDictionaryKey: "OtegamiKeychainAccessGroup") as? String
        #endif
    }
}
