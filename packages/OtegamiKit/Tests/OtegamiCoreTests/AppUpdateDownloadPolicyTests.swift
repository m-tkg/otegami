import Foundation
import Testing
@testable import OtegamiCore

/// Task #182 (macOS アプリ内アップデート): covers the host allowlist a
/// release-asset download (and every redirect hop it follows) must stay
/// inside — see `AppUpdateDownloadPolicy`'s doc comment.
struct AppUpdateDownloadPolicyTests {
    @Test("allows the initial GitHub API/web hosts")
    func allowsGitHubHosts() {
        #expect(AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://github.com/m-tkg/otegami/releases/download/v1.2.0/Otegami.zip")!))
        #expect(AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://api.github.com/repos/m-tkg/otegami/releases")!))
    }

    @Test("allows a githubusercontent.com redirect target regardless of subdomain")
    func allowsGithubusercontentRedirect() {
        #expect(AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://objects.githubusercontent.com/some-signed-path")!))
        #expect(AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://release-assets.githubusercontent.com/some-signed-path")!))
    }

    @Test("rejects an unrelated host even if it contains 'github'")
    func rejectsLookalikeHost() {
        #expect(!AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://github.com.evil.example/Otegami.zip")!))
        #expect(!AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://evilgithubusercontent.com/Otegami.zip")!))
        #expect(!AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://notgithubusercontent.com/Otegami.zip")!))
    }

    @Test("rejects the bare githubusercontent.com apex with no subdomain")
    func rejectsBareApexDomain() {
        #expect(!AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "https://githubusercontent.com/Otegami.zip")!))
    }

    @Test("rejects a downgraded http scheme even on an allowed host")
    func rejectsHTTPScheme() {
        #expect(!AppUpdateDownloadPolicy.isAllowedDownloadURL(URL(string: "http://github.com/m-tkg/otegami/releases/download/v1.2.0/Otegami.zip")!))
    }

    @Test("rejects a URL with no host at all")
    func rejectsNoHost() {
        #expect(!AppUpdateDownloadPolicy.isAllowedHost(nil))
        #expect(!AppUpdateDownloadPolicy.isAllowedHost(""))
    }

    @Test("host comparison is case-insensitive")
    func isCaseInsensitive() {
        #expect(AppUpdateDownloadPolicy.isAllowedHost("GitHub.com"))
        #expect(AppUpdateDownloadPolicy.isAllowedHost("OBJECTS.GITHUBUSERCONTENT.COM"))
    }
}
