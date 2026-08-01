import Foundation
import XCTest
@testable import Otegami

final class GoogleProfilePhotoAvatarResolverTests: XCTestCase {
    func testSuccessfulReauthenticationClearsNegativeAddressCache() async throws {
        let address = "avatar-negative-cache-\(UUID().uuidString)@example.com"
        let cacheDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        .appendingPathComponent("AvatarCache/GoogleProfilePhoto/v3", isDirectory: true)
        let markerURL = cacheDirectory
            .appendingPathComponent(AvatarCacheKey.sha256Hex(address) + ".none")

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data().write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let resolver = GoogleProfilePhotoAvatarResolver(tokenProvider: UnusedGmailAccessTokenProvider())
        await resolver.clearScopeInsufficientMemory(for: "gmail-account")

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
}

private struct UnusedGmailAccessTokenProvider: GmailAccessTokenProviding {
    func gmailAccountIds() async -> [String] { [] }

    func accessToken(for accountId: String) async throws -> String {
        throw UnusedError()
    }

    private struct UnusedError: Error {}
}
