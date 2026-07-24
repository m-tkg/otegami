import Foundation

/// Reads the M9 App Group id / Keychain Access Group out of Info.plist
/// (`OtegamiAppGroupIdentifier`/`OtegamiKeychainAccessGroup`, set from the
/// `OTEGAMI_APP_GROUP`/`OTEGAMI_KEYCHAIN_GROUP` xcconfig variables — see
/// `Config/Shared.xcconfig`'s doc comment). `Bundle.main` inside an app
/// extension is the extension's own bundle, not the containing app's, so
/// `NotificationService/NotificationService.swift` has its own
/// identically-named copy of this rather than importing this file (the two
/// targets don't share a `sources:` directory).
enum OtegamiAppGroup {
    static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiAppGroupIdentifier") as? String
    }

    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiKeychainAccessGroup") as? String
    }
}
