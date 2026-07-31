import BIMI
import Foundation
import OtegamiCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// アバター強化バッチ フェーズ3「企業ロゴ (BIMI → favicon)」:
/// `AvatarImageResolving`の第3優先情報源 (連絡先の写真・Gravatar の次)。
///
/// **Task #42 での方針転換 — BIMI を実装する**: このコメントは以前
/// 「BIMI は実装していない — 意図的な判断」として、Apple プラットフォーム
/// に DNS TXT レコード取得の手頃な高レベル API が無いこと、およびサード
/// パーティ DoH (`dns.google`等) 経由の実装は「第三者への照会になる」
/// という理由で favicon のみに絞ったことを記録していた。Task #42 の指示は
/// この判断を明示的に覆し、DoH (`https://dns.google/resolve`) 経由の BIMI
/// 実装を指定している — プライバシー上のトレードオフ (BIMI 判定のたびに
/// Google の DoH エンドポイントへドメイン名を送る) を認識した上での、この
/// バッチの作者による意図的な再選択であり、`docs/design-system.md`の
/// BIMI 節にもこの転換を記録済み。
///
/// - DNS TXT 取得: `BIMIRecordClient`(`packages/OtegamiKit/Sources/BIMI/`)
///   が`default._bimi.<domain>`を DoH 経由で引き、`v=BIMI1; l=<SVG URL>`
///   から SVG URL を取得する。
/// - SVG の安全性: `BIMISVGSafety.isSafe(_:)`が`<script>`・外部参照・
///   イベントハンドラ属性・サイズ上限 (64KB) を検証してから初めて
///   `BIMISVGParser`(安全な subset のみをサポート、それ以外は fail closed
///   で拒否) がパースする。ラスタライズは`BIMISVGRenderer`
///   (`CoreGraphics`、この型のみが Apple-only) が担う — `WKWebView`は
///   使わない (指示どおり)。
/// - BIMI が見つからない/安全でない/パースできない場合は、既存の favicon
///   フォールバック (`https://<domain>/apple-touch-icon.png` →
///   `https://<domain>/favicon.ico`) にそのまま委ねる。
public actor CompanyLogoAvatarResolver: AvatarImageResolving {
    private let session: URLSession
    private let bimiClient: BIMIRecordClient
    private var memoryCache: [String: Data?] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let cacheDirectory: URL

    /// 30日 — favicon/BIMI ロゴはユーザーの写真 (Gravatar, 7日) よりずっと
    /// 変更頻度が低いと考えられるため、長めの TTL にした。BIMI・favicon
    /// どちらから得たロゴも同じキー (ドメイン単位) の同じキャッシュに載る
    /// — 「このドメインの企業ロゴ」という1つの概念に対して情報源が2つ
    /// あるだけなので、二重キャッシュは不要と判断した。
    private let ttl: TimeInterval = 30 * 24 * 60 * 60

    /// `BIMISVGRenderer.render(_:pixelSize:)`に渡すラスタライズ後の一辺の
    /// ピクセル数。`GooglePeopleAvatarClient.sizedPhotoURL(_:)`の`=s160`と
    /// 同じ160を採用 — アバター表示サイズ (~30pt) の Retina 3x を超える
    /// 余裕を持たせつつ、無駄に大きくしない値。
    private static let bimiRenderedPixelSize = 160

    public init(session: URLSession = .shared) {
        self.session = session
        self.bimiClient = BIMIRecordClient(session: session)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("AvatarCache/CompanyLogo", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        guard AvatarSourceSettingsStore.isCompanyLogoEnabled else { return nil }
        guard let domain = Self.domain(from: address), FreeMailDomains.isEligibleForCompanyLogo(domain: domain) else {
            // gmail.com 等のフリーメールドメインは、企業ロゴ解決の対象外
            // ネットワークにすら問い合わせない (`FreeMailDomains`のドキュメント
            // コメント参照)。
            return nil
        }

        // キャッシュキーはメールアドレスではなく**ドメイン単位** —
        // 同じ会社の複数の差出人 (alice@acme.com / bob@acme.com) が同じ
        // favicon を共有できるようにする、という指示どおりの設計。
        if let cachedAt = memoryCacheTimestamps[domain], Date().timeIntervalSince(cachedAt) < ttl,
           let cached = memoryCache[domain] {
            return cached
        }
        if let existing = inFlight[domain] { return await existing.value }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadAndCache(domain: domain)
        }
        inFlight[domain] = task
        let result = await task.value
        inFlight[domain] = nil
        return result
    }

    // MARK: - Cache

    private func loadAndCache(domain: String) async -> Data? {
        if let (data, cachedAt) = readDiskCache(domain: domain), Date().timeIntervalSince(cachedAt) < ttl {
            memoryCache[domain] = data
            memoryCacheTimestamps[domain] = cachedAt
            return data
        }
        let data = await fetchCompanyLogo(domain: domain)
        memoryCache[domain] = data
        memoryCacheTimestamps[domain] = Date()
        writeDiskCache(domain: domain, data: data)
        return data
    }

    /// BIMI を favicon より先に試す (指示どおり) — 見つからない・安全で
    /// ない・パースできないのいずれであっても、`fetchFavicon`へ静かに
    /// フォールバックする (BIMI 側の失敗をエラーとしてこの型の外へ
    /// 伝える必要は無い — `AvatarImageResolving`の契約どおり「この情報源
    /// では出せなかった」を表すだけ)。
    private func fetchCompanyLogo(domain: String) async -> Data? {
        if let bimiLogo = await fetchBIMILogo(domain: domain) {
            return bimiLogo
        }
        return await fetchFavicon(domain: domain)
    }

    private func fetchBIMILogo(domain: String) async -> Data? {
        guard case .found(let svgURL) = await bimiClient.resolveLogoURL(domain: domain) else { return nil }

        var request = URLRequest(url: svgURL)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
              data.count <= BIMISVGSafety.maxByteSize
        else { return nil }

        // セキュリティ必須: 安全性検証 → パース → ラスタライズの順で、
        // どの段階が失敗しても`nil`を返し favicon へフォールバックする
        // (`BIMISVGSafety`/`BIMISVGParser`両方のドキュメントコメント参照
        // — 「わからないものは描かない」fail-closed の設計)。
        guard BIMISVGSafety.isSafe(data) else { return nil }
        guard let vectorImage = BIMISVGParser.parse(data) else { return nil }
        return BIMISVGRenderer.render(vectorImage, pixelSize: Self.bimiRenderedPixelSize)
    }

    private func readDiskCache(domain: String) -> (data: Data?, cachedAt: Date)? {
        let fileManager = FileManager.default
        let photoURL = logoFileURL(for: domain)
        if let attrs = try? fileManager.attributesOfItem(atPath: photoURL.path),
           let cachedAt = attrs[.modificationDate] as? Date,
           let data = try? Data(contentsOf: photoURL) {
            return (data, cachedAt)
        }
        let noneURL = noLogoMarkerURL(for: domain)
        if let attrs = try? fileManager.attributesOfItem(atPath: noneURL.path),
           let cachedAt = attrs[.modificationDate] as? Date {
            return (nil, cachedAt)
        }
        return nil
    }

    private func writeDiskCache(domain: String, data: Data?) {
        let fileManager = FileManager.default
        if let data {
            try? data.write(to: logoFileURL(for: domain))
            try? fileManager.removeItem(at: noLogoMarkerURL(for: domain))
        } else {
            try? Data().write(to: noLogoMarkerURL(for: domain))
            try? fileManager.removeItem(at: logoFileURL(for: domain))
        }
    }

    private func logoFileURL(for domain: String) -> URL {
        cacheDirectory.appendingPathComponent(AvatarCacheKey.sha256Hex(domain) + ".img")
    }

    private func noLogoMarkerURL(for domain: String) -> URL {
        cacheDirectory.appendingPathComponent(AvatarCacheKey.sha256Hex(domain) + ".none")
    }

    // MARK: - Network

    /// `apple-touch-icon.png`→`favicon.ico`の順に試し、**デコードできる
    /// 画像データが得られた最初のもの**を返す — 特に`favicon.ico`は真の
    /// マルチ解像度 ICO 形式で配信されることがあり、`UIImage`/`NSImage`が
    /// デコードできない場合がある (実際には PNG を`.ico`拡張子で配信する
    /// サイトも多いが、保証は無い)。デコード不能なバイト列を「見つかった」
    /// として negative cache を汚さないよう、ここで一度デコード検証してから
    /// 結果を確定する。
    private func fetchFavicon(domain: String) async -> Data? {
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "https://\(domain)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  !data.isEmpty,
                  Self.isDecodableImage(data)
            else { continue }
            return data
        }
        return nil
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        #if canImport(UIKit)
        return UIImage(data: data) != nil
        #elseif canImport(AppKit)
        return NSImage(data: data) != nil
        #else
        return false
        #endif
    }

    /// `address`の`@`以降を小文字化して返す。複数の`@`を含む不正な
    /// アドレスや`@`が無いアドレスは`nil`。
    static func domain(from address: String) -> String? {
        let parts = address.split(separator: "@")
        guard parts.count == 2, let domain = parts.last, !domain.isEmpty else { return nil }
        return String(domain).lowercased()
    }
}
