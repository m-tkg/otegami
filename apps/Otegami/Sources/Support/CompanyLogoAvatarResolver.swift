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
/// **BIMI は実装していない — 意図的な判断**: 当初の指示は BIMI
/// (DNS TXT `default._bimi.<domain>` から SVG ロゴ URL を取得) を優先し、
/// 実装コストが見合わなければ favicon のみにして判断を報告する、という
/// ものだった。BIMI を見送った理由:
/// 1. **DNS TXT レコードの取得に、システムリゾルバを使う手頃な高レベル
///    API が Apple のプラットフォームに存在しない**。`URLSession`は
///    HTTP(S) 専用で DNS レコード種別を選べず、`Network`framework の
///    `NWConnection`も同様。唯一の経路は`dnssd`framework の
///    `DNSServiceQueryRecord`(C コールバック API、`<dns_sd.h>`) で、
///    これ自体はシステムリゾルバを使う正しい選択肢ではあるものの、
///    コールバック→Swift concurrency のブリッジ・タイムアウト処理・
///    `DNSServiceRef`のメモリ管理を新規に実装する必要があり、指示が
///    明示的に許容している「実装コストに見合わなければ見送る」の対象と
///    判断した (指示の代替案だった、サードパーティ DoH (`dns.google`
///    等) 経由の実装は、指示自身が「第三者への照会になる点に注意」と
///    明記しており、プライバシー方針上採用しない)。
/// 2. SVG の安全なラスタライズ (`WKWebView`を使わない、サイズ制限+単純な
///    SVG のみ) も別途実装が要る要素で、1と合わせて BIMI 全体の実装コスト
///    がこのバッチの他フェーズ (連絡先の写真・Gravatar) に対して不釣り
///    合いに大きいと判断した。
///
/// favicon フォールバックのみを実装する: `https://<domain>/apple-touch-icon.png`
/// → 失敗すれば`https://<domain>/favicon.ico`の順に試す。
public actor CompanyLogoAvatarResolver: AvatarImageResolving {
    private let session: URLSession
    private var memoryCache: [String: Data?] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let cacheDirectory: URL

    /// 30日 — favicon はユーザーの写真 (Gravatar, 7日) よりずっと変更
    /// 頻度が低いと考えられるため、長めの TTL にした。
    private let ttl: TimeInterval = 30 * 24 * 60 * 60

    public init(session: URLSession = .shared) {
        self.session = session
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
        let data = await fetchFavicon(domain: domain)
        memoryCache[domain] = data
        memoryCacheTimestamps[domain] = Date()
        writeDiskCache(domain: domain, data: data)
        return data
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
