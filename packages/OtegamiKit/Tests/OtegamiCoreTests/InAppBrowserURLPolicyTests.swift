import Foundation
import Testing
@testable import OtegamiCore

/// Task #166 (SEC-A, F17): `MessageView`'s `OpenURLAction` used to pass
/// any `NSDataDetector`-linkified URL straight to `SFSafariViewController`
/// without checking its scheme, which throws on `init` for anything other
/// than http/https — see `InAppBrowserURLPolicy`'s doc comment.
@Suite("InAppBrowserURLPolicy")
struct InAppBrowserURLPolicyTests {
    @Test("http is supported")
    func httpSupported() {
        #expect(InAppBrowserURLPolicy.isSupported(URL(string: "http://example.com")!))
    }

    @Test("https is supported")
    func httpsSupported() {
        #expect(InAppBrowserURLPolicy.isSupported(URL(string: "https://example.com")!))
    }

    @Test("scheme comparison is case-insensitive")
    func caseInsensitive() {
        #expect(InAppBrowserURLPolicy.isSupported(URL(string: "HTTPS://example.com")!))
        #expect(InAppBrowserURLPolicy.isSupported(URL(string: "HtTp://example.com")!))
    }

    @Test("the F17 exploit scenario (a bare email address linkified to mailto:) is not supported")
    func mailtoNotSupported() {
        #expect(!InAppBrowserURLPolicy.isSupported(URL(string: "mailto:contact@example.test")!))
    }

    @Test("tel: is not supported")
    func telNotSupported() {
        #expect(!InAppBrowserURLPolicy.isSupported(URL(string: "tel:+15551234567")!))
    }

    @Test("a scheme-less URL is not supported")
    func schemeLessNotSupported() {
        #expect(!InAppBrowserURLPolicy.isSupported(URL(string: "/relative/path")!))
    }

    @Test("an arbitrary custom scheme is not supported")
    func customSchemeNotSupported() {
        #expect(!InAppBrowserURLPolicy.isSupported(URL(string: "otegami://open")!))
    }
}
