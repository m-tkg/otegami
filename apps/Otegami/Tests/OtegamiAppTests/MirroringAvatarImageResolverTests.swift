import CoreGraphics
import Foundation
import ImageIO
import PushRelayClient
import UniformTypeIdentifiers
import XCTest
@testable import Otegami

/// `MirroringAvatarImageResolver` (`SharedAvatarCacheWriter.swift`) —
/// `SharedAvatarStore(directory:)`にテンポラリディレクトリを渡し、実際の
/// App Group コンテナに触れずに「base への委譲」「ミラー書き込み」
/// 「TTL 内の再書き込みスキップ」「128×128 への正規化」を検証する。
final class MirroringAvatarImageResolverTests: XCTestCase {
    private func makeTemporaryStore() -> (store: SharedAvatarStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirroringAvatarImageResolverTests-\(UUID().uuidString)", isDirectory: true)
        return (SharedAvatarStore(directory: directory), directory)
    }

    func testBaseReturningNilDoesNotMirror() async throws {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = MirroringAvatarImageResolver(wrapping: StubAvatarImageResolver(result: nil), store: store)

        let result = await resolver.resolveAvatarImageData(displayName: nil, address: "nobody@example.com")

        XCTAssertNil(result)
        XCTAssertNil(store.imageURL(for: "nobody@example.com"))
    }

    func testBaseReturningDataMirrorsNormalizedPNGAndReturnsBaseValueUnchanged() async throws {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 正方形でない元画像 (40×80) — aspect-fill センタークロップが実際に
        // 効いていることを128×128という出力サイズで確認する。
        let sourceData = try XCTUnwrap(Self.makeTestImageData(width: 40, height: 80))
        let resolver = MirroringAvatarImageResolver(wrapping: StubAvatarImageResolver(result: sourceData), store: store)

        let result = await resolver.resolveAvatarImageData(displayName: "Someone", address: "mirror@example.com")

        // base の戻り値 (正規化前の生データ) がそのまま返る — ミラー処理は
        // 呼び出し元への戻り値に一切影響しない、という契約の確認。
        XCTAssertEqual(result, sourceData)

        let mirroredURL = try XCTUnwrap(store.imageURL(for: "mirror@example.com"))
        let mirroredData = try Data(contentsOf: mirroredURL)
        let size = try XCTUnwrap(Self.decodedPixelSize(of: mirroredData))
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
    }

    func testExistingFreshEntryIsNotRewritten() async throws {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = "stable@example.com"
        let firstSourceData = try XCTUnwrap(Self.makeTestImageData(width: 60, height: 60))
        let firstResolver = MirroringAvatarImageResolver(wrapping: StubAvatarImageResolver(result: firstSourceData), store: store)
        _ = await firstResolver.resolveAvatarImageData(displayName: nil, address: address)

        let mirroredURL = try XCTUnwrap(store.imageURL(for: address))
        let originalContents = try Data(contentsOf: mirroredURL)
        let originalModificationDate = try XCTUnwrap(Self.modificationDate(of: mirroredURL))

        // 2回目の解決要求 — 前回と異なる画像を base が返しても、既存
        // エントリが TTL 内なら書き直されないはず (`SenderAvatar`が
        // スクロールのたびに`.task`から解決要求を出すのに毎回 PNG を
        // 再エンコード/再書き込みするのは無駄、という型のドキュメント
        // コメント参照)。
        let secondSourceData = try XCTUnwrap(Self.makeTestImageData(width: 60, height: 60, color: (0, 0, 1)))
        let secondResolver = MirroringAvatarImageResolver(wrapping: StubAvatarImageResolver(result: secondSourceData), store: store)
        let secondResult = await secondResolver.resolveAvatarImageData(displayName: nil, address: address)

        XCTAssertEqual(secondResult, secondSourceData)
        let unchangedContents = try Data(contentsOf: mirroredURL)
        let unchangedModificationDate = try XCTUnwrap(Self.modificationDate(of: mirroredURL))
        XCTAssertEqual(unchangedContents, originalContents)
        XCTAssertEqual(unchangedModificationDate, originalModificationDate)
    }

    // MARK: - Fixtures

    /// テスト用の単色画像を PNG として生成する。`UIImage`/`NSImage`に
    /// 依存せず`CoreGraphics`/`ImageIO`だけで完結させる — 検証側の
    /// `decodedPixelSize(of:)`と対称。
    private static func makeTestImageData(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return pngData(from: image)
    }

    private static func decodedPixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private struct StubAvatarImageResolver: AvatarImageResolving {
    let result: Data?

    func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        result
    }
}
