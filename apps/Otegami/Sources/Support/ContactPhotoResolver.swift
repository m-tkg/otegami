import Contacts
import CryptoKit
import Foundation

/// アバター強化バッチ フェーズ1「連絡先の写真」: `AvatarImageResolving` の
/// 最優先情報源。`CNContactStore` はオンデバイス API で、この型自身は
/// ネットワークに一切触れない。
///
/// - **権限**: 初めて呼ばれたときに一度だけ `CNContactStore
///   .authorizationStatus(for: .contacts)` を見て、`.notDetermined` なら
///   `requestAccess(for:)` で OS のダイアログを出す。**拒否/未許可なら
///   静かに `nil` を返すだけ** (エラーを投げない・UI に何も出さない) —
///   `SenderAvatar` はいつでもイニシャルへフォールバックできるので、これは
///   単に「この情報源からは出せなかった」という結果でしかない。
/// - **iOS 18+ limited access**: `.limited`(ユーザーが選んだ一部の連絡先
///   だけ見える状態)も`.authorized`と同様に扱う — 取得できる範囲だけを
///   検索対象にするのは`CNContactStore`自身の仕事で、この型は「許可された
///   範囲内で検索する」以上のことをする必要がない。
/// - **キャッシュ**: メールアドレス (小文字化) をキーに、メモリ + ディスク
///   (`Caches/AvatarCache/Contacts/`) の2段でキャッシュする。「写真あり」
///   だけでなく「写真なし (連絡先が無い/連絡先はあるが写真なし)」という
///   negative result もキャッシュする — 存在しないことを毎回
///   `CNContactStore`に問い合わせ直さないため。
/// - **無効化**: `CNContactStoreDidChange`通知でメモリ・ディスク両方の
///   キャッシュを丸ごと破棄する。どの連絡先が変わったかまでは追わない
///   (`CNChangeHistoryEvent`のような差分APIを使った部分無効化は、この
///   キャッシュの再構築コストが軽い — 次にそのアドレスのアバターが
///   画面に出たときに1回`CNContactStore`を引き直すだけ — ことに対して
///   実装コストが見合わないと判断した)。
/// - **重複解決の coalesce**: 同一アドレスへの同時呼び出しは同じ
///   `Task`を共有する — 一覧が高速スクロールされ、同じ差出人の行が
///   同時に何行も再構築されても`CNContactStore`への問い合わせは1回で済む。
public actor ContactPhotoResolver: AvatarImageResolving {
    private let store = CNContactStore()
    private var memoryCache: [String: Data?] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private var authorizationChecked = false
    private var isAuthorized = false

    private let cacheDirectory: URL
    // `nonisolated(unsafe)`: mirrors `AppEnvironment.cloudSyncNotificationObserver`'s
    // identical annotation/doc comment — written once from `init` (before
    // this actor is usable at all) and read once from `deinit`, which Swift
    // requires to be `nonisolated` even for an actor, so this property can't
    // itself be actor-isolated if `deinit` is going to read it.
    private nonisolated(unsafe) var changeObserver: NSObjectProtocol?

    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("AvatarCache/Contacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let center = NotificationCenter.default
        // `addObserver(forName:object:queue:using:)` itself is thread-safe
        // to call from `init` before `self` is fully isolated-actor-ready;
        // the closure below only captures `self` weakly and hops back onto
        // the actor via `Task`, matching the pattern `AppEnvironment
        // .cloudSyncNotificationObserver` already uses for its own
        // NSNotification bridging.
        changeObserver = center.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.invalidateCache() }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    public func resolveAvatarImageData(displayName: String?, address: String) async -> Data? {
        guard AvatarSourceSettingsStore.isContactPhotoEnabled else { return nil }
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }

        if let cached = memoryCache[key] { return cached }
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
        if let cached = readDiskCache(key: key) {
            memoryCache[key] = cached
            return cached
        }
        let data = await fetchFromContacts(address: key)
        memoryCache[key] = data
        writeDiskCache(key: key, data: data)
        return data
    }

    private func invalidateCache() {
        memoryCache.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// `.some(data)` = cached with a photo, `.some(nil)` = cached, no photo
    /// (negative result), `nil` (outer) = not cached at all yet.
    private func readDiskCache(key: String) -> Data?? {
        let fileManager = FileManager.default
        if let data = try? Data(contentsOf: photoFileURL(for: key)) {
            return .some(data)
        }
        if fileManager.fileExists(atPath: noPhotoMarkerURL(for: key).path) {
            return .some(nil)
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

    /// File names are a SHA-256 digest of the (already-lowercased) address,
    /// not the address itself — avoids depending on arbitrary email-address
    /// bytes being valid/safe path components on every filesystem this app
    /// could run on.
    private func photoFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.digestHex(key) + ".jpg")
    }

    private func noPhotoMarkerURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.digestHex(key) + ".none")
    }

    private static func digestHex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - CNContactStore

    private func ensureAuthorization() async -> Bool {
        if authorizationChecked { return isAuthorized }
        authorizationChecked = true
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = (try? await store.requestAccess(for: .contacts)) ?? false
        case .denied, .restricted:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }
        return isAuthorized
    }

    private func fetchFromContacts(address: String) async -> Data? {
        guard await ensureAuthorization() else { return nil }
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return contacts.first(where: \.imageDataAvailable)?.thumbnailImageData
        } catch {
            // Denied mid-session, a malformed predicate, or any other
            // `CNContactStore` failure — same "quietly no image" contract as
            // every other branch here.
            return nil
        }
    }
}
