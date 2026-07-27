import Foundation
import GoogleOAuth

/// Dependency `GoogleProfilePhotoAvatarResolver` needs to enumerate this
/// device's Gmail accounts and fetch a currently-valid access token for one.
/// `GmailAccessTokenBridge` (`AppEnvironment.swift`) is the only conformer —
/// a separate protocol (rather than depending on `AppEnvironment` directly)
/// exists because, like every other `AvatarImageResolving` source, this
/// resolver is constructed inside `AppEnvironment.init()` *before*
/// `AppEnvironment` itself is a usable value (Swift's two-phase init rule —
/// see `GmailAccessTokenBridge`'s own doc comment for how the real wiring
/// happens once `self` is fully initialized).
public protocol GmailAccessTokenProviding: Sendable {
    /// Every currently-known Gmail (`.gmail`-kind) account id, in account
    /// order. Empty if there are none, this build has no Gmail OAuth Client
    /// ID configured, or before the very first account-list observation has
    /// fired.
    func gmailAccountIds() async -> [String]
    /// A currently-valid access token for `accountId`, refreshing under the
    /// hood if needed — same contract as `AppEnvironment.auth(for:)`'s
    /// `.oauth2` branch. Throws if no token can be produced (missing/
    /// revoked refresh token, no `TokenStore` in this build, ...); the
    /// caller treats any failure the same way (skip this account).
    func accessToken(for accountId: String) async throws -> String
}

