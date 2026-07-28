import Foundation
import OtegamiRelayAPI
import Testing

@testable import PushRelayClient

@Suite("APNSEnvironmentDetector")
struct APNSEnvironmentDetectorTests {
    /// Builds fake "provisioning profile" bytes: an embedded XML plist
    /// (the only part the parser actually looks at) surrounded by
    /// arbitrary binary padding, standing in for the CMS/PKCS#7 signature
    /// wrapper a real provisioning profile has. `apsEnvironmentValue: nil`
    /// omits the `aps-environment` key entirely (some profile types, like a
    /// plain iOS Development profile with no push capability configured,
    /// don't include it).
    private func provisioningProfileData(apsEnvironmentValue: String?) -> Data {
        let entitlementsEntry = apsEnvironmentValue.map {
            "<key>aps-environment</key><string>\($0)</string>"
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>Otegami</string>
            <key>Entitlements</key>
            <dict>
                \(entitlementsEntry)
                <key>keychain-access-groups</key>
                <array>
                    <string>ABCDE12345.jp.mtkg.otegami</string>
                </array>
            </dict>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x82, 0x0A, 0x00, 0xFF, 0x01, 0x02]) // fake DER/CMS prefix
        data.append(plist.data(using: .utf8)!)
        data.append(Data([0x00, 0xDE, 0xAD, 0xBE, 0xEF])) // fake signature suffix
        return data
    }

    @Test("development aps-environment maps to .sandbox")
    func development() {
        let data = provisioningProfileData(apsEnvironmentValue: "development")
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == .sandbox)
    }

    @Test("production aps-environment maps to .production")
    func production() {
        let data = provisioningProfileData(apsEnvironmentValue: "production")
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == .production)
    }

    @Test("missing aps-environment entitlement returns nil")
    func missingEntitlement() {
        let data = provisioningProfileData(apsEnvironmentValue: nil)
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == nil)
    }

    @Test("unrecognized aps-environment value returns nil")
    func unrecognizedValue() {
        let data = provisioningProfileData(apsEnvironmentValue: "carrier-pigeon")
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == nil)
    }

    @Test("no embedded plist at all returns nil")
    func noPlist() {
        let data = Data([0x30, 0x82, 0x0A, 0x00, 0xFF, 0x01, 0x02, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == nil)
    }

    @Test("empty data returns nil")
    func emptyData() {
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: Data()) == nil)
    }

    @Test("truncated plist (no closing </plist>) returns nil")
    func truncatedPlist() {
        var data = Data([0x30, 0x82])
        data.append("<?xml version=\"1.0\"?><plist><dict>".data(using: .utf8)!)
        #expect(APNSEnvironmentDetector.environment(fromProvisioningProfileData: data) == nil)
    }

    @Test("detectedEnvironment(bundle:) falls back to .production when the bundle has no embedded.mobileprovision")
    func detectedEnvironmentFallback() {
        // The xctest runner's own main bundle never ships an
        // embedded.mobileprovision (that's an artifact of an iOS app
        // bundle, not a test executable) — this exercises exactly the
        // "no provisioning profile found" path that a real TestFlight/App
        // Store build hits too, and both should resolve to `.production`.
        #expect(APNSEnvironmentDetector.detectedEnvironment(bundle: .main) == .production)
    }
}
