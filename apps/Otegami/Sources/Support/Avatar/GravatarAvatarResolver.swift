import Foundation

/// アバター強化バッチ フェーズ2「Gravatar」: `AvatarImageResolving`の
/// 第2優先情報源 (連絡先の写真の次)。差出人メールアドレスを正規化して
/// SHA-256 ハッシュ化し、`https://gravatar.com/avatar/<hash>?d=404&s=160`
/// を取得する — `d=404`は「登録が無ければ 200 のデフォルト画像ではなく
/// 404 を返す」という Gravatar 側のオプションで、これにより「登録者不明の
/// 差出人にまで Gravatar のデフォルトシルエット画像を表示してしまう」誤り
/// を避けている。
///
/// **プライバシー上の注意 (設定画面にも同趣旨の注記あり)**: この情報源が
/// 有効な間、一覧に表示される差出人アドレスのハッシュは gravatar.com へ
/// 送信される。メールアドレス自体は送らない (SHA-256 は一方向関数) が、
/// gravatar.com 側はハッシュから元のアドレスを特定できる可能性がある
/// (総当たり/レインボーテーブル) ため、既定 ON ではあるが設定でいつでも
/// 無効化できるようにしてある。
public actor GravatarAvatarResolver: AvatarImageResolving {
    private let session: URLSession
    private var memoryCache: [String: Data?] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let cacheDirectory: URL

    /// 7日 — 「negative cache (無かった事実) も保持」の TTL。正の結果
    /// (写真が見つかった) にも同じ TTL を適用する: ユーザーが後から
    /// Gravatar に写真を設定/変更する可能性は正負どちらの向きにもあり、
    /// 片方だけ無期限キャッシュする理由が無いため。
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    public init(session: URLSession = .shared) {
        self.session = session
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("AvatarCache/Gravatar", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        guard AvatarSourceSettingsStore.isGravatarEnabled else { return nil }
        let key = Self.normalize(address)
        guard !key.isEmpty, key.contains("@") else { return nil }

        if let cachedAt = memoryCacheTimestamps[key], Date().timeIntervalSince(cachedAt) < ttl,
           let cached = memoryCache[key] {
            return cached
        }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadAndCache(key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Cache

    private func loadAndCache(key: String) async -> Data? {
        if let (data, cachedAt) = readDiskCache(key: key), Date().timeIntervalSince(cachedAt) < ttl {
            memoryCache[key] = data
            memoryCacheTimestamps[key] = cachedAt
            return data
        }
        switch await fetchFromGravatar(key: key) {
        case .found(let data):
            memoryCache[key] = data
            memoryCacheTimestamps[key] = Date()
            writeDiskCache(key: key, data: data)
            return data
        case .notFound:
            memoryCache[key] = nil
            memoryCacheTimestamps[key] = Date()
            writeDiskCache(key: key, data: nil)
            return nil
        case .unavailable:
            // ネットワークエラー/タイムアウト等 — 確定的な「無かった」では
            // ないので、negative cache に書かない (次回また試す)。今回の
            // 呼び出しに対しては `nil` (=イニシャルへフォールバック) を
            // 返すだけに留める — 一覧の描画をブロックしない、という要件を
            // 満たすには失敗を静かに諦めるほかない。
            return nil
        }
    }

    /// `.some((data, cachedAt))` = ディスクにキャッシュ済み (`data` が
    /// `nil` なら negative)。`nil` (外側) = そもそもキャッシュが無い。
    private func readDiskCache(key: String) -> (data: Data?, cachedAt: Date)? {
        let fileManager = FileManager.default
        let photoURL = photoFileURL(for: key)
        if let attrs = try? fileManager.attributesOfItem(atPath: photoURL.path),
           let cachedAt = attrs[.modificationDate] as? Date,
           let data = try? Data(contentsOf: photoURL) {
            return (data, cachedAt)
        }
        let noneURL = noPhotoMarkerURL(for: key)
        if let attrs = try? fileManager.attributesOfItem(atPath: noneURL.path),
           let cachedAt = attrs[.modificationDate] as? Date {
            return (nil, cachedAt)
        }
        return nil
    }

    private func writeDiskCache(key: String, data: Data?) {
        let fileManager = FileManager.default
        if let data {
            try? data.write(to: photoFileURL(for: key))
            try? fileManager.removeItem(at: noPhotoMarkerURL(for: key))
        } else {
            try? Data().write(to: noPhotoMarkerURL(for: key))
            try? fileManager.removeItem(at: photoFileURL(for: key))
        }
    }

    private func photoFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(AvatarCacheKey.sha256Hex(key) + ".jpg")
    }

    private func noPhotoMarkerURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(AvatarCacheKey.sha256Hex(key) + ".none")
    }

    // MARK: - Network

    private enum FetchResult {
        case found(Data)
        case notFound
        case unavailable
    }

    private func fetchFromGravatar(key: String) async -> FetchResult {
        guard let url = Self.gravatarURL(for: key) else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 200, !data.isEmpty { return .found(data) }
            if http.statusCode == 404 { return .notFound }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    /// アドレスを trim + 小文字化する — Gravatar のハッシュ仕様どおり
    /// (公式ドキュメントの例: `"  MyEmailAddress@example.com "` →
    /// `"myemailaddress@example.com"` してからハッシュ化する)。
    static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// - Parameter normalizedAddress: `normalize(_:)`済みの文字列を渡す
    ///   こと (この関数自身は正規化しない — `AvatarCacheKey.sha256Hex`と
    ///   同じ理由)。
    static func gravatarURL(for normalizedAddress: String) -> URL? {
        var components = URLComponents(string: "https://gravatar.com/avatar/\(AvatarCacheKey.sha256Hex(normalizedAddress))")
        components?.queryItems = [
            // `d=404`: 登録が無いアドレスにはデフォルトのシルエット画像
            // ではなく 404 を返させる (仕様どおり)。
            URLQueryItem(name: "d", value: "404"),
            URLQueryItem(name: "s", value: "160")
        ]
        return components?.url
    }
}