/// アバター強化バッチ「Google プロフィール写真」: `AvatarImageResolving`の
/// 第2優先情報源 (連絡先の写真の次、Gravatar の前 — Gmail の差出人については
/// Gmail 公式アプリと同じ情報源をまず試す、という判断)。
///
/// **Gmail アカウントが1つ以上あるユーザーだけがこの情報源の恩恵を受ける** —
/// `tokenProvider.gmailAccountIds()`が空を返せば (Gmail アカウント無し、
/// この端末のビルドに OAuth Client ID 未設定、等) 即座に`nil`。差出人ごとの
/// People API 問い合わせ自体は `GooglePeopleAvatarClient`
/// (`packages/OtegamiKit/Sources/GoogleOAuth/`) が担う — この型は「どの
/// Gmail アカウントのどのトークンで試すか」の順序付け、ディスク/メモリの
/// 2段キャッシュ、設定トグル、スコープ不足の記録だけを持つ。複数の Gmail
/// アカウントがある場合、成功するまで順に試し、最初に見つかったもので確定
/// する (`fetchFromGoogle`)。
///
/// **スコープ不足の扱い**: 新スコープ (`contacts.other.readonly`,
/// `GoogleOAuthEndpoints.scope`) 追加前に作成された既存 Gmail アカウントは、
/// 再認証するまでこのスコープを持たず、People API は 401/403 を返す
/// (`GooglePeopleAvatarClient`のドキュメントコメント参照)。そのアカウントの
/// トークンは「このプロセスの生存中はスコープ不足」と`scopeInsufficientAccountIds`
/// に記録し、以降の呼び出しでは People API に問い合わせずスキップする —
/// 一覧をスクロールするたびに同じアカウントへ 401 を連打しないため。**再
/// 認証を強制することはしない** — `AccountEditView`の案内からユーザー自身が
/// 選んで再接続する (`docs/oauth-setup.md`参照)。
public actor GoogleProfilePhotoAvatarResolver: AvatarImageResolving {
    private let client: GooglePeopleAvatarClient
    private let tokenProvider: any GmailAccessTokenProviding

    private var memoryCache: [String: Data?] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let cacheDirectory: URL

    /// プロセスの生存中だけ有効 (`AppEnvironment`は毎起動で作り直すので、
    /// 次回起動時にはもう一度試す — 再認証したのに次回起動まで永久に
    /// スキップされ続ける、ということは無い)。この型のドキュメントコメント
    /// の「スコープ不足の扱い」参照。
    ///
    /// 実機バグ修正: これに加えて `AppEnvironment.reauthenticateGmailAccount`
    /// が再認証成功時に `clearScopeInsufficientMemory(for:)` を呼び、この
    /// アカウント ID の記憶を即座に消す — 元々は「次回起動まで残る」仕様
    /// だったが、再認証した直後にまだ一覧を開いたままの画面がある場合、
    /// アプリを再起動しない限り新しい写真が出ないのは体験として不自然
    /// (再認証の成功メッセージと「まだ写真が出ない」が矛盾して見える)。
    private var scopeInsufficientAccountIds: Set<String> = []

    /// `otherContacts.search`のウォームアップ要求 (`GooglePeopleAvatarClient
    /// .warmupSearchIndex(accessToken:)`のドキュメントコメント参照) を
    /// 既に送ったアカウント ID の集合。プロセスの生存中、アカウントごとに
    /// 一度だけ送れば十分 — 同じアカウントのトークンで毎回ウォームアップを
    /// 送り直す必要はない。`scopeInsufficientAccountIds`と同じ理由で
    /// プロセス寿命限定 (次回起動でまた一度だけ送り直す)。
    private var warmedUpAccountIds: Set<String> = []

    /// Gravatar と同じ 7日 TTL (`GravatarAvatarResolver.ttl`のドキュメント
    /// コメントと同じ理由 — ユーザーが後から Google プロフィール写真を
    /// 変更する可能性はどちら向きにもある)。
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    public init(
        tokenProvider: any GmailAccessTokenProviding,
        client: GooglePeopleAvatarClient = GooglePeopleAvatarClient()
    ) {
        self.tokenProvider = tokenProvider
        self.client = client
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // 実機バグ修正: `v2` — 旧ディレクトリ (`AvatarCache/GoogleProfilePhoto`)
        // には、ウォームアップ要求を送っていなかった旧実装が書いた
        // `.notFound`の negative cache (7日 TTL, `ttl`) が残っている可能性が
        // ある。ウォームアップ追加後は同じ差出人でも結果が変わりうるため、
        // ディレクトリ名を変えて旧キャッシュを無条件に無効化する (世代が
        // 上がるたびにここを更新する想定)。旧ディレクトリは掃除しない —
        // 中身は`.jpg`/`.none`だけの数KB〜数十KB程度で、放置しても実害が
        // 無い一方、ここで消す処理を書くと「他の実装がまだ旧パスを使って
        // いないか」を毎回確認する負債になる。
        cacheDirectory = base.appendingPathComponent("AvatarCache/GoogleProfilePhoto/v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// `AppEnvironment.reauthenticateGmailAccount(_:)`が再認証成功直後に
    /// 呼ぶ — `scopeInsufficientAccountIds`のドキュメントコメント参照。
    /// 記録が無いアカウント ID を渡しても無害 (`Set.remove`は no-op)。
    public func clearScopeInsufficientMemory(for accountId: String) {
        scopeInsufficientAccountIds.remove(accountId)
    }

    public func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        guard AvatarSourceSettingsStore.isGoogleProfilePhotoEnabled else { return nil }
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        switch await fetchFromGoogle(address: key) {
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
            // Gravatar/企業ロゴと同じ理由: ネットワークエラー・Gmail
            // アカウント無し・全アカウントがスコープ不足、いずれも
            // 確定的な「無かった」ではないので negative cache に書かない。
            return nil
        }
    }

    private enum OverallResult {
        case found(Data)
        case notFound
        case unavailable
    }

    /// `tokenProvider.gmailAccountIds()`の順に (スコープ不足として記録済み
    /// のものはスキップして) 試し、最初に写真が見つかったアカウントで確定
    /// する。**1つも定義できるアカウントが無い場合と、試した全アカウントが
    /// 401/403 やネットワークエラーだった場合は`.unavailable`** — 少なくとも
    /// 1アカウントが「有効なトークンで問い合わせて、該当する人物が見つから
    /// なかった」という確定的な結果を返した場合だけ`.notFound`にする
    /// (`sawDefinitiveAttempt`)。
    private func fetchFromGoogle(address: String) async -> OverallResult {
        let accountIds = await tokenProvider.gmailAccountIds()
        guard !accountIds.isEmpty else { return .unavailable }

        var sawDefinitiveAttempt = false
        for accountId in accountIds {
            if scopeInsufficientAccountIds.contains(accountId) { continue }
            guard let accessToken = try? await tokenProvider.accessToken(for: accountId) else { continue }

            if !warmedUpAccountIds.contains(accountId) {
                // 順序が重要: ウォームアップの結果は無視し、成功しても
                // 失敗しても必ず本検索へ進む (`GooglePeopleAvatarClient
                // .warmupSearchIndex(accessToken:)`のドキュメントコメント
                // 参照)。`warmedUpAccountIds`への登録もここで行う —
                // ウォームアップ自体が失敗しても毎回送り直す意味は無い
                // (インデックスの温まりは "送ったこと" 自体が効くのであって、
                // 応答の成否とは無関係)。
                warmedUpAccountIds.insert(accountId)
                await client.warmupSearchIndex(accessToken: accessToken)
            }

            switch await client.lookupPhoto(accessToken: accessToken, address: address) {
            case .found(let photoURL):
                if let data = await client.downloadPhoto(url: photoURL) {
                    return .found(data)
                }
                // ダウンロード自体の失敗 (ネットワーク/空データ) — 同じ
                // 写真 URL を他のアカウントで試しても結果は変わらないはず
                // だが、少なくとも「見つからなかった」と負でキャッシュする
                // 根拠にもならない。次のアカウントがあれば試す。
            case .notFound:
                sawDefinitiveAttempt = true
            case .insufficientScope:
                scopeInsufficientAccountIds.insert(accountId)
            case .unavailable:
                break
            }
        }
        return sawDefinitiveAttempt ? .notFound : .unavailable
    }

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
}
