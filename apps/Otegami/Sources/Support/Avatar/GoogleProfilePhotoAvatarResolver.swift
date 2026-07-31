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
/// この端末のビルドに OAuth Client ID 未設定、等) 即座に`nil`。
///
/// **索引方式 (`otherContacts.search`の逐次問い合わせから変更)**: 差出人
/// アドレスごとに People API へ問い合わせていた旧実装は (a)
/// `otherContacts.search`が`sources`パラメータを持たず PROFILE 由来の写真
/// (Gmail 自身が使っている情報源) を取得できない、(b) 保存済み連絡先
/// (`otherContacts`に含まれない) をそもそもカバーできない、という2つの
/// 欠落があった。この型は代わりに、Gmail アカウントごとに
/// `GooglePeopleAvatarClient.fetchOtherContactsPhotoIndex(accessToken:)`
/// (other contacts) と `.fetchConnectionsPhotoIndex(accessToken:)`
/// (保存済み連絡先、要`contacts.readonly`スコープ) の2つの全件走査結果を
/// マージした (メールアドレス → 写真 URL) の索引を1日1回程度構築し、
/// メモリ/ディスクにキャッシュする (`ensureIndex(for:)`)。個々の差出人の
/// 解決 (`resolveAvatarImageData`) はこの索引を引くだけで、People API への
/// 追加のネットワーク問い合わせを伴わない — 一覧をスクロールするたびに
/// 送信元アドレスの数だけ API を叩いていた旧実装と違い、索引の TTL
/// (`indexTTL`) が切れるまでは何百通スクロールしても新規リクエストは0件。
///
/// **スコープ不足の扱い**: `otherContacts.readonly`/`contacts.readonly`
/// (`GoogleOAuthEndpoints.scope`) いずれも、追加前に作成された既存 Gmail
/// アカウントは再認証するまで持たず、People API はそれぞれ独立に 401/403
/// を返しうる (`GooglePeopleAvatarClient`のドキュメントコメント参照)。
/// **2つのスコープは別々に記録・スキップする**
/// (`otherContactsScopeInsufficientAccountIds`/
/// `connectionsScopeInsufficientAccountIds`) — 例えば
/// `contacts.other.readonly`は既に許可済みだが`contacts.readonly`は未許可
/// (このバッチでスコープを追加した直後によくある状態) というアカウントで
/// も、許可済みの方の情報源だけは使い続けられる。**再認証を強制することは
/// しない** — `AccountEditView`の案内からユーザー自身が選んで再接続する
/// (`docs/oauth-setup.md`参照)。
public actor GoogleProfilePhotoAvatarResolver: AvatarImageResolving {
    private let client: GooglePeopleAvatarClient
    private let tokenProvider: any GmailAccessTokenProviding

    // MARK: - Per-address photo byte cache (2段: メモリ→ディスク)

    private var memoryCache: [String: Data?] = [:]
    private var memoryCacheTimestamps: [String: Date] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let cacheDirectory: URL

    /// Gravatar と同じ 7日 TTL (`GravatarAvatarResolver.ttl`のドキュメント
    /// コメントと同じ理由 — ユーザーが後から Google プロフィール写真を
    /// 変更する可能性はどちら向きにもある)。索引自体の鮮度は別途`indexTTL`
    /// が管理するので、この TTL は「ダウンロード済みの画像バイト列を
    /// いつまで使い回すか」の意味に限定される。
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Per-account index cache (アカウントごとの索引)

    /// アカウント ID → 直近に構築した索引 + 構築時刻。プロセスの生存中
    /// (`AppEnvironment`は毎起動で作り直す) と `indexTTL` 以内はメモリの
    /// 値をそのまま返す — ディスクキャッシュ (`readIndexDiskCache`)
    /// はプロセス再起動をまたいでこの鮮度を引き継ぐためのもの。
    private var accountIndexState: [String: (index: [String: URL], fetchedAt: Date)] = [:]
    private var indexFetchTasks: [String: Task<[String: URL]?, Never>] = [:]

    /// 索引を「1日1回程度」構築し直す (プランの指示どおり)。写真バイト列
    /// 自体の`ttl` (7日) より短いのは、索引の構築コスト (最大`maxPages`
    /// ページの全件走査) が「その日のうちに新しく増えた other contacts /
    /// 連絡先」を拾うにはこのくらいの頻度が妥当と判断したため。
    private let indexTTL: TimeInterval = 24 * 60 * 60

    /// プロセスの生存中だけ有効 — `otherContacts`側のスコープ不足の記録。
    /// `AppEnvironment.reauthenticateGmailAccount`が再認証成功時に
    /// `clearScopeInsufficientMemory(for:)` を呼び、このアカウント ID の
    /// 記憶を索引キャッシュごと即座に消す — 再認証した直後にまだ一覧を
    /// 開いたままの画面がある場合、アプリを再起動しない限り新しい写真が
    /// 出ないのは体験として不自然なため。
    private var otherContactsScopeInsufficientAccountIds: Set<String> = []
    /// 上と同じ役割の、`connections` (保存済み連絡先、`contacts.readonly`)
    /// 側のスコープ不足の記録。
    private var connectionsScopeInsufficientAccountIds: Set<String> = []
    /// Task #42「自分のプロフィール写真」: `people/me`側のスコープ不足の
    /// 記録。理論上`otherContacts`と同じスコープ (`contacts.other.readonly`)
    /// で読める見込みが高い (`GooglePeopleAvatarClient
    /// .fetchSelfPhotoIndexOutcome`のドキュメントコメント参照) が、Google
    /// 側が将来別の扱いをする可能性に備えて独立に記録・スキップする —
    /// 既存2スコープと同じパターン。
    private var selfScopeInsufficientAccountIds: Set<String> = []

    public init(
        tokenProvider: any GmailAccessTokenProviding,
        client: GooglePeopleAvatarClient = GooglePeopleAvatarClient()
    ) {
        self.tokenProvider = tokenProvider
        self.client = client
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // `v3`: `otherContacts.search`の逐次問い合わせから索引方式へ書き
        // 換えた際に上げた世代。旧`v2`ディレクトリには (a) 旧`.search`
        // ベースの negative cache (`.none`マーカー) と (b) この新実装とは
        // 全く形式の異なるファイルが残っている可能性があり、無条件に
        // 無効化する。旧ディレクトリは掃除しない — `v2`のドキュメント
        // コメントと同じ理由 (実害の無いゴミより「他の実装がまだ旧パスを
        // 使っていないか」を毎回確認する負債の方が高くつく)。
        cacheDirectory = base.appendingPathComponent("AvatarCache/GoogleProfilePhoto/v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// `AppEnvironment.reauthenticateGmailAccount(_:)`が再認証成功直後に
    /// 呼ぶ。両方のスコープ不足記録を消すだけでなく、このアカウントの
    /// 索引キャッシュ (メモリ・ディスク双方) も丸ごと破棄する — 再認証前に
    /// 書き込まれた索引は (許可されていなかった方の情報源が) 欠落した
    /// ままの可能性があり、`indexTTL`が切れるまで古い索引を使い続けて
    /// しまうと、再認証してもすぐには新しい写真が反映されない。記録が
    /// 無いアカウント ID を渡しても無害 (`Set.remove`/辞書の削除は no-op)。
    public func clearScopeInsufficientMemory(for accountId: String) {
        otherContactsScopeInsufficientAccountIds.remove(accountId)
        connectionsScopeInsufficientAccountIds.remove(accountId)
        selfScopeInsufficientAccountIds.remove(accountId)
        accountIndexState[accountId] = nil
        deleteIndexDiskCache(accountId: accountId)
    }

    /// Task #42「アバター診断」: `AccountEditView`の「アバター診断」画面が
    /// 表示する1回分のフルレポート。`ensureIndex(for:)`とは違い**常に**
    /// 3つのエンドポイント (`otherContacts`/`connections`/`people/me`) を
    /// 実際に問い合わせる — 通常の解決経路と違って「既にスコープ不足と
    /// わかっている」「索引がまだ`indexTTL`以内」のどちらの理由でもスキップ
    /// しない。ユーザーが「診断」をタップした時点の Google 側の実際の
    /// レスポンスを見せるのがこの画面の目的であり、キャッシュされた古い
    /// 結果や「試す前から諦めた」結果を混ぜると診断の意味が薄れるため。
    ///
    /// 成功したソースがあれば、その場でこのアカウントの索引 (メモリ・
    /// ディスク双方) を上書きする — 「タップで索引を強制再構築」という
    /// 要求どおり、診断は副作用として通常の解決経路が使う索引も最新化する。
    /// また各ソースの成否に応じて`...ScopeInsufficientAccountIds`も更新
    /// する (成功なら記憶を消す、403/401ならその場で記憶する) ので、次回
    /// 以降の通常解決 (`fetchAndStoreIndex`) もこの診断の結果を引き継ぐ。
    public func forceRebuildDiagnostics(accountId: String) async -> GoogleAvatarAccountDiagnostics {
        guard let accessToken = try? await tokenProvider.accessToken(for: accountId) else {
            let unavailable = GooglePeopleIndexOutcome(result: .unavailable, diagnostics: GooglePeopleFetchDiagnostics())
            return GoogleAvatarAccountDiagnostics(
                accountId: accountId,
                builtAt: Date(),
                otherContacts: unavailable,
                connections: unavailable,
                selfPhoto: unavailable,
                totalIndexedAddresses: accountIndexState[accountId]?.index.count ?? 0,
                tokenFetchFailed: true
            )
        }

        let otherContactsOutcome = await client.fetchOtherContactsIndexOutcome(accessToken: accessToken)
        let connectionsOutcome = await client.fetchConnectionsIndexOutcome(accessToken: accessToken)
        let selfOutcome = await client.fetchSelfPhotoIndexOutcome(accessToken: accessToken)

        var merged: [String: URL] = [:]
        var gotAnySuccess = false

        switch otherContactsOutcome.result {
        case .success(let index):
            merged.merge(index) { _, new in new }
            gotAnySuccess = true
            otherContactsScopeInsufficientAccountIds.remove(accountId)
        case .insufficientScope:
            otherContactsScopeInsufficientAccountIds.insert(accountId)
        case .unavailable:
            break
        }
        switch connectionsOutcome.result {
        case .success(let index):
            // See `fetchAndStoreIndex`'s identical merge order comment —
            // saved Contacts win over other-contacts for the same address.
            merged.merge(index) { _, new in new }
            gotAnySuccess = true
            connectionsScopeInsufficientAccountIds.remove(accountId)
        case .insufficientScope:
            connectionsScopeInsufficientAccountIds.insert(accountId)
        case .unavailable:
            break
        }
        switch selfOutcome.result {
        case .success(let index):
            merged.merge(index) { _, new in new }
            gotAnySuccess = true
            selfScopeInsufficientAccountIds.remove(accountId)
        case .insufficientScope:
            selfScopeInsufficientAccountIds.insert(accountId)
        case .unavailable:
            break
        }

        if gotAnySuccess {
            let fetchedAt = Date()
            accountIndexState[accountId] = (merged, fetchedAt)
            writeIndexDiskCache(accountId: accountId, index: merged, fetchedAt: fetchedAt)
        }

        return GoogleAvatarAccountDiagnostics(
            accountId: accountId,
            builtAt: Date(),
            otherContacts: otherContactsOutcome,
            connections: connectionsOutcome,
            selfPhoto: selfOutcome,
            totalIndexedAddresses: gotAnySuccess ? merged.count : (accountIndexState[accountId]?.index.count ?? 0),
            tokenFetchFailed: false
        )
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

    // MARK: - Per-address photo byte cache

    private func loadAndCache(key: String) async -> Data? {
        if let (data, cachedAt) = readDiskCache(key: key), Date().timeIntervalSince(cachedAt) < ttl {
            memoryCache[key] = data
            memoryCacheTimestamps[key] = cachedAt
            return data
        }
        switch await lookupPhotoURL(address: key) {
        case .found(let photoURL):
            guard let data = await client.downloadPhoto(url: photoURL) else {
                // ダウンロード自体の失敗 (ネットワーク/空データ) —
                // 確定的な「無かった」ではないので negative cache に
                // 書かない (次回また試す)。
                return nil
            }
            memoryCache[key] = data
            memoryCacheTimestamps[key] = Date()
            writeDiskCache(key: key, data: data)
            return data
        case .notFound:
            memoryCache[key] = nil
            memoryCacheTimestamps[key] = Date()
            writeDiskCache(key: key, data: nil)
            return nil
        case .indeterminate:
            // Gravatar/企業ロゴと同じ理由: Gmail アカウント無し・全
            // アカウントの索引が構築できていない (ネットワークエラー・
            // 全スコープ不足等)、いずれも確定的な「無かった」ではないので
            // negative cache に書かない。
            return nil
        }
    }

    private enum LookupResult {
        case found(URL)
        case notFound
        case indeterminate
    }

    /// `tokenProvider.gmailAccountIds()`の順に、各アカウントの索引
    /// (`ensureIndex(for:)`) を引いて`address`を探す。**索引が構築できた
    /// (=`ensureIndex`が`nil`以外を返した) アカウントが1つ以上あり、その
    /// どの索引にも`address`が無い場合だけ`.notFound`** — 索引が1つも
    /// 構築できなかった場合 (Gmail アカウント無し、または試した全アカウント
    /// が索引未構築) は`.indeterminate`にする (`sawDefinitiveIndex`)。
    private func lookupPhotoURL(address: String) async -> LookupResult {
        let accountIds = await tokenProvider.gmailAccountIds()
        guard !accountIds.isEmpty else { return .indeterminate }

        var sawDefinitiveIndex = false
        for accountId in accountIds {
            guard let index = await ensureIndex(for: accountId) else { continue }
            sawDefinitiveIndex = true
            if let url = index[address] { return .found(url) }
        }
        return sawDefinitiveIndex ? .notFound : .indeterminate
    }

    // MARK: - Per-account index cache

    /// このアカウントの現在の索引を返す。メモリ内キャッシュが`indexTTL`
    /// 以内ならそれを返し、そうでなければディスクキャッシュ→ネットワーク
    /// の順に試して再構築する (`fetchAndStoreIndex(accountId:)`)。同じ
    /// アカウントに対する同時呼び出しは1本のネットワーク往復にまとめる
    /// (`indexFetchTasks`、`resolveAvatarImageData`の`inFlight`と同じ
    /// パターン)。`nil` = このアカウントの索引がまだ一度も構築できて
    /// いない (index未構築、`lookupPhotoURL`側で`.indeterminate`扱い)。
    private func ensureIndex(for accountId: String) async -> [String: URL]? {
        if let state = accountIndexState[accountId], Date().timeIntervalSince(state.fetchedAt) < indexTTL {
            return state.index
        }
        if let existing = indexFetchTasks[accountId] { return await existing.value }

        let task = Task<[String: URL]?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetchAndStoreIndex(accountId: accountId)
        }
        indexFetchTasks[accountId] = task
        let result = await task.value
        indexFetchTasks[accountId] = nil
        return result
    }

    /// ディスクキャッシュが`indexTTL`以内ならそれをメモリへ昇格して返す。
    /// それ以外はアクセストークンを取得し、`otherContacts`/`connections`
    /// の2つの索引取得を (既にスコープ不足と分かっている方はスキップして)
    /// 試し、成功した方だけをマージする。**どちらも失敗 (スコープ不足
    /// または一時的なエラー) だった場合は、既存のメモリ内索引 (stale でも)
    /// をそのまま返す** — 新しい索引が1件も得られなかったからといって
    /// 古い索引を`nil`で上書きすると、一時的なネットワーク不調のたびに
    /// それまで表示できていた写真まで消えてしまう。
    private func fetchAndStoreIndex(accountId: String) async -> [String: URL]? {
        if let disk = readIndexDiskCache(accountId: accountId), Date().timeIntervalSince(disk.fetchedAt) < indexTTL {
            accountIndexState[accountId] = disk
            return disk.index
        }

        guard let accessToken = try? await tokenProvider.accessToken(for: accountId) else {
            return accountIndexState[accountId]?.index
        }

        var merged: [String: URL] = [:]
        var gotAnySuccess = false

        if !otherContactsScopeInsufficientAccountIds.contains(accountId) {
            switch await client.fetchOtherContactsPhotoIndex(accessToken: accessToken) {
            case .success(let index):
                merged.merge(index) { _, new in new }
                gotAnySuccess = true
            case .insufficientScope:
                otherContactsScopeInsufficientAccountIds.insert(accountId)
            case .unavailable:
                break
            }
        }

        if !connectionsScopeInsufficientAccountIds.contains(accountId) {
            switch await client.fetchConnectionsPhotoIndex(accessToken: accessToken) {
            case .success(let index):
                // 保存済み連絡先 (`connections`) はユーザー本人が明示的に
                // 保存した情報なので、同じアドレスが`otherContacts`側にも
                // (別の写真で) 出ていた場合はこちらを優先する。
                merged.merge(index) { _, new in new }
                gotAnySuccess = true
            case .insufficientScope:
                connectionsScopeInsufficientAccountIds.insert(accountId)
            case .unavailable:
                break
            }
        }

        // Task #42「自分のプロフィール写真」: 自分のアドレス (複数エイリ
        // アスがあれば全部) は`otherContacts`にも`connections`にも出て
        // 来ない — `people/me`だけがカバーできる母集団なので、成否に
        // 関わらず常に試す (上の2つと違って「既に成功した」からスキップ
        // する理由が無い)。
        if !selfScopeInsufficientAccountIds.contains(accountId) {
            switch await client.fetchSelfPhotoIndexOutcome(accessToken: accessToken).result {
            case .success(let index):
                merged.merge(index) { _, new in new }
                gotAnySuccess = true
            case .insufficientScope:
                selfScopeInsufficientAccountIds.insert(accountId)
            case .unavailable:
                break
            }
        }

        guard gotAnySuccess else {
            return accountIndexState[accountId]?.index
        }

        let fetchedAt = Date()
        accountIndexState[accountId] = (merged, fetchedAt)
        writeIndexDiskCache(accountId: accountId, index: merged, fetchedAt: fetchedAt)
        return merged
    }

    // MARK: - Per-account index disk cache

    private struct IndexCacheFile: Codable {
        var fetchedAt: Date
        /// `[String: URL]`ではなく`[String: String]`で保存する —
        /// `URL`の`Codable`実装は将来 Foundation 側の表現が変わっても
        /// 互換性を保証しない一方、文字列としてのシリアライズはこの型が
        /// 完全に制御できる (読み込み時に`URL(string:)`で失敗しても
        /// その1エントリだけ無視すればよく、ファイル全体のデコード失敗に
        /// しない)。
        var index: [String: String]
    }

    private func readIndexDiskCache(accountId: String) -> (index: [String: URL], fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: indexFileURL(for: accountId)),
              let file = try? JSONDecoder().decode(IndexCacheFile.self, from: data)
        else { return nil }
        let index = file.index.compactMapValues { URL(string: $0) }
        return (index, file.fetchedAt)
    }

    private func writeIndexDiskCache(accountId: String, index: [String: URL], fetchedAt: Date) {
        let file = IndexCacheFile(fetchedAt: fetchedAt, index: index.mapValues(\.absoluteString))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: indexFileURL(for: accountId))
    }

    private func deleteIndexDiskCache(accountId: String) {
        try? FileManager.default.removeItem(at: indexFileURL(for: accountId))
    }

    private func indexFileURL(for accountId: String) -> URL {
        cacheDirectory.appendingPathComponent(AvatarCacheKey.sha256Hex(accountId) + ".index.json")
    }

    // MARK: - Per-address photo byte disk cache

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

/// Task #42「アバター診断」: `GoogleProfilePhotoAvatarResolver
/// .forceRebuildDiagnostics(accountId:)`が返す1回分のフルレポート。
/// トップレベル型にしてある — `GoogleAvatarDiagnosticsView`(app 層) から
/// 単独で参照できるようにするため、また`AccountEditView`と同じ理由
/// (`docs/ci.md`の型チェックタイムアウトの節) でこの actor 自身の型
/// チェック負荷を増やさないため。
public struct GoogleAvatarAccountDiagnostics: Sendable, Equatable {
    public var accountId: String
    public var builtAt: Date
    public var otherContacts: GooglePeopleIndexOutcome
    public var connections: GooglePeopleIndexOutcome
    public var selfPhoto: GooglePeopleIndexOutcome
    /// 3つのソースをマージした結果、最終的に索引に載ったアドレスの総数
    /// (成功したソースが1つも無かった場合は、直前まで有効だった索引の
    /// 件数 — 全滅した診断実行のたびに0件表示に戻ると紛らわしいため)。
    public var totalIndexedAddresses: Int
    /// アクセストークンの取得自体が失敗した (リフレッシュトークン喪失・
    /// ネットワーク不通等) — `true`のとき`otherContacts`/`connections`/
    /// `selfPhoto`はいずれも意味を持たないダミー値 (`.unavailable`、
    /// 空の`GooglePeopleFetchDiagnostics`) になる。
    public var tokenFetchFailed: Bool
}
