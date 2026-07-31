import Foundation
import OtegamiRelayAPI

/// Determines which APNs environment (`RegisterDeviceRequest.Environment`)
/// *this running binary* was signed for, by reading the `aps-environment`
/// entitlement out of its embedded provisioning profile — the same
/// technique widely used elsewhere (e.g. Firebase's `FIRMessaging`) since
/// there's no public API that reports it directly.
///
/// Why this matters: a Debug/Ad Hoc build is always signed against a
/// Development provisioning profile (`aps-environment: development`,
/// routes to `api.sandbox.push.apple.com`), while a TestFlight/App Store
/// build is Distribution-signed (`aps-environment: production`, routes to
/// `api.push.apple.com`). `AppEnvironment.enablePushNotifications` used to
/// hardcode `.sandbox` for every build, which silently broke push once a
/// TestFlight build's device token got registered against the relay's
/// sandbox APNs client. The relay already dispatches per-device on
/// `environment`, so only the value sent by the app needed to change.
///
/// iOS-only in practice: `AppEnvironment.requestAPNsToken()` throws
/// `PushError.unsupportedPlatform` on macOS before this detector would ever
/// be consulted (push notifications aren't implemented on macOS at all —
/// see `Otegami-macOS.entitlements`'s doc comment), so this type is never
/// exercised there. It still needs to type-check when the same
/// `AppEnvironment.swift` call sites are compiled into the macOS target,
/// which `detectedEnvironment(bundle:)` does unconditionally — on macOS,
/// `Bundle.main` has no `embedded.mobileprovision` (that's an iOS/tvOS/
/// watchOS artifact; a Mac App Store build's equivalent is
/// `Contents/embedded.provisionprofile`, a Developer ID build has neither),
/// so it harmlessly falls through to the same "absent -> production"
/// default as an App Store build — never actually reached at runtime.
public enum APNSEnvironmentDetector {
    /// Returns the APNs environment this binary is signed for, or
    /// `.production` if no embedded provisioning profile could be found or
    /// parsed. That default matters: App Store/TestFlight distribution
    /// strips (or never embeds, depending on the distribution path)
    /// `embedded.mobileprovision`, so "no provisioning profile" is itself
    /// the signal for "this is a production build" rather than an error
    /// condition — the one case where a profile is legitimately absent
    /// (Debug builds always embed one) is exactly the case that should
    /// resolve to `.production` anyway.
    public static func detectedEnvironment(bundle: Bundle = .main) -> RegisterDeviceRequest.Environment {
        guard
            let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let environment = environment(fromProvisioningProfileData: data)
        else {
            return .production
        }
        return environment
    }

    /// Parses the `aps-environment` entitlement out of raw provisioning
    /// profile bytes. A provisioning profile is a CMS/PKCS#7-signed blob,
    /// not a bare property list, but it always contains exactly one
    /// embedded `<?xml ... </plist>` document (the signed payload) — this
    /// extracts that substring directly rather than pulling in a CMS/ASN.1
    /// parser just to unwrap it, the same shortcut this technique commonly
    /// takes. Returns `nil` if the data doesn't contain a well-formed
    /// embedded plist, the plist has no `Entitlements.aps-environment` key,
    /// or that key isn't one of the two values Apple documents
    /// ("development"/"production") — every `nil` case is treated by
    /// `detectedEnvironment(bundle:)` as "couldn't determine it, assume
    /// production" rather than crashing or throwing.
    static func environment(fromProvisioningProfileData data: Data) -> RegisterDeviceRequest.Environment? {
        guard
            let xmlStart = "<?xml".data(using: .utf8),
            let plistEnd = "</plist>".data(using: .utf8),
            let startRange = data.range(of: xmlStart),
            let endRange = data.range(of: plistEnd, in: startRange.upperBound..<data.endIndex)
        else {
            return nil
        }
        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)

        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
            let plistDictionary = plist as? [String: Any],
            let entitlements = plistDictionary["Entitlements"] as? [String: Any],
            let apsEnvironment = entitlements["aps-environment"] as? String
        else {
            return nil
        }

        switch apsEnvironment {
        case "development":
            return .sandbox
        case "production":
            return .production
        default:
            return nil
        }
    }
}
