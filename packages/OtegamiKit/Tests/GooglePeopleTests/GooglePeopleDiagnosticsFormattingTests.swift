import Foundation
import Testing
@testable import GooglePeople

@Suite("GooglePeopleDiagnosticsFormatting")
struct GooglePeopleDiagnosticsFormattingTests {
    @Test
    func maskEmailAddressesRedactsTheLocalPartButKeepsTheDomain() {
        let masked = GooglePeopleDiagnosticsFormatting.maskEmailAddresses(in: "error for someone@example.com: PERMISSION_DENIED")
        #expect(masked == "error for ***@example.com: PERMISSION_DENIED")
    }

    @Test
    func maskEmailAddressesHandlesMultipleAddresses() {
        let masked = GooglePeopleDiagnosticsFormatting.maskEmailAddresses(in: "a@example.com and b@sample.org both failed")
        #expect(masked == "***@example.com and ***@sample.org both failed")
    }

    @Test
    func maskEmailAddressesLeavesTextWithoutAnAddressUnchanged() {
        let masked = GooglePeopleDiagnosticsFormatting.maskEmailAddresses(in: "PERMISSION_DENIED: insufficient scope")
        #expect(masked == "PERMISSION_DENIED: insufficient scope")
    }
}
