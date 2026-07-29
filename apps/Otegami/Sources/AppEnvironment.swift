import AccountCloudSync
import Foundation
import GoogleOAuth
import GRDB
import MailTransport
import MailTransportMailCore
import MicrosoftOAuth
import OtegamiCore
import OtegamiRelayAPI
import OtegamiStore
import OtegamiTranslation
import OtegamiTranslationFoundationModels
import PushRelayClient
import SyncEngine
import TranslationEngine
#if os(iOS)
import UserNotifications
#endif

/// Root dependency-injection container for the app: the shared database,
/// the sync coordinator (wired to the real `MailCoreIMAPSession` — tests
/// inject `FakeIMAPSession` directly into `SyncEngine`'s own test target
/// instead of going through this type), and the Keychain-backed credential
/// store. Also keeps a live `accounts` list so the sidebar (and anything
/// else that needs "which accounts exist") doesn't have to set up its own
/// top-level `ValueObservation`.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let syncCoordinator: SyncCoordinator
    let credentialStore: KeychainCredentialStore
    /// Task #56 — see `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`'s doc
    /// comment (inside the `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` block
    /// below). Non-nil only when that env var was set at launch; `nil` in
    /// every real launch. `MailScreenView`'s matching `.task` reads this
    /// once and pushes straight to that thread — the "UITest の直接遷移
    /// 経路" fallback for when this simulator/toolchain's `MessageListRow`
    /// tap doesn't register.
    var uitestDirectOpenThreadId: Int64? = nil
    /// C6/C7 送信キャンセル — see `PendingSendCoordinator`'s doc comment.
    let pendingSendCoordinator = PendingSendCoordinator()
    /// アバター強化バッチ「Google プロフィール写真」— see `GmailAccessTokenBridge`'s
    /// doc comment. Default-initialized here (no dependency on anything else
    /// in this class), same "wired to `self` at the very end of `init()`"
    /// two-phase pattern as `pendingSendCoordinator` right above — this is
    /// what makes it safe to already be usable when `avatarImageResolver`
    /// below is built, well before `database`/`tokenStore` exist.
    @ObservationIgnored private let gmailAccessTokenBridge = GmailAccessTokenBridge()
    /// M9: push opt-in. `pushSettings` is the persistence layer
    /// (`PushSettingsStore`'s doc comment); `isPushEnabled`/
    /// `pushRelayURLString` mirror it into `@Observable` state so
    /// `PushNotificationSettingsView` doesn't read `UserDefaults`
    /// directly.
    let pushRelayClient = PushRelayClient()
    @ObservationIgnored let pushSettings: PushSettingsStore
    private(set) var isPushEnabled: Bool
    private(set) var pushRelayURLString: String

    /// M11: iCloud account-definition sync. `accountCloudSync` reconciles
    /// the local `account` table against the `"accounts.v1"` iCloud KVS key
    /// (`docs/icloud-sync.md`); `cloudSyncSettings` is the "iCloud でアカウン
    /// トを同期" toggle's persistence (`AccountsSettingsView`),
    /// `isCloudSyncEnabled` its `@Observable` mirror for the UI, matching
    /// the `pushSettings`/`isPushEnabled` split above.
    @ObservationIgnored let cloudSyncSettings: CloudSyncSettingsStore
    @ObservationIgnored let accountCloudSync: AccountCloudSyncEngine
    private(set) var isCloudSyncEnabled: Bool
    /// Task #89: the display-settings counterpart to `accountCloudSync` —
    /// syncs the allowlisted `UserDefaults` keys `AppSettingsCloudDirectory`
    /// names (list display/viewer/swipe/toolbar/avatar/translation
    /// preferences) through the `"settings.v1"` KVS key, gated by the exact
    /// same `cloudSyncSettings`/`isCloudSyncPermittedOnThisBuild()` toggle
    /// as `accountCloudSync` — see `docs/icloud-sync.md`'s settings-sync
    /// section for why this piggybacks on the same toggle rather than
    /// getting its own (a re-install wiping every UI preference back to its
    /// compiled-in default is exactly the same class of "this device's
    /// `UserDefaults` can't be trusted to survive" problem the account sync
    /// toggle already exists to address).
    @ObservationIgnored let settingsCloudSync: SettingsCloudSyncEngine
    // `nonisolated(unsafe)`: only ever written once, from `init()` (already
    // `@MainActor`), and read once, from `deinit` — which Swift requires to
    // be `nonisolated` even on a `@MainActor` class, so this property can't
    // itself be actor-isolated if `deinit` is going to read it at all.
    @ObservationIgnored nonisolated(unsafe) private var cloudSyncNotificationObserver: NSObjectProtocol?
    /// Task #101 (実機報告「スレッド表示をオフにしても再起動で戻る」フォロー
    /// アップ): `settingsCloudSync` previously only ever got a chance to push
    /// a local `*SettingsStore` edit at a `.background`/`.inactive` scene-
    /// phase transition (`OtegamiApp.handleScenePhaseChange`'s doc comment
    /// explains why there's no per-write hook) — an un-pushed edit could sit
    /// on this device for the entire rest of a foreground session with no
    /// other trigger. This observer debounces `UserDefaults.didChangeNotification`
    /// (which fires on *every* `UserDefaults.standard` write, not just the
    /// allowlisted sync keys — `AppSettingsCloudDirectory`'s allowlist is
    /// what keeps an unrelated write, e.g. `lastOpenedThreadIdBySelectionKey`,
    /// from mattering here; `reconcile()` itself is a cheap no-op when
    /// nothing relevant changed) and calls `reconcile()` a few seconds after
    /// things go quiet, so a change gets a real chance to reach the cloud
    /// well before the user might background/kill the app, shrinking (not
    /// eliminating — `reconcile()`'s own doc comment on why a genuinely
    /// concurrent edit still needs its own guard) the window during which an
    /// un-pushed local edit exists at all.
    @ObservationIgnored nonisolated(unsafe) private var settingsChangeNotificationObserver: NSObjectProtocol?
    @ObservationIgnored private var settingsChangeDebounceTask: Task<Void, Never>?
    /// `nil` when `GOOGLE_OAUTH_CLIENT_ID` isn't configured for this build
    /// (see `GoogleOAuthConfig`'s doc comment) — every Gmail-entry point
    /// checks this (directly or via `isGmailOAuthConfigured`) before
    /// offering the option at all.
    let googleOAuthClient: GoogleOAuthClient?
    let tokenStore: GoogleOAuth.TokenStore?

    /// Drives `AccountTypeSelectionView`'s Gmail button (disabled + a
    /// docs/oauth-setup.md hint when `false`) — see `GoogleOAuthConfig`.
    var isGmailOAuthConfigured: Bool { googleOAuthClient != nil }

    /// Task #116 第2段: Outlook.com/Office 365's counterpart to
    /// `googleOAuthClient`/`tokenStore` above — `nil` when
    /// `OTEGAMI_MICROSOFT_CLIENT_ID` isn't configured for this build (see
    /// `MicrosoftOAuthConfig`'s doc comment). A build can have Gmail,
    /// Microsoft, both, or neither configured independently — each
    /// provider's Client ID comes from its own xcconfig variable.
    let microsoftOAuthClient: MicrosoftOAuthClient?
    let microsoftTokenStore: MicrosoftOAuth.TokenStore?

    /// Drives `AccountTypeSelectionView`'s Outlook/Office365 buttons —
    /// mirrors `isGmailOAuthConfigured`.
    var isMicrosoftOAuthConfigured: Bool { microsoftOAuthClient != nil }

    private(set) var accounts: [AccountRecord] = []
    @ObservationIgnored private var accountsObservationTask: Task<Void, Never>?
    /// H「アプリアイコンの未読バッジ」— restarted (not just left running)
    /// every time `accounts` changes, since `MessageQuery
    /// .unifiedInboxUnreadCountObservation(accountIds:)`'s `accountIds`
    /// argument has to track the current account list. See
    /// `restartBadgeObservationIfNeeded(accountIds:)`.
    @ObservationIgnored private var badgeObservationTask: Task<Void, Never>?
    /// Set once `BadgeCenter.requestAuthorizationIfNeeded()` has actually
    /// been called this launch — guards against re-requesting on every
    /// single `accounts` change (harmless either way since the OS itself is
    /// idempotent about a decided authorization, but there's no reason to
    /// call it more than once).
    @ObservationIgnored private var hasRequestedBadgeAuthorization = false

    /// design-phase-3 (1i/1k, `docs/translation.md`): the raw engine, for
    /// one-off translations not tied to a stored message (`ComposerView`'s
    /// "英語に翻訳して送る" — there's no `messageId` for a draft still being
    /// typed, so `MessageTranslator`'s per-message cache doesn't apply).
    /// `FoundationModelsTranslationService` in every normal build — this
    /// app's deployment target is already iOS/macOS 26 (`project.yml`), so
    /// the type itself is unconditionally available at compile time;
    /// whether it can actually translate on *this* device/Apple
    /// Intelligence configuration is a runtime question
    /// `isTranslationAvailable` answers by reading `availability`. `init()`'s
    /// `OTEGAMI_UITEST_FAKE_TRANSLATION` check is the one exception — swaps
    /// in `FakeTranslationService` (normally a tests/previews-only type,
    /// `OtegamiTranslation`'s own doc comment) purely so 1i's HTML-
    /// preserving translation display can still be verified end-to-end on a
    /// Simulator where Foundation Models itself doesn't run.
    @ObservationIgnored let translationService: any TranslationService
    /// The cached, per-message-persisted counterpart (`docs/translation.md`'s
    /// "キャッシュ方針") — what `MessageView`'s translation bar (1i) actually
    /// calls, so opening the same English message twice doesn't re-run the
    /// on-device model twice.
    @ObservationIgnored let messageTranslator: MessageTranslator

    /// アバター強化バッチ: `SenderAvatar`'s priority-ordered image source
    /// (`docs/design-system.md`). A single shared instance so its per-source
    /// caches actually cache across every row — see `CompositeAvatarImageResolver`'s
    /// doc comment. Injected into the SwiftUI environment alongside
    /// `.environment(environment)` (`OtegamiApp.swift`), not read directly
    /// off `AppEnvironment` by any view — `SenderAvatar` lives in
    /// `DesignSystem`, which can't import this app-target type.
    @ObservationIgnored let avatarImageResolver: any AvatarImageResolving

    /// The same instance `avatarImageResolver`'s `CompositeAvatarImageResolver`
    /// holds (type-erased there behind `any AvatarImageResolving`), kept
    /// here too under its concrete type so `reauthenticateGmailAccount(_:)`
    /// can call `clearScopeInsufficientMemory(for:)` on it directly —
    /// `AvatarImageResolving` itself has no such method (it's specific to
    /// this one source), and there's no reason to widen that shared
    /// protocol just for it.
    @ObservationIgnored let googleProfilePhotoAvatarResolver: GoogleProfilePhotoAvatarResolver

    /// Drives the translation bar's visibility/enabled state and the
    /// Composer's "英語に翻訳して送る" toggle — `false` covers every
    /// `TranslationUnavailableReason` (device not eligible, Apple
    /// Intelligence off, model not ready) with one check, matching how
    /// `isGmailOAuthConfigured` above collapses its own availability
    /// question to a single `Bool` for view code.
    var isTranslationAvailable: Bool { translationService.availability.isAvailable }

    init() {
        // Task #105 (実機報告「スレッド表示はオフのまま (設定画面も含め)
        // なのに、再起動直後の一覧だけがスレッド表示になる」): forces
        // `UserDefaults.standard`'s in-process cache to reload from disk
        // before *anything* — including the `register...Defaults()` calls
        // right below, and every `ListDisplaySettingsStore.persistedBool`
        // call `MessageListView`'s `.task(id:)` makes on its very first
        // post-launch render — reads it. See `ListDisplaySettingsStore
        // .forceReloadFromDiskOnce()`'s doc comment for why this targets a
        // cold-launch `UserDefaults`/`cfprefsd` cache-lag theory that #82
        // (06c1062)'s own direct-`UserDefaults.standard`-read fix didn't
        // fully close.
        ListDisplaySettingsStore.forceReloadFromDiskOnce()
        // Task #142 (`scripts/verify-screen.sh list-pinned-only`):「フラグ
        // 付きのみ表示」トグルをタップ無しで直接ONにする検証用フック —
        // 他の`-uitests...Directly`系launch argumentと違い、こちらは
        // `UserDefaults.standard.set(true, forKey:)`で実際の`Bool`値を書く
        // 必要がある。`-listDisplay.pinnedOnly 1`のような素の launch
        // argument (`NSArgumentDomain`) だと `String` "1" として入るだけで、
        // `ListDisplaySettingsStore.persistedBool(forKey:default:)`が使う
        // 厳密な`object(forKey:) as? Bool`キャストでは`nil`(→既定値`false`)
        // に落ちてしまう (`@AppStorage`側の緩い`UserDefaults.bool(forKey:)`
        // だけは真として読めてしまうため、ヘッダのトグルアイコンだけON表示
        // で実際のフィルタが効かないという食い違いが実機/シミュレータで
        // 再現した — この`set(true, forKey:)`はその食い違いを避けるための
        // 修正)。
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FORCE_PINNED_ONLY"] == "1" {
            UserDefaults.standard.set(true, forKey: ListDisplaySettingsStore.pinnedOnlyKey)
        }
        // Design system: registers the bundled Archivo variable font with
        // CoreText before any view can render — see `OtegamiFont
        // .registerCustomFontsIfNeeded()`'s doc comment. Was previously
        // never called at all (`docs/design-system.md`'s "次フェーズへの
        // 申し送り"), so every `Font.custom("ArchivoRoman-...", ...)` token
        // silently fell back to the system font; harmless but not what the
        // design system intends. `AppEnvironment.init()` runs exactly once,
        // synchronously, before `RootView` first renders, and is already
        // `@MainActor`, matching this call's own `@MainActor` requirement.
        OtegamiFont.registerCustomFontsIfNeeded()
        // design-phase-3: registers the 1l "翻訳" defaults (auto-translate
        // on, list summary off) before any `@AppStorage` reader — see
        // `UserDefaults.registerOtegamiTranslationDefaults()`'s doc comment.
        UserDefaults.registerOtegamiTranslationDefaults()
        // B「画像の設定」— see `UserDefaults.registerOtegamiImageDefaults()`'s
        // doc comment for why this needs to run before any `HTMLMessageView`
        // is ever constructed, not just before any `@AppStorage` read.
        UserDefaults.registerOtegamiImageDefaults()
        // Task #45「ダークモードで文字が読めない」— see
        // `HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey`'s doc
        // comment for why this needs the same "before any `HTMLMessageView`
        // is constructed" ordering as the image defaults registration above.
        UserDefaults.registerOtegamiHTMLDisplayDefaults()
        // Task #43: F (実機フィードバック第3弾)で入れた
        // `LocalizationSettingsStore.migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()`
        // の呼び出しはここにあったが、削除した — 「起動のたびに言語設定が
        // 英語へ戻る」という実機バグの原因だった。詳細は
        // `LocalizationSettingsStore`の型doc comment参照。
        // アバター強化バッチ: `AvatarSourceSettingsStore`'s doc comment — the
        // `ContactPhotoResolver` actor reads these keys directly via
        // `UserDefaults.standard`, not `@AppStorage`, so they need to
        // resolve correctly from its very first call too.
        UserDefaults.registerOtegamiAvatarSourceDefaults()

        // Task #60 (シミュレータ検証基盤の整備): `OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES`
        // — a UITest/verify-script-only escape hatch, same `OTEGAMI_UITEST_*`
        // launch-environment pattern as every other flag in this file.
        // 連絡先の写真 (`ContactPhotoResolver`) は初回解決の瞬間に OS の
        // 連絡先アクセス許可ダイアログを出す (`ContactPhotoResolver`のドキュ
        // メントコメント参照) — このダイアログはシミュレータ上で非決定的な
        // タイミングで現れ、XCUITest の待機やタップ前提の起動フローを潰す
        // (`docs/verify.md`「シミュレータ検証の既知の不調」参照)。フォース
        // する4キーはいずれも `ContactPhotoResolver`/`GoogleProfilePhotoAvatarResolver`/
        // `GravatarAvatarResolver`/`CompanyLogoAvatarResolver`の`resolveAvatarImageData`
        // が本体処理 (権限確認・ネットワーク送信) より前に読む早期 `guard`
        // なので、ここで`false`に上書きしておけば連絡先ダイアログだけでなく
        // Google People API/Gravatar/favicon への通信も一切発生せず、
        // `SenderAvatar`は常にイニシャル+アカウント色の最終フォールバックへ
        // 直行する。`.set(false, forKey:)`(`.register(defaults:)`ではなく)
        // を使うのは、同じシミュレータインストールでこのフラグ無しの launch
        // が過去にあった場合、その launch がユーザー操作で書き込んだ
        // (「常に有効」がデフォルト) 実際の値を確実に上書きするため —
        // `register`は「キーが未設定のときだけ」効くので、それだと過去の
        // 値が残って上書きできない。
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DISABLE_AVATAR_SOURCES"] == "1" {
            UserDefaults.standard.set(false, forKey: AvatarSourceSettingsStore.showContactPhotoKey)
            UserDefaults.standard.set(false, forKey: AvatarSourceSettingsStore.showGoogleProfilePhotoKey)
            UserDefaults.standard.set(false, forKey: AvatarSourceSettingsStore.showGravatarKey)
            UserDefaults.standard.set(false, forKey: AvatarSourceSettingsStore.showCompanyLogoKey)
        }

        // アバター強化バッチ: no dependency on `database`/`credentialStore`/
        // anything constructed further below, so it's safe to build this
        // early alongside the other launch-time setup above. Sources are
        // listed in `SenderAvatar`'s documented priority order — see
        // `CompositeAvatarImageResolver`'s doc comment.
        // アバター強化バッチ「Google プロフィール写真」: 連絡先の写真の次、
        // Gravatar の前 — `gmailAccessTokenBridge`はまだ`self`を知らない
        // (下の`configure(environment:)`呼び出しまで) が、それまでの間に
        // 解決要求が来ても`gmailAccountIds()`が空を返すだけで安全
        // (`GmailAccessTokenBridge`のドキュメントコメント参照)。単独の
        // `let`にしてから`sources`に渡す — `reauthenticateGmailAccount(_:)`
        // が後で同じインスタンスを`googleProfilePhotoAvatarResolver`
        // 経由で直接呼べるようにするため (上のプロパティのドキュメント
        // コメント参照)。
        let googleProfilePhotoAvatarResolver = GoogleProfilePhotoAvatarResolver(tokenProvider: gmailAccessTokenBridge)
        self.googleProfilePhotoAvatarResolver = googleProfilePhotoAvatarResolver
        self.avatarImageResolver = CompositeAvatarImageResolver(sources: [
            ContactPhotoResolver(),
            googleProfilePhotoAvatarResolver,
            GravatarAvatarResolver(),
            CompanyLogoAvatarResolver()
        ])

        let database: AppDatabase
        do {
            database = try AppDatabase.makeShared(appGroupIdentifier: OtegamiAppGroup.identifier)
        } catch {
            // The on-disk database couldn't be opened (corrupt file, out of
            // disk space, ...). Falling back to in-memory keeps the app
            // usable for the current launch rather than crashing outright;
            // the underlying issue would need a real repair/reset flow to
            // recover from permanently, which is out of scope for M1.
            assertionFailure("Failed to open shared database, falling back to in-memory: \(error)")
            guard let inMemory = try? AppDatabase.makeInMemory() else {
                fatalError("Failed to create even an in-memory database: \(error)")
            }
            database = inMemory
        }
        self.database = database

        // Moved ahead of the duplicate-account merge below (it used to be
        // constructed much further down, alongside `syncCoordinator`) so
        // the merge's survivor pick can do a *live* Keychain check instead
        // of trusting the persisted `AccountRecord.needsReauth` column —
        // see `AccountDuplicateMerger.mergeDuplicateAccounts`'s
        // `hasCredential` parameter doc comment for the real-device bug
        // (`KeychainCredentialStore.legacyServices`'s doc comment) that
        // made the column-only check pick a credential-less survivor.
        // `KeychainCredentialStore` itself has no dependency on anything
        // constructed later in this initializer, so moving it earlier is
        // safe.
        self.credentialStore = KeychainCredentialStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)

        // UITest-only escape hatch (mirrors `MessageView
        // .deleteCredentialIfUITestRequested`'s `OTEGAMI_UITEST_*`
        // pattern) — see `KeychainCredentialStore
        // .relocateToLegacyServiceForUITesting`'s doc comment.
        // `OtegamiCredentialRecoveryUITests` sets this on a *second* launch
        // (after a first, ordinary launch already added a real account, so
        // its password already exists under the current `service`) to
        // reproduce the exact state a device that predates the `52df393`
        // Keychain-service rename was left in, then lets the rest of this
        // very same `init()` — the duplicate-merge live credential check
        // right below, `startObservingAccounts`'s automatic retry, any
        // message body fetch — exercise `KeychainCredentialStore`'s own
        // legacy-service fallback for real, end to end.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_MOVE_CREDENTIALS_TO_LEGACY_KEYCHAIN_SERVICE"] == "1" {
            let passwordAccountIds = (try? database.dbWriter.read { db in
                try AccountRecord.filter(Column("authType") == AccountAuthType.password.rawValue).fetchAll(db)
            })?.map(\.id) ?? []
            for accountId in passwordAccountIds {
                credentialStore.relocateToLegacyServiceForUITesting(accountId: accountId)
            }
        }

        // UITest-only escape hatch, the other shape of credential loss this
        // app now recovers from (see `KeychainCredentialStore
        // .relocateToOrphanAccountIdForUITesting`'s doc comment) — moves
        // every `.password` account's Keychain password onto a synthetic id
        // that matches no real `AccountRecord`, reproducing a device that
        // already went through a bad duplicate-account merge before this
        // fix shipped and was left with the real password stranded under
        // the merged-away account's now-nonexistent id.
        // `OtegamiCredentialRecoveryUITests` sets this on a *second* launch,
        // then lets the very next, ordinary launch (no flag) exercise
        // `adoptOrphanedCredentialIfUnambiguous` below for real.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_RELOCATE_CREDENTIAL_TO_ORPHAN_ACCOUNT_ID"] == "1" {
            let passwordAccountIds = (try? database.dbWriter.read { db in
                try AccountRecord.filter(Column("authType") == AccountAuthType.password.rawValue).fetchAll(db)
            })?.map(\.id) ?? []
            for accountId in passwordAccountIds {
                credentialStore.relocateToOrphanAccountIdForUITesting(
                    accountId: accountId, orphanAccountId: "\(accountId)-orphaned-uitest"
                )
            }
        }

        // M11 bug fix: consolidate already-local duplicate `account` rows
        // for the same real mailbox — see `AccountDuplicateMerger`'s doc
        // comment for the bug this is the migration side of
        // (`docs/icloud-sync.md`'s "重複挿入バグ"): a device that hit the
        // pre-fix `AccountCloudSyncEngine.reconcile()` duplicate-insertion
        // bug ends up with two account rows for the same mailbox — one
        // live, one perpetually `needsReauth` (no Keychain credential for
        // its UUID ever synced to this device) — which showed up as two
        // identical entries in Settings → アカウント and, because the
        // unified inbox merges both accounts' independently-synced mail,
        // duplicate messages that failed to open unpredictably depending on
        // which duplicate's copy a given message came from. Run
        // synchronously (unlike the FTS backfill/cloud reconcile `Task`s
        // below) so `startObservingAccounts()`'s very first read of the
        // account list already reflects the merged state — nobody should
        // ever see the duplicate flash by in Settings, even for one frame.
        // Idempotent (`AccountDuplicateMerger`'s doc comment) — safe to
        // leave unconditional on every launch rather than gating it behind
        // a one-shot flag.
        //
        // `OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE`: a UITest-only
        // escape hatch (mirrors `ComposerView
        // .attachUITestFixtureIfRequested`'s/`MessageView
        // .deleteCredentialIfUITestRequested`'s `OTEGAMI_UITEST_*` launch-
        // environment pattern), no-op unless explicitly set — lets
        // `OtegamiDuplicateAccountUITests` inject a duplicate `account` row
        // via `sqlite3` between two launches of the *same* build and
        // actually capture the pre-merge "two accounts" bug state on
        // screen for one launch, before letting the very next launch (flag
        // unset) run the real merge. Without this, the synchronous merge
        // above makes the bug state unobservable in the UI even for a
        // single frame by design — which is the correct behavior for real
        // users, but means an automated screenshot-based "before" repro
        // needs some way to hold that state still for one launch.
        let duplicateMerges: [AccountDuplicateMerger.MergeResult]
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_SKIP_DUPLICATE_ACCOUNT_MERGE"] == "1" {
            duplicateMerges = []
        } else {
            // `.password`-kind credential check is a synchronous Keychain
            // read (`KeychainCredentialStore.password` never suspends), so
            // it can run live, right here, inside this still-synchronous
            // `init()` — unlike `.oauth2`'s `TokenStore.hasStoredRefreshToken`
            // (an actor method, genuinely `async`, and `init()` can't await
            // into it without breaking the "no duplicate-row flash" ordering
            // this whole block's doc comment above depends on). A `.oauth2`
            // duplicate group therefore still falls back to `order()`'s
            // `!needsReauth` heuristic, same as before this parameter
            // existed — only the `.password` path (the one the real-device
            // report was actually about) gets the live check.
            let credentialStore = self.credentialStore
            duplicateMerges = (try? database.dbWriter.write { db in
                try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) { account in
                    guard account.authType == .password else { return !account.needsReauth }
                    return ((try? credentialStore.password(forAccountId: account.id)) ?? nil) != nil
                }
            }) ?? []
        }

        // Immediate rescue, part 1 — this merge's own aftermath: even with
        // the live `hasCredential` check above, a `.oauth2` duplicate group
        // still falls back to the (possibly stale) `!needsReauth` heuristic
        // (see the closure's own comment), so it's still possible for a
        // merge picked *this very launch* to leave a `.password` survivor
        // with no working credential while one of the accounts it just
        // merged away genuinely had one. Adopt that credential onto the
        // survivor's accountId right now, synchronously, *before*
        // `cleanupAfterDuplicateMerge` below gets a chance to delete it as
        // this device's own stray leftover — this is what makes that
        // deletion safe to keep unconditional rather than needing to know
        // which ids were "rescued" and which weren't.
        for merge in duplicateMerges {
            guard let survivorAccount = (try? database.dbWriter.read { db in
                try AccountRecord.fetchOne(db, key: merge.survivorAccountId)
            }) ?? nil,
                survivorAccount.authType == .password,
                ((try? credentialStore.password(forAccountId: merge.survivorAccountId)) ?? nil) == nil
            else { continue }
            for loserAccountId in merge.mergedAccountIds {
                guard (try? credentialStore.adoptOrphanedPassword(
                    fromAccountId: loserAccountId, toAccountId: merge.survivorAccountId
                )) == true else { continue }
                try? database.dbWriter.write { db in
                    guard var row = try AccountRecord.fetchOne(db, key: merge.survivorAccountId) else { return }
                    row.needsReauth = false
                    try row.update(db)
                }
                break
            }
        }

        // Immediate rescue, part 2 — a device that already went through a
        // bad merge in a *previous* launch, before this fix shipped: the
        // duplicate `account` rows are long gone by now (so `duplicateMerges`
        // above is empty and part 1 never runs), but the real password can
        // still be sitting in the Keychain, orphaned, under the merged-away
        // account's id — `CloudAccountDirectory.cleanupAfterDuplicateMerge`'s
        // own credential delete is a `Task` that races the very next app
        // termination, so it isn't guaranteed to have run to completion.
        // Only acts when completely unambiguous (exactly one `.password`
        // account missing a credential, exactly one orphaned Keychain item)
        // — see `KeychainCredentialStore.adoptOrphanedPassword`'s doc
        // comment for why guessing between multiple candidates is
        // deliberately not attempted. Also a no-op if the user already
        // recovered by hand via `AccountEditView`'s "パスワードを入力" flow
        // before this fix shipped (`adoptOrphanedPassword` refuses to
        // clobber an existing credential).
        Self.adoptOrphanedCredentialIfUnambiguous(database: database, credentialStore: credentialStore)

        // Task #42「アバター診断」: UITest-only escape hatch inserting a
        // fake `.gmail`-kind `AccountRecord` with no real OAuth token —
        // exists purely so `OtegamiAvatarDiagnosticsUITests` can navigate
        // to `AccountEditView`'s Gmail-only "アバター診断" link and confirm
        // `GoogleAvatarDiagnosticsView` renders without layout breakage.
        // Real Google auth is impossible to drive from an automated test
        // (`docs/oauth-setup.md`), so this account deliberately has no
        // stored refresh token — every network-backed diagnostic call
        // (`googleGrantedScope`/`googleAvatarDiagnostics`) fails closed to
        // "unknown"/`tokenFetchFailed`, which is exactly the state this
        // fixture needs to exercise the screen's empty/error rendering
        // paths, not a real diagnosis. Mirrors the other `OTEGAMI_UITEST_*`
        // flags' inline, doc-commented, launch-environment-gated pattern
        // above — a plain constant `sortOrder` (rather than
        // `nextAccountSortOrder()`) is used because `self` isn't fully
        // initialized yet at this point in `init()` (Swift's two-phase
        // init rule — same reason `gmailAccessTokenBridge` needs its own
        // `configure(environment:)` step below).
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] == "1" {
            let fakeGmailEmail = "uitest-fake@gmail.com"
            let nextSortOrder = ((try? database.dbWriter.read { db in
                try AccountRecord.fetchAll(db)
            })?.map(\.sortOrder).max() ?? -1) + 1
            let fakeGmailAccount = AccountRecord(
                displayName: "Fake Gmail (UITest)",
                email: fakeGmailEmail,
                authType: .oauth2,
                kind: .gmail,
                imapHost: "imap.gmail.com",
                imapPort: 993,
                imapSecurity: .tls,
                imapUsername: fakeGmailEmail,
                smtpHost: "smtp.gmail.com",
                smtpPort: 587,
                smtpSecurity: .startTLS,
                smtpUsername: fakeGmailEmail,
                sortOrder: nextSortOrder
            )
            // Task #151: captured inside the write block below (mirrors
            // `capturedThreadId`'s pattern elsewhere in this file), read
            // afterward to set `self.uitestDirectOpenThreadId` — `self`
            // isn't safely mutable *from inside* the `Database`-closure
            // itself (same two-phase-init/actor-isolation reasoning as the
            // other `captured*ThreadId` locals in this file).
            var capturedArchivedThreadId: Int64?
            try? database.dbWriter.write { db in
                // Task #52 追記: 同じ email の重複挿入を避ける — 元は
                // `AccountEditView`のGmail専用「アバター診断」リンクの
                // レイアウト確認だけが目的で、口座が"存在するだけ"でよかった
                // (再挿入のガードも無かった) が、Task #52 でハンバーガー
                // メニューの「アーカイブ」カテゴリマッピング (Gmail の All
                // Mail → アーカイブ、INBOX/Sent/Drafts との重複除外) を検証
                // するため INBOX/All Mail/Sent とメッセージも併せて挿入する
                // ようになった — `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`の
                // 同じ理由 (複数回`app.launch()`する検証手順での重複行防止)
                // でこのガードを追加した。
                guard try AccountRecord.filter(Column("email") == fakeGmailEmail).fetchOne(db) == nil else { return }
                try fakeGmailAccount.insert(db)

                var inbox = MailboxRecord(accountId: fakeGmailAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox)
                try inbox.insert(db)
                var allMail = MailboxRecord(accountId: fakeGmailAccount.id, path: "[Gmail]/All Mail", displayPath: "All Mail", role: .all)
                try allMail.insert(db)
                var sent = MailboxRecord(accountId: fakeGmailAccount.id, path: "[Gmail]/Sent Mail", displayPath: "Sent Mail", role: .sent)
                try sent.insert(db)

                // 「本当にアーカイブ済み」— All Mail にしか無い (INBOX/Sent
                // と重複しない) メッセージ。`GmailArchiveFilter`の定義どおり
                // 「アーカイブ」カテゴリに出るはず。
                var archivedThread = ThreadRecord(accountId: fakeGmailAccount.id, lastMessageDate: Date(), messageCount: 1)
                try archivedThread.insert(db)
                var archivedMessage = MessageRecord(
                    mailboxId: allMail.id!, uid: 1,
                    messageId: "<uitest-fake-gmail-archived@otegami.test>",
                    subject: "アーカイブ済みメール (UITest)", normalizedSubject: "アーカイブ済みメール (UITest)",
                    fromAddresses: [EmailAddress(name: "Otegami QA", address: "qa@example.com")],
                    fromText: "Otegami QA <qa@example.com>",
                    internalDate: Date(),
                    gmailMessageId: 1,
                    threadId: archivedThread.id,
                    // Task #151 (「アーカイブ済みの可視化」): `bodyState:
                    // .fetched`+ a local `MessageBodyRecord` so
                    // `-uitestsOpenGmailArchivedMessageDirectly` (below)
                    // renders `MessageView`'s header immediately, instead of
                    // attempting (and failing) a real network fetch against
                    // this fake account's bogus IMAP host.
                    bodyState: .fetched
                )
                try archivedMessage.insert(db)
                try MessageBodyRecord(
                    messageId: archivedMessage.id!, plainText: "このメールは Task #151 検証用の、すでにアーカイブ済みの fake フィクスチャです。",
                    fetchedAt: Date()
                ).insert(db)
                capturedArchivedThreadId = archivedThread.id

                // 「まだ受信トレイにある (未アーカイブ)」— 同じ物理メールが
                // INBOX と All Mail の両方に (同じ`gmailMessageId`で) 存在する
                // — `GmailArchiveFilter`はこれを「アーカイブ」から除外する
                // はず。
                var inboxThread = ThreadRecord(accountId: fakeGmailAccount.id, lastMessageDate: Date(), messageCount: 2)
                try inboxThread.insert(db)
                var inboxMessage = MessageRecord(
                    mailboxId: inbox.id!, uid: 1,
                    messageId: "<uitest-fake-gmail-unarchived@otegami.test>",
                    subject: "受信トレイのメール (UITest)", normalizedSubject: "受信トレイのメール (UITest)",
                    fromAddresses: [EmailAddress(name: "Otegami QA", address: "qa@example.com")],
                    fromText: "Otegami QA <qa@example.com>",
                    internalDate: Date(),
                    gmailMessageId: 2,
                    threadId: inboxThread.id
                )
                try inboxMessage.insert(db)
                var allMailDuplicate = MessageRecord(
                    mailboxId: allMail.id!, uid: 2,
                    messageId: "<uitest-fake-gmail-unarchived@otegami.test>",
                    subject: "受信トレイのメール (UITest)", normalizedSubject: "受信トレイのメール (UITest)",
                    fromAddresses: [EmailAddress(name: "Otegami QA", address: "qa@example.com")],
                    fromText: "Otegami QA <qa@example.com>",
                    internalDate: Date(),
                    gmailMessageId: 2,
                    threadId: inboxThread.id
                )
                try allMailDuplicate.insert(db)
            }
            // Task #151 (「アーカイブ済みの可視化」検証): `scripts/
            // verify-screen.sh archived-message-detail`向け — タップ無しで
            // 上の「アーカイブ済みメール (UITest)」を直接開き、
            // `MessageHeaderCompactView`の`ArchivedBadge`が出ることを確認
            // する。`uitestDirectOpenThreadId`の既存の仕組み (`MailScreenView
            // .task`) をそのまま再利用 — 新規の画面遷移コードは不要。
            if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_OPEN_GMAIL_ARCHIVED_MESSAGE_DIRECTLY"] == "1" {
                self.uitestDirectOpenThreadId = capturedArchivedThreadId
            }
        }

        // Task #45「ダークモードで文字が読めない・本文が途中で切れる」→
        // Task #51 でその修正の適用条件が広すぎた退行を直した際、同じ
        // escape hatch に2件追加 (下の `uitestFakeHTMLMessages` 参照):
        // same escape hatch as the fake Gmail account above, for the same
        // reason — this simulator/toolchain's account-setup flow has been
        // unreliable against the dev Dovecot mailstack (`MailCoreErrorDomain
        // error 1`, `docs/verify.md`), which makes `OtegamiSecurityNotice
        // DarkModeUITests` unable to depend on a real IMAP round trip to get
        // its fixture messages onto screen. Inserts a fully local account +
        // mailbox + one message/body row per `uitestFakeHTMLMessages` entry
        // directly into GRDB — `bodyState: .fetched` means `MessageView
        // .load()` reads the body straight from this row, never touching
        // the network, so `HTMLMessageView` actually renders real
        // `WKWebView` content (unlike the fake Gmail account above, which
        // only needs to *exist*, never render a body).
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE"] == "1" {
            let fakeAccountEmail = "uitest-fake-html@example.com"
            let fakeAccount = AccountRecord(
                displayName: "Fake HTML Test (UITest)",
                email: fakeAccountEmail,
                authType: .password,
                kind: .generic,
                imapHost: "127.0.0.1",
                imapPort: 1,
                imapSecurity: .plain,
                imapUsername: fakeAccountEmail,
                sortOrder: 1_000
            )
            // Declared here, *outside* the `dbWriter.write` closure below —
            // see that closure's `capturedDirectOpenThreadId` comment for
            // why the assignment to `self.uitestDirectOpenThreadId` has to
            // happen out here too, as a plain statement after the closure
            // returns, not from inside it.
            var capturedDirectOpenThreadId: Int64?
            try? database.dbWriter.write { db in
                // Task #51: `OtegamiSecurityNoticeDarkModeUITests` now has
                // three test methods, each doing its own fresh `app.launch()`
                // with this same env var set — GRDB state (unlike the
                // process) persists across those launches within one
                // simulator install, so without this guard every launch
                // would insert *another* copy of this account/mailbox/
                // messages, leaving duplicate rows in the unified inbox by
                // the second test method (confirmed: `openMessage`'s
                // `.containing(predicate).firstMatch` row lookup then
                // resolves inconsistently against the growing duplicate
                // set, and the tap that's supposed to open the message
                // detail silently fails to navigate — the accessibility
                // hierarchy at the point of failure showed the app still on
                // `messageList.list`, never having reached
                // `messageDetail`/`htmlWebView`). Checking for the account
                // by its fixed fake email first makes every relaunch within
                // the same install idempotent, the same guarantee a real
                // account naturally has (IMAP accounts are unique by
                // email/host in this app).
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(
                    accountId: fakeAccount.id,
                    path: "INBOX",
                    displayPath: "INBOX",
                    role: .inbox,
                    messageCount: Self.uitestFakeHTMLMessages.count
                )
                try mailbox.insert(db)
                // Task #51: each message gets its own `internalDate`, one
                // second apart, rather than all three sharing whatever a
                // single shared `Date()` call would have given them — a
                // three-way sort-order tie (`MessageListView`'s unified
                // inbox sorts newest-first) has no guaranteed-stable
                // tiebreak, so a tied timestamp risks the list re-ordering
                // these rows out from under an in-flight XCUITest tap
                // between when the row is located and when the row is
                // actually pressed. Spacing them out removes the tie
                // instead of relying on a tiebreak being stable.
                let now = Date()
                // Task #56: this simulator/toolchain's `MessageListRow` tap
                // (`.highPriorityGesture`/`.simultaneousGesture` for swipe/
                // long-press-select, per this file's own `docs/verify.md`
                // notes) can fail to register at all — confirmed not specific
                // to this batch's own fixture by reproducing the identical
                // failure on an untouched, previously-passing test in the
                // same suite. `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX`
                // (0-based index into `uitestFakeHTMLMessages`) is the "UITest
                // の直接遷移経路" fallback: threading each fake message right
                // here (rather than waiting for `AccountSyncer`'s own
                // self-heal backfill pass, which needs a foreground sync
                // this offline fake account never gets) means
                // `uitestDirectOpenThreadId` is ready the moment this method
                // returns, so `MailScreenView`'s matching `.task` can push
                // straight to `ThreadEntryView` without any XCUITest tap at
                // all. `ThreadAssigner.assignThread` is safe to call twice
                // for the same message (its own doc comment) — a real
                // foreground sync backfill pass later finding these
                // messages already threaded is a no-op.
                let directOpenIndex = ProcessInfo.processInfo.environment["OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX"].flatMap(Int.init)
                // `capturedDirectOpenThreadId` is captured by reference here
                // (an ordinary local, declared *outside* this closure right
                // above the `dbWriter.write` call) — not a `self.` property
                // write. Writing to `self.uitestDirectOpenThreadId` directly
                // from inside this closure (an earlier version of this
                // change did exactly that) hits "'self' captured by a
                // closure before all members were initialized": this
                // closure runs well before every stored property declared
                // below this point in `init()` has been assigned. The actual
                // `self.uitestDirectOpenThreadId = capturedDirectOpenThreadId`
                // assignment happens after this closure returns instead
                // (below) — the same safe pattern `duplicateMerges` uses
                // further up this file.
                for (index, fixture) in Self.uitestFakeHTMLMessages.enumerated() {
                    let uid = Int64(index + 1)
                    var message = MessageRecord(
                        mailboxId: mailbox.id!,
                        uid: uid,
                        messageId: "<uitest-fake-html-\(uid)@otegami.test>",
                        subject: fixture.subject,
                        normalizedSubject: fixture.subject,
                        fromAddresses: [EmailAddress(name: "Example Security", address: "security-noreply@example.com")],
                        toAddresses: [EmailAddress(name: nil, address: "user@example.com")],
                        fromText: "Example Security <security-noreply@example.com>",
                        internalDate: now.addingTimeInterval(-Double(index)),
                        bodyState: .fetched,
                        snippet: fixture.snippet,
                        detectedLanguage: fixture.detectedLanguage
                    )
                    try message.insert(db)
                    let body = MessageBodyRecord(messageId: message.id!, plainText: nil, html: fixture.html, fetchedAt: Date())
                    try body.insert(db)
                    if index == directOpenIndex {
                        capturedDirectOpenThreadId = try? ThreadAssigner.assignThread(messageId: message.id!, accountId: fakeAccount.id, db: db)
                        // Task #103 ("ソースを表示"): pre-writes this fixture's
                        // own raw-source cache file directly (`MessageSourceFetcher
                        // .prewarmCache` — see its doc comment) so `scripts/
                        // verify-screen.sh message-source`'s `-uitestsOpenMessageSourceDirectly`
                        // shows real fixture content instead of the offline
                        // error state — this fake account's IMAP host
                        // (`127.0.0.1:1`) never actually connects, same
                        // reason `OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE`
                        // below writes its ICS straight to an
                        // `AttachmentRecord.localPath` file instead.
                        //
                        // Task #111 (実機報告: 「ソースを表示」が数十KB級の
                        // 実メールで空白になる): `index == 0`のときだけ、
                        // 合成の引用チェーン (`uitestFakeLargeRawSourceQuoted
                        // History`、実データは含まない) を末尾に足して生
                        // ソースを数十KB級まで水増しする — `message-source`
                        // シナリオ (`scripts/verify-screen.sh`) は常にこの
                        // index 0を開くので、実際にユーザーが再現した
                        // サイズ級でこの画面を検証できる。他のindexの生
                        // ソース (どのシナリオからも表示されない) はそのまま
                        // 小さいまま。
                        let sizeFiller = index == 0 ? "\n\n\(Self.uitestFakeLargeRawSourceQuotedHistory)" : ""
                        let rawSource = """
                            From: Example Security <security-noreply@example.com>\r
                            To: user@example.com\r
                            Subject: \(fixture.subject)\r
                            Content-Type: text/html; charset=UTF-8\r
                            \r
                            \(fixture.html)\(sizeFiller)
                            """
                        try? MessageSourceFetcher.prewarmCache(
                            accountId: fakeAccount.id, messageId: message.id!, data: Data(rawSource.utf8)
                        )
                    }
                }
            }
            self.uitestDirectOpenThreadId = capturedDirectOpenThreadId
        }

        // Task #66 (カレンダー招待メール対応): same "insert a fully local,
        // already-`.fetched` fake message" escape hatch as
        // `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` above and for the same
        // reason (this simulator/toolchain's IMAP connectivity is
        // unreliable — `docs/verify.md`) — `scripts/verify-screen.sh
        // calendar-invite`'s only way to get `CalendarInviteSectionView`
        // on screen without a real IMAP/attachment-download round trip.
        // Unlike the HTML fixtures (whose body is inline `MessageBodyRecord
        // .html`), the invite card reads its `text/calendar` content from
        // an `AttachmentRecord.localPath` file on disk (the same shape a
        // real download leaves behind — see `CalendarInviteSectionView
        // .loadICSText()`), so this writes the fixture ICS text to a real
        // temp file and points the inserted attachment row at it, rather
        // than needing `AttachmentFetcher`/a network fetch to populate it.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE"] == "1" {
            let fakeAccountEmail = "uitest-fake-calendar-invite@example.com"
            let fakeAccount = AccountRecord(
                displayName: "Fake Calendar Invite (UITest)",
                email: fakeAccountEmail,
                authType: .password,
                kind: .generic,
                imapHost: "127.0.0.1",
                imapPort: 1,
                imapSecurity: .plain,
                imapUsername: fakeAccountEmail,
                sortOrder: 1_001
            )
            var capturedThreadId: Int64?
            try? database.dbWriter.write { db in
                // Idempotent across repeated `app.launch()`s within the
                // same install — same rationale/guard as the HTML fixture
                // block above.
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(accountId: fakeAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox, messageCount: 1)
                try mailbox.insert(db)

                let icsText = Self.uitestFakeCalendarInviteICS.replacingOccurrences(of: "\n", with: "\r\n")
                let icsURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("otegami-uitest-calendar-invite.ics")
                try? icsText.data(using: .utf8)?.write(to: icsURL, options: .atomic)

                var message = MessageRecord(
                    mailboxId: mailbox.id!,
                    uid: 1,
                    messageId: "<uitest-fake-calendar-invite@otegami.test>",
                    subject: "Invitation: 四半期計画会議 (Quarterly Planning Sync)",
                    normalizedSubject: "Invitation: 四半期計画会議 (Quarterly Planning Sync)",
                    fromAddresses: [EmailAddress(name: "Otegami Organizer", address: "organizer@otegami.test")],
                    toAddresses: [EmailAddress(address: fakeAccountEmail)],
                    fromText: "Otegami Organizer <organizer@otegami.test>",
                    internalDate: Date(),
                    hasAttachments: true,
                    bodyState: .fetched,
                    snippet: "四半期の計画会議です。事前に資料をご確認ください。"
                )
                try message.insert(db)
                let body = MessageBodyRecord(
                    messageId: message.id!,
                    plainText: "四半期の計画会議です。事前に資料をご確認ください。",
                    html: Self.uitestFakeCalendarInviteHTML,
                    fetchedAt: Date()
                )
                try body.insert(db)
                var attachment = AttachmentRecord(
                    messageId: message.id!,
                    partId: "2",
                    filename: nil,
                    mimeType: "text",
                    mimeSubtype: "calendar",
                    isInline: false,
                    size: icsText.utf8.count,
                    localPath: icsURL.path
                )
                try attachment.insert(db)
                // Task #84: a real Google Calendar invite also carries a
                // separately named `invite.ics` (`application/ics`)
                // attachment alongside the unnamed `text/calendar` part
                // above — both should be recognized as the same invite and
                // hidden from the plain attachment list (`MessageView
                // .listableAttachments`), not just the one driving the
                // card. This second row exercises that "hide every
                // recognized invite part, not only the one used" behavior
                // in `scripts/verify-screen.sh calendar-invite` screenshots.
                var icsAttachment = AttachmentRecord(
                    messageId: message.id!,
                    partId: "3",
                    filename: "invite.ics",
                    mimeType: "application",
                    mimeSubtype: "ics",
                    isInline: false,
                    size: icsText.utf8.count,
                    localPath: icsURL.path
                )
                try icsAttachment.insert(db)
                capturedThreadId = try? ThreadAssigner.assignThread(messageId: message.id!, accountId: fakeAccount.id, db: db)
            }
            self.uitestDirectOpenThreadId = capturedThreadId
        }

        // Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列
        // 表示」): same "insert a fully local, already-`.fetched` fake
        // message" escape hatch as `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`
        // above and for the same reason — `scripts/verify-screen.sh
        // quote-history`'s only way to get `QuoteHistorySectionView`'s
        // card on screen without a real IMAP round trip. Unlike that
        // fixture, this one is plain text (`MessageBodyRecord.plainText`,
        // no `html`) — `QuoteHistorySectionView` is deliberately scoped to
        // genuinely plain-text mail (see `MessageView
        // .plainTextQuoteHistorySplit`'s doc comment) — and models the same
        // three-level-deep top-posted reply chain shape
        // `QuoteHistoryParserTests`' own fixture exercises (each level's
        // attribution line at its own nesting depth, that level's body one
        // `>` deeper still), so this screenshot and those unit tests are
        // checking the same real-world shape end to end.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_QUOTED_PLAIN_MESSAGE"] == "1" {
            let fakeAccountEmail = "uitest-fake-quoted-plain@example.com"
            let fakeAccount = AccountRecord(
                displayName: "Fake Quoted Plain Test (UITest)",
                email: fakeAccountEmail,
                authType: .password,
                kind: .generic,
                imapHost: "127.0.0.1",
                imapPort: 1,
                imapSecurity: .plain,
                imapUsername: fakeAccountEmail,
                sortOrder: 1_002
            )
            var capturedThreadId: Int64?
            try? database.dbWriter.write { db in
                // Idempotent across repeated `app.launch()`s within the
                // same install — same rationale/guard as the HTML fixture
                // block above.
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(accountId: fakeAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox, messageCount: 1)
                try mailbox.insert(db)

                var message = MessageRecord(
                    mailboxId: mailbox.id!,
                    uid: 1,
                    messageId: "<uitest-fake-quoted-plain@otegami.test>",
                    inReplyTo: "<uitest-fake-quoted-plain-parent@otegami.test>",
                    subject: "Re: 定例ミーティングの件 (UITest)",
                    normalizedSubject: "定例ミーティングの件 (UITest)",
                    fromAddresses: [EmailAddress(name: "山田太郎", address: "yamada@example.com")],
                    toAddresses: [EmailAddress(name: "田中花子", address: "tanaka@example.com")],
                    fromText: "山田太郎 <yamada@example.com>",
                    internalDate: Date(),
                    bodyState: .fetched,
                    snippet: "資料のご確認ありがとうございます。来週の定例はオンラインで問題ありません。"
                )
                try message.insert(db)
                let body = MessageBodyRecord(
                    messageId: message.id!,
                    plainText: Self.uitestFakeQuotedPlainMessageBody,
                    html: nil,
                    fetchedAt: Date()
                )
                try body.insert(db)
                capturedThreadId = try? ThreadAssigner.assignThread(messageId: message.id!, accountId: fakeAccount.id, db: db)
            }
            self.uitestDirectOpenThreadId = capturedThreadId
        }

        // Task #136 (実機フィードバック「スレッド表示 ON の本文画面を
        // アコーディオンに戻してほしい」): same "insert a fully local,
        // already-`.fetched` fake message" escape hatch as
        // `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` above — `scripts/
        // verify-screen.sh`'s only way to get a genuinely multi-message
        // thread (`ThreadDetailView`'s accordion, one row per message) on
        // screen without a real IMAP/threading round trip. Unlike every
        // other fixture in this file, this one assembles its `ThreadRecord`
        // and 3 `MessageRecord`s directly with a shared `threadId` (the same
        // technique the Gmail archive-filter fixture's `inboxThread` above
        // uses) rather than going through `ThreadAssigner.assignThread` —
        // simpler and fully deterministic than getting `Threader`'s
        // References/subject-matching heuristics to actually join 3
        // messages the way a real reply chain would, when all this needs is
        // "3 distinct messages, one thread, in order". One plain-text
        // message in the middle of two HTML ones exercises both rendering
        // paths across accordion row switches (the newest, HTML, is what
        // opens expanded by default) — see `docs/design-system.md`'s
        // Task #136 節 for why this matters (WKWebView height-reporting
        // across repeated expand/collapse, previously only exercised by
        // macOS's always-on accordion, never iOS's push navigation before
        // this task).
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_MULTI_MESSAGE_THREAD"] == "1" {
            let fakeAccountEmail = "uitest-fake-multi-message-thread@example.com"
            let fakeAccount = AccountRecord(
                displayName: "Fake Multi-Message Thread (UITest)",
                email: fakeAccountEmail,
                authType: .password,
                kind: .generic,
                imapHost: "127.0.0.1",
                imapPort: 1,
                imapSecurity: .plain,
                imapUsername: fakeAccountEmail,
                sortOrder: 1_003
            )
            var capturedThreadId: Int64?
            try? database.dbWriter.write { db in
                // Idempotent across repeated `app.launch()`s within the
                // same install — same rationale/guard as the HTML fixture
                // block above.
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(accountId: fakeAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox, messageCount: 3)
                try mailbox.insert(db)

                let subject = "四半期振り返りミーティングの日程調整 (UITest)"
                var thread = ThreadRecord(accountId: fakeAccount.id, normalizedSubject: subject, messageCount: 0, unreadCount: 0)
                try thread.insert(db)
                guard let threadId = thread.id else { return }

                let now = Date()
                // Task #51 と同じ理由 (同秒タイムスタンプの並び順不安定さ回避)
                // — 1秒ずつずらす。oldest-first で insert する。
                var original = MessageRecord(
                    mailboxId: mailbox.id!, uid: 1,
                    messageId: "<uitest-fake-multi-thread-1@otegami.test>",
                    subject: subject, normalizedSubject: subject,
                    fromAddresses: [EmailAddress(name: "田中花子", address: "tanaka@example.com")],
                    toAddresses: [EmailAddress(address: fakeAccountEmail)],
                    fromText: "田中花子 <tanaka@example.com>",
                    internalDate: now.addingTimeInterval(-200),
                    flagsRaw: MessageFlags.seen.rawValue,
                    threadId: threadId,
                    bodyState: .fetched,
                    snippet: "来週の四半期振り返りミーティングですが、火曜または木曜の午後でご都合いかがでしょうか。"
                )
                try original.insert(db)
                try MessageBodyRecord(
                    messageId: original.id!,
                    plainText: "来週の四半期振り返りミーティングですが、火曜または木曜の午後でご都合いかがでしょうか。\n\nよろしくお願いします。",
                    html: nil, fetchedAt: Date()
                ).insert(db)

                var reply1 = MessageRecord(
                    mailboxId: mailbox.id!, uid: 2,
                    messageId: "<uitest-fake-multi-thread-2@otegami.test>",
                    inReplyTo: "<uitest-fake-multi-thread-1@otegami.test>",
                    subject: "Re: \(subject)", normalizedSubject: subject,
                    fromAddresses: [EmailAddress(name: "佐藤次郎", address: "sato@example.com")],
                    toAddresses: [EmailAddress(name: "田中花子", address: "tanaka@example.com")],
                    fromText: "佐藤次郎 <sato@example.com>",
                    internalDate: now.addingTimeInterval(-100),
                    flagsRaw: MessageFlags.seen.rawValue,
                    threadId: threadId,
                    bodyState: .fetched,
                    snippet: "木曜の午後14:00でお願いします。会議室は空いていますか。"
                )
                try reply1.insert(db)
                try MessageBodyRecord(
                    messageId: reply1.id!, plainText: nil,
                    html: "<p>木曜の午後14:00でお願いします。会議室は空いていますか。</p>",
                    fetchedAt: Date()
                ).insert(db)

                var reply2 = MessageRecord(
                    mailboxId: mailbox.id!, uid: 3,
                    messageId: "<uitest-fake-multi-thread-3@otegami.test>",
                    inReplyTo: "<uitest-fake-multi-thread-2@otegami.test>",
                    subject: "Re: \(subject)", normalizedSubject: subject,
                    fromAddresses: [EmailAddress(name: "田中花子", address: "tanaka@example.com")],
                    toAddresses: [EmailAddress(name: "佐藤次郎", address: "sato@example.com")],
                    fromText: "田中花子 <tanaka@example.com>",
                    internalDate: now,
                    threadId: threadId,
                    bodyState: .fetched,
                    snippet: "承知しました、木曜14:00で確定します。会議室Aを予約してカレンダー招待を送ります。"
                )
                try reply2.insert(db)
                try MessageBodyRecord(
                    messageId: reply2.id!, plainText: nil,
                    html: "<p>承知しました、木曜14:00で確定します。</p><p>会議室Aを予約してカレンダー招待を送ります。</p>",
                    fetchedAt: Date()
                ).insert(db)

                try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                capturedThreadId = threadId
            }
            if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_OPEN_MULTI_MESSAGE_THREAD_DIRECTLY"] == "1" {
                self.uitestDirectOpenThreadId = capturedThreadId
            }
        }

        // Task #142 (一覧ヘッダの「フラグ付きのみ表示」トグル):
        // `scripts/verify-screen.sh list-pinned-only`向け — 1件ピン留め済み
        // + 1件未ピンのfakeメッセージを挿入する。`OTEGAMI_UITEST_INSERT_FAKE_
        // HTML_MESSAGE`と同じ「オフラインの完結したfakeアカウント」パターン
        // だが、こちらは`MessageRecord.isPinnedLocal`をシード時に直接立てる
        // 点だけが違う (ピン留め操作自体はタップ操作なのでこのシミュレータ/
        // ツールチェーンでは検証できない — `docs/verify.md`の既知不調)。
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_PINNED_MESSAGE"] == "1" {
            let fakeAccountEmail = "uitest-fake-pinned@example.com"
            let fakeAccount = AccountRecord(
                displayName: "Fake Pinned Test (UITest)",
                email: fakeAccountEmail,
                authType: .password,
                kind: .generic,
                imapHost: "127.0.0.1",
                imapPort: 1,
                imapSecurity: .plain,
                imapUsername: fakeAccountEmail,
                sortOrder: 1_004
            )
            try? database.dbWriter.write { db in
                // Idempotent across repeated `app.launch()`s within the same
                // install — same rationale/guard as the fixtures above.
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(accountId: fakeAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox, messageCount: 2)
                try mailbox.insert(db)

                let now = Date()
                var pinnedThread = ThreadRecord(accountId: fakeAccount.id, normalizedSubject: "フラグ付きのテストメール (UITest)", messageCount: 0, unreadCount: 0)
                try pinnedThread.insert(db)
                var pinned = MessageRecord(
                    mailboxId: mailbox.id!, uid: 1,
                    messageId: "<uitest-fake-pinned-1@otegami.test>",
                    subject: "フラグ付きのテストメール (UITest)", normalizedSubject: "フラグ付きのテストメール (UITest)",
                    fromAddresses: [EmailAddress(name: "Pinned Sender", address: "pinned@example.com")],
                    toAddresses: [EmailAddress(address: fakeAccountEmail)],
                    fromText: "Pinned Sender <pinned@example.com>",
                    internalDate: now,
                    threadId: pinnedThread.id,
                    bodyState: .fetched,
                    snippet: "このメールはフラグ付き (ピン留め) のfakeフィクスチャです。",
                    isPinnedLocal: true
                )
                try pinned.insert(db)
                try ThreadAssigner.recomputeAggregates(threadId: pinnedThread.id!, db: db)

                var unpinnedThread = ThreadRecord(accountId: fakeAccount.id, normalizedSubject: "フラグ無しのテストメール (UITest)", messageCount: 0, unreadCount: 0)
                try unpinnedThread.insert(db)
                var unpinned = MessageRecord(
                    mailboxId: mailbox.id!, uid: 2,
                    messageId: "<uitest-fake-pinned-2@otegami.test>",
                    subject: "フラグ無しのテストメール (UITest)", normalizedSubject: "フラグ無しのテストメール (UITest)",
                    fromAddresses: [EmailAddress(name: "Regular Sender", address: "regular@example.com")],
                    toAddresses: [EmailAddress(address: fakeAccountEmail)],
                    fromText: "Regular Sender <regular@example.com>",
                    internalDate: now.addingTimeInterval(-60),
                    threadId: unpinnedThread.id,
                    bodyState: .fetched,
                    snippet: "このメールはフラグ無しのfakeフィクスチャです。"
                )
                try unpinned.insert(db)
                try ThreadAssigner.recomputeAggregates(threadId: unpinnedThread.id!, db: db)
            }
        }

        self.syncCoordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: { draft in MailCoreMessageBuilder.build(draft) }
        )
        // `credentialStore` itself was constructed further up — see the
        // duplicate-account-merge block's comment on why.

        // design-phase-3: see `translationService`/`messageTranslator`'s
        // doc comments.
        //
        // `OTEGAMI_UITEST_FAKE_TRANSLATION`: this project's Simulator/host
        // combination can't actually run Foundation Models from inside the
        // sandboxed `.app` process (`FoundationModelsTranslationService.translateParagraphs`
        // consistently throws `FoundationModels.LanguageModelError error -1`
        // there, confirmed not a code bug — the identical call succeeds in
        // 2-5s run instead as a plain `swift test` process on the same host;
        // `docs/translation.md`'s "既知の制限" section has the full
        // writeup). That makes the HTML-preserving translation display path
        // (1i) impossible to verify end-to-end via a real on-device
        // translation on this Simulator — this flag substitutes
        // `FakeTranslationService` (deterministic `"[ja] ..."` output, no
        // Apple Intelligence dependency) so a UITest/manual verify run can
        // still drive the actual DOM-rewrite/layout-preservation code path,
        // matching this file's other `OTEGAMI_UITEST_*` launch-environment
        // overrides (`deleteCredentialIfUITestRequested`'s doc comment in
        // `MessageView`, `OTEGAMI_UITEST_DISABLE_CLOUD_SYNC` below).
        let translationService: any TranslationService
        let translationEngineIdentifier: String
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FAKE_TRANSLATION"] == "1" {
            translationService = FakeTranslationService()
            translationEngineIdentifier = MessageTranslator.EngineIdentifier.fake
        } else {
            translationService = FoundationModelsTranslationService()
            translationEngineIdentifier = MessageTranslator.EngineIdentifier.foundationModels
        }
        self.translationService = translationService
        self.messageTranslator = MessageTranslator(
            database: database,
            service: translationService,
            engineIdentifier: translationEngineIdentifier
        )

        let pushSettings = PushSettingsStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)
        self.pushSettings = pushSettings
        self.isPushEnabled = pushSettings.isEnabled
        self.pushRelayURLString = pushSettings.relayURLString ?? ""

        if let endpoints = GoogleOAuthConfig.endpoints {
            let client = GoogleOAuthClient(
                endpoints: endpoints,
                // Explicitly `GoogleOAuth.` — `MicrosoftOAuth` (imported
                // below for the Microsoft branch right after this one)
                // declares its own identically-named
                // `ASWebAuthenticationSessionRunner`/`AuthorizationSessionRunning`
                // (a deliberate mirror, see that type's doc comment), so the
                // bare name is ambiguous once both modules are imported into
                // the same file.
                sessionRunner: GoogleOAuth.ASWebAuthenticationSessionRunner(presentationContextProvider: AuthPresentationContextProvider())
            )
            self.googleOAuthClient = client
            self.tokenStore = GoogleOAuth.TokenStore(refresher: client)
        } else {
            self.googleOAuthClient = nil
            self.tokenStore = nil
        }

        // Task #116 第2段: same shape as the Google branch just above, for
        // Outlook.com/Office 365. `ASWebAuthenticationSessionRunner` here is
        // `MicrosoftOAuth`'s own copy (a deliberate mirror of `GoogleOAuth`'s
        // — see that type's doc comment), not the Google one, even though
        // both are named identically — Swift resolves each to the type from
        // its own module since neither call site imports both unqualified
        // in a way that's ambiguous here (the module is inferred from
        // `MicrosoftOAuthClient`'s own parameter type).
        if let endpoints = MicrosoftOAuthConfig.endpoints {
            let client = MicrosoftOAuthClient(
                endpoints: endpoints,
                sessionRunner: MicrosoftOAuth.ASWebAuthenticationSessionRunner(presentationContextProvider: AuthPresentationContextProvider())
            )
            self.microsoftOAuthClient = client
            self.microsoftTokenStore = MicrosoftOAuth.TokenStore(refresher: client)
        } else {
            self.microsoftOAuthClient = nil
            self.microsoftTokenStore = nil
        }

        // M11: iCloud account sync. `directory` bundles everything
        // `AccountCloudSyncEngine` needs to actually apply a reconcile
        // decision locally — see `CloudAccountDirectory`'s doc comment for
        // why it holds these references directly instead of AppEnvironment
        // passing itself in via callback closures.
        let cloudSyncSettings = CloudSyncSettingsStore()
        self.cloudSyncSettings = cloudSyncSettings
        self.isCloudSyncEnabled = cloudSyncSettings.isEnabled
        let directory = CloudAccountDirectory(
            database: database,
            credentialStore: credentialStore,
            tokenStore: tokenStore,
            microsoftTokenStore: microsoftTokenStore,
            syncCoordinator: syncCoordinator,
            pushSettings: pushSettings,
            pushRelayClient: pushRelayClient
        )
        self.accountCloudSync = AccountCloudSyncEngine(
            store: SystemUbiquitousStore(),
            local: directory,
            isEnabled: { [cloudSyncSettings] in
                cloudSyncSettings.isEnabled && AppEnvironment.isCloudSyncPermittedOnThisBuild()
            }
        )
        self.settingsCloudSync = SettingsCloudSyncEngine(
            store: SystemUbiquitousStore(),
            local: AppSettingsCloudDirectory(),
            isEnabled: { [cloudSyncSettings] in
                cloudSyncSettings.isEnabled && AppEnvironment.isCloudSyncPermittedOnThisBuild()
            }
        )

        // Tear down whatever per-device state (cached `AccountSyncer`/
        // `IDLE` loop, Keychain password, OAuth tokens, registered push
        // watch) the duplicate-merge pass above left behind for each
        // merged-away account id — the DB row is already gone by this
        // point (deleted inside the synchronous merge above), so this only
        // ever needs the id, never the full `AccountRecord`
        // (`CloudAccountDirectory.cleanupAfterDuplicateMerge`'s doc
        // comment). Captures `directory` (a `Sendable` struct), not
        // `self`, matching the `cloudSync`-only capture the reconcile
        // `Task` right below already uses.
        if !duplicateMerges.isEmpty {
            let mergedAwayAccountIds = duplicateMerges.flatMap(\.mergedAccountIds)
            Task {
                for accountId in mergedAwayAccountIds {
                    await directory.cleanupAfterDuplicateMerge(accountId: accountId)
                }
            }
        }

        // C6/C7: wired last, once every other stored property has a value
        // (Swift's two-phase init rule — `self` can't be handed to
        // anything, even just to store a `weak` back-reference, until then).
        pendingSendCoordinator.configure(environment: self)
        // アバター強化バッチ「Google プロフィール写真」: same reasoning,
        // same timing — see `GmailAccessTokenBridge`'s doc comment.
        gmailAccessTokenBridge.configure(environment: self)

        startObservingAccounts()

        // M7: defensive self-heal, in addition to the v7 migration's own
        // one-time backfill (`AppDatabase`) — cheap once caught up (a
        // single `NOT EXISTS` scan that finds nothing), so running it again
        // on every launch costs effectively nothing but guards against any
        // future code path that ever inserts a `message` row without going
        // through `AccountSyncer.upsert`/`BodyFetcher.fetchBody`.
        Task { [database] in
            try? await database.dbWriter.write { db in
                try FTSIndexer.backfillIfNeeded(db: db)
            }
        }

        // M11: reconcile once at launch, then again every time iCloud
        // reports the KVS payload changed externally (another device
        // pushed while this one wasn't running, or just now). Every actual
        // side effect (inserting/updating/deleting an `AccountRecord`,
        // starting a first sync, registering/tearing down a push watch)
        // happens inside `accountCloudSync`/`directory` themselves — see
        // `CloudAccountDirectory`'s doc comment — so the observer here only
        // ever needs to call `reconcile()` and can capture the engine
        // itself (an actor, `Sendable`) rather than `self`.
        // Task #89: `settingsCloudSync` reconciles alongside
        // `accountCloudSync` at every one of the same trigger points (launch,
        // external KVS change) — both share the single `didChangeExternally
        // Notification` observer below rather than each registering its own,
        // since the notification doesn't say *which* key changed and both
        // engines' `reconcile()` calls are cheap no-ops when nothing relevant
        // changed. Settings sync additionally reconciles on every foreground/
        // background scene-phase transition (`OtegamiApp.handleScenePhase
        // Change`) — see `SettingsCloudSyncEngine`'s doc comment for why a
        // transition-triggered diff stands in for a per-write push hook.
        let cloudSync = accountCloudSync
        let settingsSync = settingsCloudSync
        Task {
            await cloudSync.reconcile()
            await settingsSync.reconcile()
        }
        cloudSyncNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: nil
        ) { _ in
            Task {
                await cloudSync.reconcile()
                await settingsSync.reconcile()
            }
        }
        // Task #101: see `settingsChangeNotificationObserver`'s doc comment
        // — debounced, so this only calls `reconcile()` a few seconds after
        // the last `UserDefaults.standard` write rather than on every one.
        settingsChangeNotificationObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSettingsPush()
            }
        }

        // C「既読メール再表示の高速化」(実機フィードバック第3弾) — see
        // `HTMLWebViewPrewarmer`'s doc comment. Deferred to a `Task` (not
        // called synchronously here) so warming up a `WKWebView` never
        // delays `RootView`'s first render.
        Task { @MainActor in
            HTMLWebViewPrewarmer.prewarm()
        }
    }

    deinit {
        accountsObservationTask?.cancel()
        badgeObservationTask?.cancel()
        settingsChangeDebounceTask?.cancel()
        if let cloudSyncNotificationObserver {
            NotificationCenter.default.removeObserver(cloudSyncNotificationObserver)
        }
        if let settingsChangeNotificationObserver {
            NotificationCenter.default.removeObserver(settingsChangeNotificationObserver)
        }
    }

    /// Task #101: restarts a short debounce timer on every `UserDefaults
    /// .standard` write — cancelling and replacing any still-pending one —
    /// so a burst of writes (e.g. a picker view that updates a couple of
    /// keys in quick succession) only triggers one `settingsCloudSync
    /// .reconcile()` call after things go quiet, not one per write.
    /// `reconcile()` itself is cheap when nothing in the allowlist actually
    /// changed (`SettingsCloudSyncEngine`'s doc comment), so firing it more
    /// often than strictly necessary here is a non-issue; the debounce
    /// exists to avoid a `Task.sleep` pile-up, not to protect `reconcile()`.
    private func scheduleDebouncedSettingsPush() {
        settingsChangeDebounceTask?.cancel()
        let settingsSync = settingsCloudSync
        settingsChangeDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await settingsSync.reconcile()
        }
    }

    /// The launch-time rescue for a device already left with an orphaned
    /// Keychain credential by a *previous* bad duplicate-account merge —
    /// see the two call sites in `init()` for the full picture (this is
    /// "part 2", the one that still helps on a later launch after the
    /// duplicate `account` rows themselves are long gone). `static` (not an
    /// instance method) and takes `database`/`credentialStore` as
    /// parameters rather than reading `self.database`/`self.credentialStore`
    /// because it runs from inside `init()` before `self` exists as a fully
    /// formed value — the exact same constraint the duplicate-merge block
    /// right above it in `init()` is already under.
    ///
    /// Deliberately conservative: only acts when there is exactly one
    /// `.password` account missing a working credential *and* exactly one
    /// Keychain item whose accountId matches no live account at all. Either
    /// count being 0 or ≥2 means this can't tell which orphan (if any)
    /// belongs to which account without guessing, so it does nothing and
    /// leaves the existing "パスワードを入力" flow (`AccountsSettingsView`) as
    /// the way out — silently reassigning the wrong password to the wrong
    /// account would be a far worse failure mode than leaving the banner up.
    @discardableResult
    private static func adoptOrphanedCredentialIfUnambiguous(
        database: AppDatabase, credentialStore: KeychainCredentialStore
    ) -> String? {
        guard let accounts = try? database.dbWriter.read({ db in try AccountRecord.fetchAll(db) }) else { return nil }
        let knownAccountIds = Set(accounts.map(\.id))

        let needyAccounts = accounts.filter { account in
            account.authType == .password
                && ((try? credentialStore.password(forAccountId: account.id)) ?? nil) == nil
        }
        guard needyAccounts.count == 1, let needyAccount = needyAccounts.first else { return nil }

        let orphanAccountIds = credentialStore.allStoredAccountIds().subtracting(knownAccountIds)
        guard orphanAccountIds.count == 1, let orphanAccountId = orphanAccountIds.first else { return nil }

        guard (try? credentialStore.adoptOrphanedPassword(
            fromAccountId: orphanAccountId, toAccountId: needyAccount.id
        )) == true else { return nil }

        try? database.dbWriter.write { db in
            guard var row = try AccountRecord.fetchOne(db, key: needyAccount.id) else { return }
            row.needsReauth = false
            try row.update(db)
        }
        return needyAccount.id
    }

    private func startObservingAccounts() {
        // アカウントの並び替え: `sortOrder` first (what a drag reorder
        // actually changes), `createdAt` only as a tiebreaker for rows that
        // happen to share a `sortOrder` (pre-migration backfill gives every
        // row a distinct value already, but this stays deterministic for
        // e.g. a brief post-`reconcile()` collision). Every account-order-
        // sensitive UI (`FolderListSheet`, `AccountFilterChipRow`,
        // `ComposerView`'s From picker, `AccountSettingsCategoryView`) reads
        // straight off `self.accounts`, so this one query is the single
        // place account order is decided.
        let observation = ValueObservation.tracking { db in
            try AccountRecord.order(Column("sortOrder"), Column("createdAt")).fetchAll(db)
        }
        accountsObservationTask = Task { [database] in
            do {
                for try await accounts in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    self.accounts = accounts
                    await restartBadgeObservationIfNeeded(accountIds: accounts.map(\.id))
                    // Backfill (M4): thread every not-yet-threaded message
                    // for each known account. Covers both a brand new
                    // account (belt-and-suspenders — `AccountSyncer`
                    // already threads as part of its own sync passes) and,
                    // more importantly, accounts synced before M4 shipped,
                    // whose `message.threadId` is still `nil` for every
                    // row. Cheap to re-run on every account-list tick: once
                    // an account's messages are threaded, the query this
                    // backs (`threadId IS NULL`) simply returns nothing.
                    for account in accounts {
                        try? await database.dbWriter.write { db in
                            try ThreadAssigner.assignAllUnthreaded(accountId: account.id, db: db)
                        }
                        // M11: see `retryPendingCredentialIfAvailable`'s doc
                        // comment — the "起動時再チェック" half of that
                        // method's two retry paths.
                        await retryPendingCredentialIfAvailable(account)
                    }
                }
            } catch {
                // A failing account-list observation shouldn't be fatal —
                // the sidebar just won't update further until relaunch.
            }
        }
    }

    /// H「アプリアイコンの未読バッジ」→ G「アイコンバッジの on/off 設定を
    /// アプリから削除」(実機フィードバック第3弾): (re)subscribes to
    /// `MessageQuery.unifiedInboxUnreadCountObservation(accountIds:)` and
    /// pushes every update to `BadgeCenter.setBadge(count:)` — this single
    /// `ValueObservation` is what covers "既読操作・同期・フォアグラウンド
    /// 復帰での更新" all at once (every one of those already writes to
    /// `message`/mutates flags through the same tables this query reads, so
    /// the observation fires on its own without any scene-phase-specific
    /// code here). Called from `startObservingAccounts()`'s loop on every
    /// `accounts` change, since `accountIds` has to track the current list
    /// — cancels and replaces any previous subscription rather than
    /// accumulating one per account change.
    ///
    /// G: the app's own on/off toggle (`BadgeSettingsStore`) is gone —
    /// whether the badge shows now follows **the OS's own notification
    /// settings** (設定 → 通知 → otegami → バッジ) exclusively, checked via
    /// `UNUserNotificationCenter.current().notificationSettings()
    /// .badgeSetting` on iOS. macOS keeps the unconditional pre-G behavior
    /// (`NSApplication.dockTile.badgeLabel` needs no permission at all, so
    /// there's no OS setting to defer to there — `BadgeCenter.setBadge
    /// (count:)`'s doc comment). `refreshBadgeObservation()` is public so
    /// `RootView.handleScenePhaseChange(.active)` can re-check on every
    /// foreground return — the OS setting can change at any time in
    /// Settings.app while this app is backgrounded, and there's no
    /// notification this app receives when that happens.
    func refreshBadgeObservation() {
        Task { await restartBadgeObservationIfNeeded(accountIds: accounts.map(\.id)) }
    }

    private func restartBadgeObservationIfNeeded(accountIds: [String]) async {
        badgeObservationTask?.cancel()
        #if os(iOS)
        if !hasRequestedBadgeAuthorization {
            hasRequestedBadgeAuthorization = true
            await BadgeCenter.requestAuthorizationIfNeeded()
        }
        // G: `.notDetermined`/`.disabled` both mean "OS says don't show a
        // badge" from this app's point of view — the request above only
        // resolves `.notDetermined` the *first* time this ever runs (a
        // decision, once made, persists); every call still re-fetches
        // current settings so a user who changes their mind in Settings.app
        // is picked up the next time this runs (see `refreshBadgeObservation`'s
        // doc comment on why `RootView` calls this on every foreground
        // return, not just once).
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        guard notificationSettings.badgeSetting == .enabled else {
            BadgeCenter.setBadge(count: 0)
            return
        }
        #endif
        guard !accountIds.isEmpty else {
            BadgeCenter.setBadge(count: 0)
            return
        }
        let observation = MessageQuery.unifiedInboxUnreadCountObservation(accountIds: accountIds)
        badgeObservationTask = Task { [database] in
            do {
                for try await count in observation.values(in: database.dbWriter) {
                    guard !Task.isCancelled else { return }
                    BadgeCenter.setBadge(count: count)
                }
            } catch {
                // Best-effort — a failing observation just leaves the badge
                // at whatever it last showed, same "not fatal" shape as
                // `startObservingAccounts()`'s own catch above.
            }
        }
    }

    /// Removes an account entirely (Settings → account list → delete):
    /// stops its `IDLE` loop, deletes the Keychain password, then deletes
    /// its `account` row — every `mailbox`/`message`/`thread`/`opQueue` row
    /// referencing it cascades via the schema's `onDelete: .cascade`
    /// foreign keys (`AppDatabase`'s migrator), so this one delete is
    /// enough to fully remove the account's local data too.
    func deleteAccount(_ account: AccountRecord) async {
        await syncCoordinator.stopIdleLoop(for: account)
        try? credentialStore.deletePassword(forAccountId: account.id)
        if let tokenStore {
            try? await tokenStore.clearTokens(for: account.id)
        }
        // M9: an account's watch (if push is enabled and one exists for
        // it) has to go too — otherwise the relay would keep IDLE-ing an
        // IMAP credential for an account this app no longer even knows
        // about.
        await unregisterWatch(forAccountId: account.id)
        try? await database.dbWriter.write { db in
            // M7: `account`→`mailbox`→`message` cascades via `onDelete:
            // .cascade` foreign keys, but `messageSearchIndex` is a virtual
            // table with no FK support — its rows for this account's
            // messages have to be removed explicitly, before the cascade
            // wipes the `message` rows that would otherwise identify them.
            let messageIds = try Int64.fetchAll(
                db,
                sql: """
                    SELECT message.id FROM message
                    JOIN mailbox ON mailbox.id = message.mailboxId
                    WHERE mailbox.accountId = ?
                    """,
                arguments: [account.id]
            )
            try FTSIndexer.deleteAll(messageIds: messageIds, db: db)
            _ = try account.delete(db)
        }
        // M11: this deletion is user-initiated here (as opposed to one
        // `CloudAccountDirectory.deleteLocally` runs in response to a
        // tombstone that already exists) — push a fresh tombstone so every
        // other device syncing this Apple ID's iCloud account picks up the
        // deletion too.
        await accountCloudSync.pushLocalDeletion(accountId: account.id)
    }

    // MARK: - Account ordering

    /// The `sortOrder` a brand-new account should be created with — one past
    /// whatever's currently highest, so a freshly-added account always lands
    /// at the *end* of every account-ordered list rather than jumping to an
    /// arbitrary position. Reads `self.accounts` (already the live,
    /// correctly-ordered result of `startObservingAccounts`'s
    /// `ValueObservation`) rather than issuing a fresh DB query — cheap, and
    /// exactly the list every call site (`AccountSetupView`,
    /// `ICloudAccountSetupView`, `createGmailAccount`) would otherwise have
    /// had to read for itself.
    func nextAccountSortOrder() -> Int {
        (accounts.map(\.sortOrder).max() ?? -1) + 1
    }

    /// The `labelColorKey` a brand-new account should be created with —
    /// Task #72「自動割当の改善」: the palette color whose hue is farthest
    /// from every existing account's *resolved* color (manual pick or the
    /// FNV-1a hash fallback alike), so a freshly-added account doesn't land
    /// on a color an existing account already has by chance (real device
    /// report: three accounts in a row all auto-assigned "amber"/gold).
    /// Persisted as an explicit `labelColorKey` rather than left `nil` (which
    /// would just fall back to the same hash) — same reasoning and same
    /// three call sites as `nextAccountSortOrder()` above
    /// (`AccountSetupView`, `ICloudAccountSetupView`, `createGmailAccount`).
    func leastUsedAccountLabelColorKey() -> String {
        let usedColors = accounts.map {
            OtegamiAccountColor.resolvedPaletteColor(for: $0.id, override: $0.labelColorKey)
        }
        return OtegamiAccountColor.leastUsedColorKey(avoiding: usedColors).rawValue
    }

    /// Persists a drag-reorder from the accounts list (設定 のアカウント一覧
    /// — same content backs the hamburger menu/filter chips/Composer's From
    /// picker via `self.accounts`, so this one call is all any of those UIs
    /// needs). `orderedAccountIds` is the *complete* new order (every known
    /// account id, exactly once — what SwiftUI's `.onMove`-driven array
    /// already looks like after the move is applied locally); writes back a
    /// dense `0, 1, 2, ...` sequence matching that order.
    ///
    /// Only actually writes (and pushes to iCloud) the rows whose
    /// `sortOrder` genuinely changed — most `.onMove` calls only move one
    /// row past a handful of others, so most rows keep the position they
    /// already had. Builds `changedAccounts` as the write closure's *return
    /// value* rather than mutating a captured `var` from inside it — Swift 6
    /// strict concurrency rejects mutating a captured variable from within a
    /// `@Sendable` closure like `DatabaseWriter.write`'s, the same
    /// constraint `updateAccount`'s `toWrite` snapshot works around
    /// elsewhere in this file.
    func reorderAccounts(_ orderedAccountIds: [String]) async {
        let now = Date()
        let changedAccounts = (try? await database.dbWriter.write { db -> [AccountRecord] in
            var changed: [AccountRecord] = []
            for (index, accountId) in orderedAccountIds.enumerated() {
                guard var row = try AccountRecord.fetchOne(db, key: accountId) else { continue }
                guard row.sortOrder != index else { continue }
                row.sortOrder = index
                row.updatedAt = now
                try row.update(db, columns: [Column("sortOrder"), Column("updatedAt")])
                changed.append(row)
            }
            return changed
        }) ?? []
        for account in changedAccounts {
            await pushAccountToCloud(account)
        }
    }

    // MARK: - Account editing

    /// Saves an edit to an existing account (`AccountEditView`) — display
    /// name, IMAP/SMTP host/port/security, SMTP username, and (only when
    /// `newPassword` is non-`nil`/non-empty) a new Keychain password. Fixed
    /// per `AccountRecord.kind`/identity fields (`email`, `kind`,
    /// `imapUsername`) are deliberately **not** parameters here — the plan
    /// this implements is explicit that email/kind aren't editable (they're
    /// the account's identity; changing either means "a different
    /// account"), and `imapUsername` specifically is left out of the edit
    /// form too (only ever set at creation, alongside `email`).
    ///
    /// Bumps `updatedAt` (so `AccountCloudSyncEngine`'s last-writer-wins
    /// reconcile actually has something to compare — see
    /// `AccountRecord.updatedAt`'s doc comment on why this was previously
    /// dead weight) and pushes the result to iCloud, mirroring every other
    /// account-mutating call site's `pushAccountToCloud` tail.
    ///
    /// Also invalidates the account's cached `AccountSyncer` (see
    /// `SyncCoordinator.invalidateSyncer(for:)`'s doc comment for why this
    /// is necessary at all: without it, a syncer built before this edit
    /// keeps using the pre-edit host/port/credentials indefinitely) and
    /// stops its `IDLE` loop — `OtegamiApp`'s `.onChange(of:
    /// environment.accounts)` (already fires for any change to this
    /// `AccountRecord`, not just a brand-new one, since `AccountRecord` is
    /// `Equatable` and the array changed) restarts the `IDLE` loop and
    /// kicks an incremental sync with the fresh `AccountRecord`, the exact
    /// same path a newly-added account already goes through — no
    /// duplicate "restart sync" logic needed here.
    func updateAccount(
        _ account: AccountRecord,
        displayName: String,
        imapHost: String,
        imapPort: Int,
        imapSecurity: ConnectionSecurityRecord,
        smtpHost: String?,
        smtpPort: Int?,
        smtpSecurity: ConnectionSecurityRecord?,
        smtpUsername: String?,
        newPassword: String?,
        labelColorKey: String?? = nil,
        defaultSignatureId: Int64?? = nil
    ) async throws {
        var updated = account
        updated.displayName = displayName
        updated.imapHost = imapHost
        updated.imapPort = imapPort
        updated.imapSecurity = imapSecurity
        updated.smtpHost = smtpHost
        updated.smtpPort = smtpPort
        updated.smtpSecurity = smtpSecurity
        updated.smtpUsername = smtpUsername
        // D「アカウントのラベル色を変更可能に」: `labelColorKey` is `String??`
        // (an optional-of-an-optional) specifically so callers that don't
        // pass it at all (every pre-existing call site) leave the column
        // untouched, while `AccountEditView` — which always knows the
        // picker's current selection, including "自動" (nil) — can pass
        // `.some(nil)` to explicitly clear back to auto-assignment. `nil`
        // (the parameter itself absent) means "don't touch this field";
        // `.some(x)` means "set it to x", where x may itself be nil.
        if let labelColorKey {
            updated.labelColorKey = labelColorKey
        }
        // F「デフォルト署名（アカウントごと）」— same "`??` means don't touch,
        // `.some(x)` means set to x (possibly nil)" shape as `labelColorKey`
        // just above; see that parameter's doc comment.
        if let defaultSignatureId {
            updated.defaultSignatureId = defaultSignatureId
        }
        updated.updatedAt = Date()

        if let newPassword, !newPassword.isEmpty {
            try credentialStore.setPassword(newPassword, forAccountId: updated.id)
        }

        // Snapshotted as a `let` before the closure: `DatabaseWriter.write`'s
        // closure is `@Sendable`, and capturing a mutated `var` across that
        // boundary is rejected under Swift 6 strict concurrency (same
        // pattern `AccountSyncer.performInitialSync`'s `syncedRecord` uses).
        let toWrite = updated
        try await database.dbWriter.write { db in
            try toWrite.update(db)
        }

        await syncCoordinator.stopIdleLoop(for: updated)
        await syncCoordinator.invalidateSyncer(for: updated.id)

        await pushAccountToCloud(updated)
    }

    // MARK: - iCloud account sync (M11)

    /// Real-device contamination fix (`docs/icloud-sync.md`'s "開発用ビル
    /// ドでの iCloud KVS 汚染" section): a developer's own Mac is, by
    /// construction, signed into that developer's *real* Apple ID, and
    /// every local build of this app — the iOS Simulator included — shares
    /// the exact same `com.apple.developer.ubiquity-kvstore-identifier`
    /// (Team ID + bundle id, `Otegami-iOS.entitlements`/
    /// `Otegami-macOS.entitlements`) as the Ad-Hoc-signed build this repo
    /// ships to a real device (`make deploy-ota`). There is no separate
    /// sandboxed/fake iCloud a dev/verify run talks to instead — confirmed
    /// on this dev machine by `cloudd`'s own unified log, which shows real
    /// `"TCC approved access for container containerID=iCloud.com.mtkg
    /// .otegami:Sandbox"` entries firing in lockstep with `xcodebuild test`
    /// (verify-script) runs against the iOS *Simulator*. This is what
    /// actually reseeded a real iPhone with `test1@otegami.test`
    /// ("Dovecot Test1"/"test") every time a verify script or a plain
    /// `make ios` run added that dev-mailstack account: `AccountCloudSync
    /// Engine.reconcile()`'s launch-time push reached the real account's
    /// real iCloud KVS key, not a Simulator-local stand-in.
    ///
    /// The Simulator therefore defaults to **not talking to
    /// `AccountCloudSyncEngine` at all** — this gates every push
    /// (`pushLocalChange`/`pushLocalDeletion`) *and* every pull
    /// (`reconcile()`'s cloud→local phase), since pulling a real account
    /// down into a disposable Simulator database is its own, reverse form
    /// of contamination (`CloudAccountDirectory`'s doc comment). A
    /// developer who genuinely wants to exercise real cloud-sync behavior
    /// on the Simulator (e.g. driving `reconcile()` end-to-end against a
    /// real second "device") can opt back in with the
    /// `-otegamiEnableCloudSyncInSimulator` launch argument.
    ///
    /// `OTEGAMI_UITEST_DISABLE_CLOUD_SYNC` is a second, independent
    /// override in the opposite direction: forces sync off even outside
    /// `targetEnvironment(simulator)` (a `make mac` build driven for UI
    /// verification, say) — belt-and-suspenders alongside the Simulator
    /// default above, matching this file's other `OTEGAMI_UITEST_*`
    /// escape hatches (`init()`'s duplicate-merge/credential-relocation
    /// flags).
    ///
    /// This gate is layer 1 of the fix; layer 2
    /// (`CloudAccountSnapshot.isDevelopmentAccount`) is what protects a
    /// Mac-*native* `make mac`/verify run, which — being neither the
    /// Simulator nor a UI test process — this gate alone can't reach, and
    /// is also what self-heals a cloud payload already contaminated
    /// before this fix shipped. Doesn't affect
    /// `AccountCloudSyncEngineTests`/`AccountCloudSyncSnapshotTests` at
    /// all — those drive the engine directly against an in-memory fake
    /// `UbiquitousStoring`, never through this gate or `AppEnvironment`.
    ///
    /// `nonisolated`: pure `ProcessInfo` reads, no `AppEnvironment` state —
    /// matching `validatedRelayURL`'s reasoning, this has to be callable
    /// from the plain `@Sendable () -> Bool` closure `init()` hands
    /// `AccountCloudSyncEngine` as `isEnabled`, which runs on that engine's
    /// own actor, not `@MainActor`.
    nonisolated static func isCloudSyncPermittedOnThisBuild() -> Bool {
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DISABLE_CLOUD_SYNC"] == "1" {
            return false
        }
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-otegamiEnableCloudSyncInSimulator")
        #else
        return true
        #endif
    }

    /// `AccountsSettingsView`'s "iCloud でアカウントを同期" toggle. Flipping it
    /// on runs a full `reconcile()` immediately (plan: "OFF→ON で full
    /// reconcile") rather than waiting for the next launch/external-change
    /// notification; flipping it off just persists the flag — every
    /// in-flight `accountCloudSync` call already no-ops once
    /// `cloudSyncSettings.isEnabled` reads `false` (`AccountCloudSyncEngine`
    /// reads it fresh on every call, not just at construction time), so
    /// there's nothing further to tear down.
    func setCloudSyncEnabled(_ enabled: Bool) async {
        let wasEnabled = cloudSyncSettings.isEnabled
        cloudSyncSettings.isEnabled = enabled
        isCloudSyncEnabled = enabled
        if enabled, !wasEnabled {
            await accountCloudSync.reconcile()
            // Task #89: same toggle, same "just turned back on" trigger —
            // see `settingsCloudSync`'s doc comment for why this piggybacks
            // on the account-sync toggle instead of getting its own.
            await settingsCloudSync.reconcile()
        }
    }

    /// Pushes a locally-added or locally-changed account to iCloud right
    /// away — called after every account-creation flow's local DB insert
    /// (`AccountSetupView`/`ICloudAccountSetupView`/`createGmailAccount`
    /// below) instead of waiting for the next full `reconcile()`.
    func pushAccountToCloud(_ account: AccountRecord) async {
        await accountCloudSync.pushLocalChange(CloudAccountSnapshot(account: account))
    }

    /// A `.password`-kind account `CloudAccountDirectory.insertFromCloud`
    /// created without a credential (iCloud Keychain hadn't synced the
    /// password yet — see `AccountRecord.needsReauth`'s doc comment) gets
    /// Keychain re-checked automatically on every accounts-list tick
    /// (`startObservingAccounts`, cheap once resolved since this whole
    /// method becomes a no-op the moment `needsReauth` flips to `false`).
    /// Real-device bug fix: this used to also be reachable from
    /// `AccountsSettingsView`'s "再接続" button as an explicit-retry sibling
    /// (`retryPendingCredential(for:)`, since removed) — but a button whose
    /// only job is "run this same automatic check one time, right now" is
    /// useless once the credential is actually gone rather than merely not
    /// synced yet, and gives the user no way to tell the two apart. The
    /// button now pushes straight to `AccountEditView`'s password field
    /// instead (`AccountsSettingsView.passwordEntryAccount`'s doc comment)
    /// — a `.password` account's only real recovery path — leaving this
    /// automatic tick-based check as the sole caller. A `.gmail`/`.oauth2`
    /// account's `needsReauth` means something different (a rejected
    /// refresh token — `AppEnvironment.reauthenticateGmailAccount`'s
    /// interactive OAuth flow is the only way to clear that one), so this
    /// only ever touches `.password` accounts.
    private func retryPendingCredentialIfAvailable(_ account: AccountRecord) async {
        guard account.needsReauth, account.authType == .password else { return }
        guard let password = try? credentialStore.password(forAccountId: account.id) else { return }
        await setNeedsReauth(false, for: account)
        let auth = MailAuth.password(username: account.imapUsername, password: password)
        Task {
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        await registerWatchIfNeeded(for: account)
    }

    // MARK: - Auth resolution (M6: "SyncCoordinator のセッション構築経路に auth
    // provider を注入する形に拡張")

    enum AuthResolutionError: Error {
        /// `.password`-kind account with no Keychain entry (deleted
        /// externally, or the account row outlived a failed Keychain
        /// write — see `AccountSetupView.saveAccount`'s doc comment on
        /// that ordering).
        case missingCredential
        /// `.oauth2`-kind account but this build has no
        /// `GOOGLE_OAUTH_CLIENT_ID` configured — shouldn't be reachable in
        /// practice (the Gmail entry point is disabled without one, so no
        /// `.gmail` account could have been created), but handled
        /// explicitly rather than force-unwrapping `tokenStore`.
        case oauthUnavailable
    }

    /// The single place every call site that needs a `MailAuth` for
    /// `account` goes through — replaces the four near-identical
    /// "read Keychain, build `.password`" blocks M1–M5 each had (see
    /// `OtegamiApp.swift`/`ComposerView`/`MessageListView`/`MessageView`
    /// before this change) and adds the M6 branch: for a `.gmail`-kind
    /// account, asks `TokenStore` for a currently-valid access token
    /// (refreshing under the hood if needed) and returns
    /// `MailAuth.xoauth2`. On `TokenStoreError.reauthenticationRequired`,
    /// marks the account "要再認証" (persisted, so `AccountsSettingsView`'s
    /// banner survives a relaunch) before rethrowing.
    func auth(for account: AccountRecord) async throws -> MailAuth {
        switch account.authType {
        case .password:
            guard let password = try credentialStore.password(forAccountId: account.id) else {
                // Bug fix: previously this branch never touched
                // `needsReauth` at all, unlike the `.oauth2` branch below —
                // a `.password` account whose Keychain item genuinely goes
                // missing (not just the M11 "cloud-inserted, iCloud
                // Keychain hasn't caught up yet" case, which already sets
                // this at insert time via `CloudAccountDirectory
                // .insertFromCloud`) had no visible symptom anywhere in the
                // UI: every call site that needs a body/attachment/send
                // just failed with whatever error message *that* call site
                // happened to show, with no account-level banner and no
                // "再接続" affordance pointing at the actual cause. Setting
                // it here means `AccountsListContent`'s existing
                // "資格情報を待っています"/"再接続" UI (built for the M11 case)
                // now also covers this one "for free" — same flag, same
                // banner, same automatic retry-on-tick
                // (`retryPendingCredentialIfAvailable`, which only fires
                // when `needsReauth` is already `true`) — instead of this
                // being a second, undiscoverable failure mode.
                await setNeedsReauth(true, for: account)
                throw AuthResolutionError.missingCredential
            }
            // Mirrors `retryPendingCredentialIfAvailable`'s clearing: any
            // successful resolution — not just the automatic per-tick
            // retry — means the credential is available again, so a stale
            // `needsReauth` (set by a previous failure, here or in
            // `retryPendingCredentialIfAvailable`) should stop being shown.
            if account.needsReauth {
                await setNeedsReauth(false, for: account)
            }
            return .password(username: account.imapUsername, password: password)

        case .oauth2:
            // Task #116 第2段: `.oauth2` alone doesn't say *which* provider's
            // tokens to use — `account.kind` does. Each branch below is a
            // near-identical mirror of the other, just against a different
            // `TokenStore`/error type (`GoogleOAuth.TokenStoreError` vs
            // `MicrosoftOAuth.TokenStoreError` — same case names, different
            // types, since the two OAuth packages are deliberately
            // independent of each other).
            switch account.kind {
            case .gmail:
                guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
                do {
                    let accessToken = try await tokenStore.accessToken(for: account.id)
                    return .xoauth2(username: account.imapUsername, accessToken: accessToken)
                } catch GoogleOAuth.TokenStoreError.reauthenticationRequired {
                    await setNeedsReauth(true, for: account)
                    throw GoogleOAuth.TokenStoreError.reauthenticationRequired
                }
            case .microsoft:
                guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
                do {
                    let accessToken = try await microsoftTokenStore.accessToken(for: account.id)
                    return .xoauth2(username: account.imapUsername, accessToken: accessToken)
                } catch MicrosoftOAuth.TokenStoreError.reauthenticationRequired {
                    await setNeedsReauth(true, for: account)
                    throw MicrosoftOAuth.TokenStoreError.reauthenticationRequired
                }
            case .generic, .icloud:
                // Shouldn't be reachable — only `.gmail`/`.microsoft`-kind
                // accounts are ever created with `authType: .oauth2` (every
                // account-creation call site pairs the two together). Not a
                // `fatalError` regardless, matching this method's existing
                // "handled explicitly rather than force-unwrapping" style
                // for the sibling `AuthResolutionError.oauthUnavailable`
                // case just above.
                throw AuthResolutionError.oauthUnavailable
            }
        }
    }

    /// Best-effort — a failed write here just means the banner doesn't
    /// show/clear until the next successful DB write for this row; never
    /// worth failing whatever `auth(for:)`/`reauthenticateGmailAccount(_:)`
    /// call this from over.
    private func setNeedsReauth(_ value: Bool, for account: AccountRecord) async {
        try? await database.dbWriter.write { db in
            guard var row = try AccountRecord.fetchOne(db, key: account.id) else { return }
            guard row.needsReauth != value else { return }
            row.needsReauth = value
            try row.update(db)
        }
    }

    // MARK: - Gmail sign-in (M6)

    /// Runs the interactive Authorization Code + PKCE flow, then looks up
    /// the signed-in account's email (see `GoogleOAuthEndpoints
    /// .userInfoEndpoint`'s doc comment for why that second round trip is
    /// needed). Used by `GmailAccountSetupView` for a brand-new account
    /// (always `promptConsent: true`, the default — see
    /// `GoogleOAuthEndpoints.authorizationURL(pkce:state:promptConsent:)`'s
    /// doc comment for why a first-time grant needs the consent screen
    /// forced) and — with the returned tokens simply re-stored under an
    /// *existing* account id — by `reauthenticateGmailAccount(_:)` below,
    /// which decides `promptConsent` for itself.
    /// Throws `AuthResolutionError.oauthUnavailable` if this build has no
    /// Client ID (shouldn't be reachable: the Gmail button is disabled in
    /// that case).
    func requestGmailAuthorization(promptConsent: Bool = true) async throws -> (email: String, tokens: GoogleOAuthTokens) {
        guard let googleOAuthClient else { throw AuthResolutionError.oauthUnavailable }
        let tokens = try await googleOAuthClient.requestAuthorization(promptConsent: promptConsent)
        let email = try await googleOAuthClient.fetchUserEmail(accessToken: tokens.accessToken)
        return (email, tokens)
    }

    /// Creates and persists a new Gmail account: `imap.gmail.com`/
    /// `smtp.gmail.com` presets (plan: "imap.gmail.com:993 / smtp.gmail.com:465or587"
    /// — 587/STARTTLS chosen as the more broadly-compatible of the two, see
    /// `GmailAccountSetupView`), `kind: .gmail`, `authType: .oauth2`. Stores
    /// `tokens` in `TokenStore` keyed by the new account's id (assigned
    /// here, before either write, since both the DB row and the token
    /// storage need to agree on it) and kicks off the first sync the same
    /// way `AccountSetupView.saveAccount`/`iCloudAccountSetupView` do.
    func createGmailAccount(email: String, displayName: String, tokens: GoogleOAuthTokens) async throws {
        guard let tokenStore else { throw AuthResolutionError.oauthUnavailable }
        let account = AccountRecord(
            displayName: displayName.isEmpty ? email : displayName,
            email: email,
            authType: .oauth2,
            kind: .gmail,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: email,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            smtpUsername: email,
            // Task #72「自動割当の改善」: see this call's identical doc
            // comment on `AccountSetupView.saveAccount`/
            // `ICloudAccountSetupView.saveAccount`.
            labelColorKey: leastUsedAccountLabelColorKey(),
            sortOrder: nextAccountSortOrder()
        )
        // TokenStore first, same ordering rationale as
        // `AccountSetupView.saveAccount`'s Keychain-before-DB-row: an
        // account row with nowhere to get an access token from is useless,
        // while an orphaned TokenStore entry for an id nothing references
        // is harmless dead weight.
        try await tokenStore.storeInitialTokens(tokens, accountId: account.id)
        try await database.dbWriter.write { db in
            try account.insert(db)
        }

        Task {
            guard let auth = try? await self.auth(for: account) else { return }
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        // M11: see AccountSetupView.saveAccount's identical call.
        Task { await pushAccountToCloud(account) }
    }

    /// Re-runs the OAuth flow for an already-existing `.gmail` account
    /// (`AccountsSettingsView`'s "再認証" button) and clears its
    /// `needsReauth` flag on success. Deliberately does *not* verify the
    /// re-authenticated account is the same Google account as before —
    /// Google's consent screen (when it's shown at all — see below) always
    /// shows the account picker, so the user could pick a different one;
    /// that's treated as "the user's explicit choice", not an error to
    /// guard against here (a mismatch would just start delivering a
    /// different inbox's mail, which is immediately obvious rather than a
    /// silent data-integrity problem).
    ///
    /// Task #47 (「毎回gmailアカウント追加時に警告のようなものが出るのが
    /// つらい」): before requesting authorization, checks whether the
    /// account's last-known granted scope (`TokenStore.diagnosticScope(for:)`,
    /// the same forced-refresh lookup `AccountEditView`'s「権限の診断」uses)
    /// already covers everything this build's `scope` asks for
    /// (`GoogleOAuthEndpoints.isSatisfied(byGrantedScope:)`). If so, the
    /// authorization request omits `prompt=consent` entirely — Google
    /// silently reissues a code for the existing grant with no screen and
    /// no "アプリは確認されていません" warning, so a routine token refresh
    /// (the common case: nothing about `scope` changed since the account
    /// was last connected) is a single tap with no consent screen at all.
    /// Only when the stored scope is missing, stale, or genuinely
    /// insufficient (a new scope was added to `scope` since this account
    /// last connected, or the diagnostic lookup itself failed) does this
    /// fall back to forcing the consent screen, the same as before this
    /// fix — see `GoogleOAuthEndpoints.authorizationURL(pkce:state:promptConsent:)`'s
    /// doc comment for the full reasoning.
    func reauthenticateGmailAccount(_ account: AccountRecord) async throws {
        guard let tokenStore, let endpoints = GoogleOAuthConfig.endpoints else {
            throw AuthResolutionError.oauthUnavailable
        }
        let grantedScope = try? await tokenStore.diagnosticScope(for: account.id)
        let promptConsent = !endpoints.isSatisfied(byGrantedScope: grantedScope)
        let (_, tokens) = try await requestGmailAuthorization(promptConsent: promptConsent)
        try await tokenStore.storeInitialTokens(tokens, accountId: account.id)
        await setNeedsReauth(false, for: account)
        // 実機バグ修正: `GoogleProfilePhotoAvatarResolver.scopeInsufficientAccountIds`
        // のドキュメントコメント参照 — 再認証成功でこのアカウントの
        // 「スコープ不足」記憶を即座に消す。これをしないと、次にスコープ
        // 不足で401/403を踏んでいた同一プロセス内では、再認証で新しい
        // スコープを得た直後でも次回起動までGoogleプロフィール写真の
        // 取得が永久にスキップされ続ける。
        await googleProfilePhotoAvatarResolver.clearScopeInsufficientMemory(for: account.id)
    }

    /// `AccountEditView`の「権限の診断」表示専用 — `account`の現在の
    /// 付与済みスコープを Google に強制的に問い合わせて返す
    /// (`TokenStore.diagnosticScope(for:)`のドキュメントコメント参照:
    /// キャッシュされた既存トークンにはスコープ情報が付随しないため、
    /// 診断のたびに実際にリフレッシュリクエストを送る必要がある)。
    /// `.oauth2`以外のアカウントやこのビルドに`tokenStore`が無い場合は
    /// `nil`。問い合わせ自体が失敗した場合 (ネットワークエラー・
    /// リフレッシュトークン喪失等) も`nil` — このビューは「わからない」
    /// と「未許可」を区別して見せる必要があるほど厳密な用途ではなく、
    /// 失敗時は`reauthErrorMessage`側の通常のエラー表示に任せる。
    func googleGrantedScope(for account: AccountRecord) async -> String? {
        guard account.authType == .oauth2, account.kind == .gmail, let tokenStore else { return nil }
        return try? await tokenStore.diagnosticScope(for: account.id)
    }

    /// Task #42「アバター診断」— `AccountEditView`の「アバター診断」画面が
    /// タップ時に呼ぶ。`googleProfilePhotoAvatarResolver
    /// .forceRebuildDiagnostics(accountId:)`への薄い橋渡しで、実質的な
    /// 内容はそちらのドキュメントコメント参照。`.oauth2`以外のアカウント
    /// (呼び出し元がそもそもこの画面を出さない) には`nil`。
    func googleAvatarDiagnostics(for account: AccountRecord) async -> GoogleAvatarAccountDiagnostics? {
        guard account.authType == .oauth2 else { return nil }
        return await googleProfilePhotoAvatarResolver.forceRebuildDiagnostics(accountId: account.id)
    }

    // MARK: - Microsoft sign-in (Task #116 第2段)

    /// Mirrors `requestGmailAuthorization(promptConsent:)` — runs the
    /// interactive Authorization Code + PKCE flow, then reads the signed-in
    /// account's email straight out of the token response's id_token
    /// (`MicrosoftOAuthClient.fetchUserEmail(idToken:)`'s doc comment on
    /// why that needs no extra network round trip the way Google's does).
    /// Unlike Google, there's no `promptConsent` parameter to thread
    /// through — Microsoft's flow always requests `prompt=select_account`
    /// (`MicrosoftOAuthEndpoints.authorizationURL(pkce:state:)`'s doc
    /// comment), and `offline_access` alone (no forced-reconsent flag
    /// needed) already guarantees a `refresh_token` on every grant.
    func requestMicrosoftAuthorization() async throws -> (email: String, tokens: MicrosoftOAuthTokens) {
        guard let microsoftOAuthClient else { throw AuthResolutionError.oauthUnavailable }
        let tokens = try await microsoftOAuthClient.requestAuthorization()
        let email = try microsoftOAuthClient.fetchUserEmail(idToken: tokens.idToken)
        return (email, tokens)
    }

    /// Mirrors `createGmailAccount(email:displayName:tokens:)` — Outlook.com/
    /// Office 365 preset (`outlook.office365.com:993` TLS /
    /// `smtp.office365.com:587` STARTTLS, plan-specified), `kind: .microsoft`,
    /// `authType: .oauth2`. Both "Outlook" and "Office365" buttons on
    /// `AccountTypeSelectionView` call this same method — see
    /// `MicrosoftOAuthEndpoints.authorizationEndpoint`'s doc comment for why
    /// there's no server-side difference between the two entry points.
    func createMicrosoftAccount(email: String, displayName: String, tokens: MicrosoftOAuthTokens) async throws {
        guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
        let account = AccountRecord(
            displayName: displayName.isEmpty ? email : displayName,
            email: email,
            authType: .oauth2,
            kind: .microsoft,
            imapHost: "outlook.office365.com",
            imapPort: 993,
            imapSecurity: .tls,
            imapUsername: email,
            smtpHost: "smtp.office365.com",
            smtpPort: 587,
            smtpSecurity: .startTLS,
            smtpUsername: email,
            labelColorKey: leastUsedAccountLabelColorKey(),
            sortOrder: nextAccountSortOrder()
        )
        try await microsoftTokenStore.storeInitialTokens(tokens, accountId: account.id)
        try await database.dbWriter.write { db in
            try account.insert(db)
        }

        Task {
            guard let auth = try? await self.auth(for: account) else { return }
            _ = try? await self.syncCoordinator.syncAccount(account, auth: auth)
        }
        Task { await pushAccountToCloud(account) }
    }

    /// Mirrors `reauthenticateGmailAccount(_:)` — re-runs the OAuth flow for
    /// an already-existing `.microsoft` account and clears `needsReauth` on
    /// success. No `isSatisfied(byGrantedScope:)`-driven "skip the consent
    /// screen" fast path the way Gmail's reauth has (Task #47) — Microsoft's
    /// `prompt=select_account` always shows the account picker regardless,
    /// so there's no silent-refresh case to special-case here.
    func reauthenticateMicrosoftAccount(_ account: AccountRecord) async throws {
        guard let microsoftTokenStore else { throw AuthResolutionError.oauthUnavailable }
        let (_, tokens) = try await requestMicrosoftAuthorization()
        try await microsoftTokenStore.storeInitialTokens(tokens, accountId: account.id)
        await setNeedsReauth(false, for: account)
    }

    // MARK: - Push notifications (M9)

    enum PushError: Error, Equatable {
        /// Relay URL failed `PushNotificationSettingsView`'s "https
        /// required (http://localhost exempted for local dev)" check.
        case invalidRelayURL
        /// `PushTokenCenter` never got a device token — always the case on
        /// the iOS Simulator (`PushTokenCenter`'s doc comment). No longer
        /// used for a denied notification-authorization prompt on a real
        /// device — that's `.notificationPermissionDenied` now, so the UI
        /// can tell the two apart and point at Settings only for the
        /// latter.
        case noDeviceToken
        /// The user declined (or had previously declined) the
        /// `UNUserNotificationCenter` alert/badge/sound authorization
        /// prompt — `PushTokenCenter.requestToken()` throws
        /// `.notificationPermissionDenied` *before* attempting APNs
        /// device-token registration at all (M9 bug fix: the app
        /// previously never requested this permission, so push
        /// notifications silently never displayed — see
        /// `docs/verify.md`'s "M9 追補" section). `PushNotificationSettingsView`
        /// surfaces this with a link to the Settings app
        /// (`UIApplication.openSettingsURLString`), since iOS never
        /// re-shows the system prompt once denied.
        case notificationPermissionDenied
        /// This build has no `UIApplication` to register with at all
        /// (macOS) — push isn't implemented there yet (M9 scope: iOS-only
        /// `NotificationService`, plan/PENDING.md).
        case unsupportedPlatform
    }

    /// Validates `relayURLString`, requests notification authorization +
    /// an APNs device token, registers this device with the relay, and
    /// creates a watch for every currently-configured `.password`-auth
    /// account (Gmail/`.oauth2` accounts are skipped — the relay only
    /// supports password auth in v1, `OtegamiRelayAPI.WatchAuth.Kind`'s
    /// doc comment). Persists everything via `pushSettings` as it goes, so
    /// a failure partway through (e.g. the device registers fine but one
    /// account's watch creation fails) still leaves whatever succeeded in
    /// place rather than needing to be redone from scratch.
    func enablePushNotifications(relayURLString: String) async throws {
        guard let baseURL = Self.validatedRelayURL(relayURLString) else {
            throw PushError.invalidRelayURL
        }

        let apnsToken = try await requestAPNsToken()
        let apnsEnvironment = APNSEnvironmentDetector.detectedEnvironment()

        let deviceId: String
        let deviceSecret: String
        if let existingId = pushSettings.deviceId, let existingSecret = try pushSettings.deviceSecret() {
            // Already registered (re-enabling after a previous disable, or
            // recovering from a partial failure) — just refresh the token
            // rather than minting a brand new device registration.
            try await pushRelayClient.updateDeviceToken(
                baseURL: baseURL,
                deviceId: existingId,
                deviceSecret: existingSecret,
                apnsToken: apnsToken,
                environment: apnsEnvironment
            )
            deviceId = existingId
            deviceSecret = existingSecret
        } else {
            let response = try await pushRelayClient.registerDevice(baseURL: baseURL, apnsToken: apnsToken, environment: apnsEnvironment)
            deviceId = response.deviceId
            deviceSecret = response.deviceSecret
            try pushSettings.setDeviceSecret(deviceSecret)
        }

        pushSettings.relayURLString = relayURLString
        pushSettings.deviceId = deviceId
        pushRelayURLString = relayURLString

        for account in accounts where account.authType == .password {
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }

        pushSettings.isEnabled = true
        isPushEnabled = true
    }

    /// Deletes every watch this device has registered (best-effort — a
    /// relay that's unreachable at the moment shouldn't leave the user
    /// stuck unable to turn push back off locally) and clears all local
    /// push state.
    func disablePushNotifications() async {
        if let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
           let deviceSecret = try? pushSettings.deviceSecret() {
            for (_, watchId) in pushSettings.accountWatchMap {
                try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
            }
        }
        pushSettings.reset()
        isPushEnabled = false
        pushRelayURLString = ""
    }

    /// Registers a watch for `account` if push is enabled and it doesn't
    /// already have one — called both from `enablePushNotifications` (for
    /// every existing account) and should be called again whenever a new
    /// `.password` account is added while push is already enabled.
    func registerWatchIfNeeded(for account: AccountRecord) async {
        guard isPushEnabled, account.authType == .password else { return }
        guard pushSettings.accountWatchMap[account.id] == nil else { return }
        guard let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
    }

    private func registerWatch(for account: AccountRecord, baseURL: URL, deviceSecret: String) async {
        guard let password = try? credentialStore.password(forAccountId: account.id) else { return }
        let request = CreateWatchRequest(
            accountId: account.id,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapUseTLS: account.imapSecurity != .plain,
            imapUsername: account.imapUsername,
            auth: WatchAuth(secret: password),
            mailbox: "INBOX"
        )
        guard let response = try? await pushRelayClient.createWatch(baseURL: baseURL, deviceSecret: deviceSecret, request: request) else {
            return
        }
        pushSettings.setWatchId(response.watchId, forAccountId: account.id)
    }

    private func unregisterWatch(forAccountId accountId: String) async {
        guard let watchId = pushSettings.accountWatchMap[accountId] else { return }
        defer { pushSettings.setWatchId(nil, forAccountId: accountId) }
        guard let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
    }

    /// Throttle for `reconcilePushWatchesIfNeeded()` — see that method's
    /// doc comment for why a full reconcile pass doesn't need to run on
    /// every single foreground.
    private static let watchReconcileInterval: TimeInterval = 60 * 60 * 24

    /// M9 follow-up (実機バグ1: 削除済みアカウントの watch がリレーに残り
    /// 通知が届き続ける): `unregisterWatch`'s `DELETE` is (and stays)
    /// best-effort `try?` with no retry of its own — a relay that's
    /// unreachable for that one call previously meant the watch (and the
    /// IMAP credential it holds) lived on the relay forever, with nothing
    /// to ever notice or retry. This is the self-healing counterpart:
    /// called from every launch/foreground (`RootView
    /// .handleScenePhaseChange`'s `.active` case), it fetches this
    /// device's actual watch list from the relay (`GET /v1/watches`,
    /// ground truth) and reconciles it against local accounts via
    /// `WatchReconciler.plan` —
    ///   - a relay watch for an account no longer known locally gets
    ///     `DELETE`d (fixes the actual bug: a deleted account's watch
    ///     that a prior best-effort delete failed to clean up).
    ///   - a local `.password` account with no live relay watch gets a
    ///     fresh one registered (the initial `createWatch` failed, or the
    ///     local map fell out of sync some other way).
    ///   - the local accountId→watchId map is repaired to match the
    ///     relay wherever it disagrees — no network call needed for that
    ///     part, just local bookkeeping.
    /// Throttled to roughly once a day (`PushSettingsStore
    /// .lastWatchReconcileDate`) rather than running on every single
    /// foreground — once healed, this shouldn't need to run often, and a
    /// `GET` plus up to one request per drifted account on every
    /// foreground would be wasteful. A relay that's unreachable right now
    /// just means this quietly no-ops and tries again next time the
    /// throttle allows it — same "best-effort, no user-visible failure"
    /// posture as the rest of this file's push plumbing.
    func reconcilePushWatchesIfNeeded() async {
        guard isPushEnabled else { return }
        if let last = pushSettings.lastWatchReconcileDate, Date().timeIntervalSince(last) < Self.watchReconcileInterval {
            return
        }
        guard let baseURL = Self.validatedRelayURL(pushSettings.relayURLString ?? ""),
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        guard let serverWatches = try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret) else {
            return
        }
        // Recorded even if `serverWatches` turns out empty/no drift —
        // a successful `GET` is what the throttle is protecting against
        // repeating, regardless of what it found.
        pushSettings.lastWatchReconcileDate = Date()

        let localPasswordAccountIds = Set(accounts.filter { $0.authType == .password }.map(\.id))
        let plan = WatchReconciler.plan(
            localPasswordAccountIds: localPasswordAccountIds,
            localWatchMap: pushSettings.accountWatchMap,
            serverWatches: serverWatches
        )

        for watchId in plan.watchIdsToDelete {
            try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
        }
        for (accountId, watchId) in plan.watchIdsToAdoptLocally {
            pushSettings.setWatchId(watchId, forAccountId: accountId)
        }
        for accountId in plan.accountIdsToForgetLocally {
            pushSettings.setWatchId(nil, forAccountId: accountId)
        }
        for accountId in plan.accountIdsToRegister {
            guard let account = accounts.first(where: { $0.id == accountId }) else { continue }
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }
    }

    /// Task #31 (docs/roadmap.md): thin wiring for `SyncCoordinator
    /// .prefetchUnifiedInboxBodiesIfNeeded(accounts:now:authProvider:)` —
    /// all the actual logic (candidate selection, debounce, per-account
    /// sequencing, silent best-effort failure handling) lives there and is
    /// unit-tested there with `FakeIMAPSession`; this method exists only
    /// because `SyncEngine` has no dependency on `KeychainCredentialStore`/
    /// `GoogleOAuth`, so resolving each account's `MailAuth` has to be
    /// injected from here, the same way `auth(for:)` already is for
    /// `syncAllAccountsOnce()`/`startIdleLoops(for:)` in `OtegamiApp.swift`.
    /// Called from `RootView.handleScenePhaseChange`'s `.active` case as a
    /// low-priority, fire-and-forget `Task` — never awaited inline with
    /// user-visible sync/refresh, so a slow or offline prefetch pass can
    /// never delay them.
    func prefetchRecentBodiesIfNeeded() async {
        _ = await syncCoordinator.prefetchUnifiedInboxBodiesIfNeeded(accounts: accounts) { [weak self] account in
            guard let self else { throw AuthResolutionError.missingCredential }
            return try await self.auth(for: account)
        }
    }

    /// Task #80 (「一覧が更新されたときにバックグラウンドで先読み」): same thin-
    /// wiring role as `prefetchRecentBodiesIfNeeded()` above, but for
    /// `SyncCoordinator.prefetchMessageBodies(messageIds:accounts:
    /// authProvider:)` — `MessageListView`/`SearchScreenView` call this with
    /// the leading `SyncCoordinator.listUpdatePrefetchLimit` not-yet-fetched
    /// message ids of whatever list/search-result content just came on
    /// screen (each view debounces its own trigger first; see those views'
    /// doc comments). All the actual logic lives in `SyncCoordinator` and is
    /// unit-tested there; this exists only to supply `auth(for:)`, same
    /// rationale as `prefetchRecentBodiesIfNeeded()`.
    @discardableResult
    func prefetchMessageBodiesIfNeeded(messageIds: [Int64]) async -> Int {
        await syncCoordinator.prefetchMessageBodies(messageIds: messageIds, accounts: accounts) { [weak self] account in
            guard let self else { throw AuthResolutionError.missingCredential }
            return try await self.auth(for: account)
        }
    }

    private func requestAPNsToken() async throws -> String {
        #if os(iOS)
        do {
            return try await PushTokenCenter.shared.requestToken()
        } catch PushTokenCenter.PushTokenError.notificationPermissionDenied {
            throw PushError.notificationPermissionDenied
        } catch {
            throw PushError.noDeviceToken
        }
        #else
        throw PushError.unsupportedPlatform
        #endif
    }

    /// `https://` required; `http://localhost`/`http://127.0.0.1` (any
    /// port) exempted for local dev against a relay run with `swift run`
    /// on the same machine (plan: "リレー URL 入力 (https 必須、ローカル開発時
    /// のみ http://localhost 許可)"). Returns `nil` for anything else,
    /// including a URL that fails to parse at all.
    /// `nonisolated`: pure string parsing, no `AppEnvironment` state —
    /// called both from `@MainActor` call sites in this file and from
    /// `CloudAccountDirectory` (M11), which isn't `@MainActor`.
    nonisolated static func validatedRelayURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), let url = components.url else { return nil }
        if components.scheme == "https" { return url }
        if components.scheme == "http", let host = components.host, host == "localhost" || host == "127.0.0.1" {
            return url
        }
        return nil
    }

    /// Task #45 — see the `OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE` block
    /// above. A 1x1-ish placeholder PNG (the same tiny fixture image
    /// `dev/mailstack/seed/fixtures/16-cid-inline-image.eml` and friends
    /// use, base64-reencoded as a `data:` URI) stands in for the logo/
    /// avatar images the real `.eml` fixture loads via `cid:`.
    private static let uitestFakeHTMLMessagePlaceholderImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAH0lEQVR42mN4USVHFcQwatCoQaMGjRo0atCoQQNvEAD6qmAurCoQRgAAAABJRU5ErkJggg=="

    /// Task #111 (実機報告: 「ソースを表示」をタップすると画面が空白 — 数十
    /// KB級の実メールで再現、シェアシートからの`.eml`書き出しは正常。原因は
    /// `MessageSourceView`の表示側 (`SwiftUI`の`Text`を`ScrollView`に
    /// ネストして巨大な文字列を渡すとCore Graphicsのテクスチャサイズ上限
    /// 相当に達し無言で空白になる、既知の挙動) だった): この定数はその
    /// 再現・検証用の合成データ — ユーザー提供の実メール (実名の宛先
    /// アドレス・購読解除トークンを含む、約54KB) は`docs/`規約により
    /// リポジトリへコミットできないため、同程度のサイズ級を作れる意味の
    /// ない引用チェーン (長く育った返信スレッドで実際によく見る形 —
    /// 何段にも重なった`>`引用行) で代替する。`uitestFakeHTMLMessages[0]`
    /// (html-0シナリオ) の生ソースにだけ足される
    /// (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`挿入ブロック参照) —
    /// `message-source`シナリオ (`scripts/verify-screen.sh`) が常にこの
    /// index 0を開くため。
    private static let uitestFakeLargeRawSourceQuotedHistory: String = {
        let line = "> このダミー引用行はメールソース表示のパフォーマンス検証 (Task #111) 用に生成した合成テキストです。実データは一切含みません。"
        return Array(repeating: line, count: 500).joined(separator: "\r\n")
    }()

    /// Task #123 (Spark 参考「引用履歴をメッセージ単位に分解して時系列
    /// 表示」): `OTEGAMI_UITEST_INSERT_FAKE_QUOTED_PLAIN_MESSAGE`'s body — a
    /// three-level-deep, top-posted Japanese Gmail-style reply chain (same
    /// shape/fictional names `QuoteStripperTests`/`QuoteHistoryParserTests`
    /// already use: 山田太郎 <yamada@example.com> / 田中花子
    /// <tanaka@example.com>). Each level's attribution line ("YYYY年M月D日
    /// (曜) H:MM 名前 <addr>:") lands one `>` shallower than that level's
    /// own body, mirroring exactly how a real top-posting client's quoting
    /// nests (see `QuoteHistoryParser`'s doc comment for why nesting depth
    /// alone recovers chronological order) — `scripts/verify-screen.sh
    /// quote-history` opens this fixture to screenshot
    /// `QuoteHistorySectionView`'s card with real (if fictional) multi-
    /// message content instead of a placeholder.
    private static let uitestFakeQuotedPlainMessageBody = """
        田中さん

        資料のご確認ありがとうございます。来週の定例はオンラインで問題ありません。ご都合の良い候補日を2〜3つ、水曜までに教えていただけますと助かります。

        > 2026年7月28日(火) 10:15 田中花子 <tanaka@example.com>:
        > > 山田さん
        > >
        > > 明日の打ち合わせですが、資料を先にお送りしておきますね。会議室ではなくオンラインに変更しても大丈夫でしょうか。
        > >
        > > > 2026年7月25日(土) 09:03 山田太郎 <yamada@example.com>:
        > > > > 田中さん
        > > > >
        > > > > 承知しました、来週の打ち合わせの件、日程調整ありがとうございます。会議室の予約は私の方で進めておきます。
        > > > >
        > > > > > 2026年7月20日(月) 16:47 田中花子 <tanaka@example.com>:
        > > > > > > 山田さん
        > > > > > >
        > > > > > > お世話になっております。次回の定例ミーティングの日程について、来週のどこかでお時間いただけますでしょうか。
        """

    /// 実機フィードバック (MakerWorld実メールとの比較報告): 完全に透明な
    /// 背景の上に不透明な黒だけを描いた120x40のPNG (ロゴの線画部分を模した
    /// 単純な矩形3つ) — 上の `uitestFakeHTMLMessagePlaceholderImage` (ほぼ
    /// 1x1、装飾目的のダミー) と違い、この画像自体の見た目 (透過部分がある
    /// こと、黒い部分の実サイズが小さいこと) がテスト対象そのもの:
    /// 「反転フィルタを打ち消すために img がもう一度反転される→透過PNGの
    /// 黒いロゴがそのまま黒で残る→反転後の暗い背景に沈んで読めなくなる」
    /// という実機報告と、その対策 (`decideLogoChips`によるロゴサイズの
    /// 画像への白系チップ背景) を実際に目視確認できるようにするための
    /// 実物。`dev/mailstack/seed/fixtures/34-white-canvas-transparent-logo.eml`
    /// と同じPNGバイト列 (手で同期を保つ理由は
    /// `uitestFakeHTMLMessageBodySecurityNotice`のdoc comment参照)。
    private static let uitestFakeHTMLMessagePlaceholderTransparentLogo = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAHgAAAAoCAYAAAA16j4lAAAAeUlEQVR4nO3aMQ6AIBAAQTT+/8vaWdkacJ0pabhkQ0FgDAAAAPiP7WHtnLTvKvun7LMH4F0CxwkcJ3CcwHHH7AEWdI7vu28JTnCcwHECxwkcJ3CcwHECxwkcJ3CcwHECxwkc57Eh/p3HCY4TOE7gOIHjBAYAAGD8yAV2jAM3LCTYZQAAAABJRU5ErkJggg=="

    /// Task #51/#56: one entry per dark-mode/HTML-rendering regression
    /// scenario (`docs/design-system.md`'s Task #51/#56 節), inserted as
    /// separate seeded messages so `OtegamiSecurityNoticeDarkModeUITests`
    /// can open and screenshot all of them in one run instead of needing
    /// one separate env-var-gated code path per case:
    /// - `securityNotice` (case b): explicit white background + dark text,
    ///   no self-declared dark support — the *original* Task #45 fixture;
    ///   still needs the invert to stay readable in dark mode.
    /// - `noColors` (case a): zero color declarations anywhere — the
    ///   Task #51 regression case itself (see `HTMLDocumentBuilder.wrap
    ///   (bodyHTML:autoAdjustColorsInDarkMode:)`'s doc comment); must NOT
    ///   be inverted, since it already renders correctly via this app's
    ///   own `color-scheme`/`CanvasText` CSS reset alone.
    /// - `selfDarkAware` (case c): declares its own `prefers-color-scheme`
    ///   handling, so `HTMLDocumentBuilder.wrap` should skip inversion
    ///   consideration entirely regardless of what the JS measurement would
    ///   have found — proves the "mail already handles its own dark mode"
    ///   gate still wins over the newer measured-inversion logic.
    /// - `betaTestingNotice` (Task #56): no background at all *and* an
    ///   explicit dark text color (`#444444`) — the case neither `b` nor
    ///   `a` above covers (background genuinely unresolved, but unlike `a`
    ///   the text isn't relying on `CanvasText`). Also exercises the
    ///   "responsive but capped" image technique (`width` attribute +
    ///   `style="width:100%; max-width:120px;"`) that the image-enlargement
    ///   fix targets.
    /// - `makerWorldLikeNotice` (実機フィードバック、MakerWorld実メールとの
    ///   比較報告): `body`自身が`background-color`を明示指定するテンプレート
    ///   (findEffectiveBackgroundの最優先候補) と、透過PNGの小さいロゴ画像
    ///   の組み合わせ — ダーク反転時の「右端の白帯・セクション間の色ムラ・
    ///   透過ロゴが暗背景に沈む」の3点を確認する。
    /// - `calendarInviteRealisticNotice` (Task #98、実機報告: Google カレン
    ///   ダー招待メールがダークモードでほぼ読めない): `uitestFakeCalendarInviteHTML`
    ///   (Task #84、`calendar-invite`シナリオ) 自体は既に「背景なし+過半数
    ///   ラベルが`#5f6368`系」のケースを再現しているが、そちらは本文冒頭
    ///   から即座にラベル (`#5f6368`) が始まるため、
    ///   `representativeTextLuminance`の「最初の6テキストノードの平均」
    ///   だけでも実は既に閾値未満に落ちて正しく判定できてしまっていた
    ///   (Task #84 時点で確認済み)。実機報告の実際のメールはタイトル見出し
    ///   や「〜さんが招待しました」といった色未指定の前置きテキストが本文
    ///   冒頭に複数行あり、そちらが平均を0.5超まで押し上げて「介入不要」に
    ///   誤って倒れる — その取りこぼしそのものを再現するのがこのケース
    ///   (色未指定のテキストを冒頭に3つ挟み、6サンプル平均を0.5超で固定
    ///   しつつ、全体としては明示的な暗〜中間色テキストが文字数で過半を
    ///   占める構造)。`explicitDarkTextIsMajority`(Task #98) が無いとこの
    ///   ケースは白カード化されず、暗地に暗〜中間色文字のまま残る。
    /// - `styleBlockGrayTextNotice` (Task #104、実機報告: Readdle Documents
    ///   のニュースレター等が Task #98 対策後もダークネイティブのまま
    ///   読めない): 上の`calendarInviteRealisticNotice`と違い、文字色を
    ///   **インライン`style`ではなく`<head>`の`<style>`ブロックの CSS
    ///   クラス**で指定するニュースレターテンプレートを再現する
    ///   (`.headline`/`.body-text`/`.footer-text`が`color`を持つクラス、
    ///   本文側は`class="body-text"`のようにクラス名を書くだけでインライン
    ///   `style`を一切持たない)。背景は本文中どこにも指定せず (青い
    ///   ヒーロー画像は`<img>`のみで背景色を持つ要素ではない — CTAボタンの
    ///   背景色だけが唯一の候補になるが `inner`の30%未満なのでTask #84の
    ///   足切りに掛かりnullのまま)、文書冒頭に色未指定の前置き文を2行
    ///   置いて`representativeTextLuminance`の6サンプル平均を0.5超で固定
    ///   しつつ、クラス経由の暗〜中間グレー本文が文字数で過半を占める —
    ///   `explicitDarkTextIsMajority`がインライン`style`しか見ていなければ
    ///   (Task #98時点の実装) この過半を検出できず「介入不要」に誤って
    ///   倒れる、その取りこぼしを再現するケース。
    /// - `whiteCardHeroNotice` (Task #112、ユーザー提供の実メール
    ///   `readdle.eml`で再現・修正 — 上の6件と違う点が肝心): 上のケースは
    ///   すべて`findEffectiveBackground`が`null`を返す「背景なし」の構造
    ///   だったため、`explicitDarkTextIsMajority`(Task #98/#104)は
    ///   `decideDarkInversion`の`else`枝 (背景なしフォールバック) からしか
    ///   呼ばれないという実装のまま気づかれずにいた。実際の readdle.eml は
    ///   `body`が明示的に白背景を持つ「背景あり」の構造 (ニュースレターとして
    ///   ごく普通) で、この場合`decideDarkInversion`は`if (background)`枝の
    ///   `representativeTextLuminance`(先頭6テキストノードの平均) だけしか
    ///   見ておらず、`explicitDarkTextIsMajority`には一度も到達していな
    ///   かった — Task #104 の対策が実際には多くの実メールで効いていな
    ///   かった根本原因。このフィクスチャは`body`に明示的な白背景を持たせ
    ///   た上で、文書冒頭にヒーロー領域 (背景画像+白文字の短い見出し2行、
    ///   Gmail限定の`u+.body`セレクタ — このWKWebViewでは絶対にマッチしない
    ///   ため無害 — による`mix-blend-mode`ハックも実物同様に含む) を置き、
    ///   その後に本文カード (クラス経由の`#111111`/`rgb(51, 51, 51)`系の
    ///   暗〜中間グレー文字を複数段落) を続ける — 先頭6サンプルがヒーロー
    ///   側の明るい文字に偏って「介入不要」に落ち着いた後、本文の暗色
    ///   段落が文字数で過半を占める構造を`explicitDarkTextIsMajority`側の
    ///   フォールバックが拾えることを確認する。冒頭の隠しプリヘッダ
    ///   (`display:none`/`visibility:hidden`/`font-size:0`と、実物同様の
    ///   大量の不可視結合文字) も含めてあり、これが`explicitDarkText
    ///   IsMajority`の分母を水増ししない (`isVisuallyHiddenText`) ことも
    ///   同時に確認できる。色指定は実物の`#333333`/`rgb(51, 51, 51)`混在を
    ///   模して両記法を使う。
    fileprivate struct UITestFakeHTMLMessage {
        let subject: String
        let snippet: String
        let html: String
        /// Task #128: `nil` (the default — every pre-existing fixture) seeds
        /// the row with no `detectedLanguage` at all, same as a message this
        /// app has never opened before. `uitestFakeHTMLMessageBodySSONotice`
        /// below is the one fixture that sets this to a deliberately *wrong*
        /// non-`nil` value — see its own doc comment for why.
        var detectedLanguage: String? = nil
    }

    fileprivate static let uitestFakeHTMLMessages: [UITestFakeHTMLMessage] = [
        UITestFakeHTMLMessage(
            subject: "セキュリティ通知",
            snippet: "あなたは otegami に Example アカウントのデータの一部へのアクセスを許可しました",
            html: uitestFakeHTMLMessageBodySecurityNotice
        ),
        UITestFakeHTMLMessage(
            subject: "色指定なしのシンプルなお知らせ (UITest)",
            snippet: "このメールは背景色・文字色のどちらも一切指定していません。",
            html: uitestFakeHTMLMessageBodyNoColors
        ),
        UITestFakeHTMLMessage(
            subject: "自前ダーク対応済みのお知らせ (UITest)",
            snippet: "このメールは prefers-color-scheme で自前のダークモード対応を宣言しています。",
            html: uitestFakeHTMLMessageBodySelfDarkAware
        ),
        UITestFakeHTMLMessage(
            subject: "AppSample 2.1 (45) is ready to test on iOS. (UITest)",
            snippet: "AppSample 2.1 (45) is ready to test on iOS.",
            html: uitestFakeHTMLMessageBodyBetaTestingNotice
        ),
        UITestFakeHTMLMessage(
            subject: "A boost token is about to expire (UITest)",
            snippet: "Your boost token is nearing expiration. Kindly utilize it to boost your preferred model and win points reward.",
            html: uitestFakeHTMLMessageBodyMakerWorldLikeNotice
        ),
        UITestFakeHTMLMessage(
            subject: "四半期計画会議 (Quarterly Planning Sync) (UITest)",
            snippet: "otegami calendar organizer さんがあなたを招待しました",
            html: uitestFakeHTMLMessageBodyCalendarInviteRealisticNotice
        ),
        UITestFakeHTMLMessage(
            subject: "FakeDocs Weekly Update (UITest)",
            snippet: "共同編集がさらに高速になりました",
            html: uitestFakeHTMLMessageBodyStyleBlockGrayTextNotice
        ),
        UITestFakeHTMLMessage(
            subject: "ScribbleSync is now SOC 2 certified. (UITest)",
            snippet: "ScribbleSync が SOC 2 認証を取得しました",
            html: uitestFakeHTMLMessageBodyWhiteCardHeroNotice
        ),
        // Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
        // サインオン通知メール、hypothesis (2)): `detectedLanguage: "fr"` は
        // 実際にはフランス語のメールではなく、古いビルドが誤った言語を検出
        // して保存してしまったケースの再現 — 修正前の
        // `backfillDetectedLanguageIfNeeded`は`detectedLanguage != nil`な
        // ら常にスキップしていたので、この誤った値が永久に固定化し、
        // 明らかに英語の本文でも翻訳バー/ボタンが二度と現れなかった。
        // `MessageView.load()`が本文読み込み直後に呼ぶ再判定 (修正後) が
        // 本文から"en"を再検出し、この誤った"fr"を上書きすることを検証する。
        UITestFakeHTMLMessage(
            subject: "New sign-in to Example App (UITest)",
            snippet: "We noticed a new sign-in to your Example App account. If this was you, no action is needed.",
            html: uitestFakeHTMLMessageBodySSONotice,
            detectedLanguage: "fr"
        ),
        // Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」):
        // `html-9` — see `uitestFakeHTMLMessageBodyGmailQuoteHistory`'s doc
        // comment for what this checks (HTML branch's quote-history
        // toggle+card, newHTML-only WKWebView rendering).
        UITestFakeHTMLMessage(
            subject: "ご予約について (UITest)",
            snippet: "承知しました、21日の11時でお願いします。",
            html: uitestFakeHTMLMessageBodyGmailQuoteHistory
        )
    ]

    /// See the doc comment above `uitestFakeHTMLMessagePlaceholderImage`.
    /// Structurally identical to `31-security-notice-dark-mode.eml`'s
    /// `text/html` part (white card background + explicit dark text, no
    /// `color-scheme`/`prefers-color-scheme` of its own, a `<hr>` with two
    /// body paragraphs + a CTA button below it, and a `white-space: nowrap`
    /// footer line that deterministically forces fit-to-width's scale path)
    /// — kept in sync by hand since a UITest-only Swift string literal can't
    /// `include` the `.eml` fixture file.
    fileprivate static let uitestFakeHTMLMessageBodySecurityNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <style type="text/css">
      body { margin: 0; padding: 0; background-color: #f2f2f2; font-family: 'Helvetica Neue', Arial, sans-serif; }
      .card { max-width: 480px; margin: 24px auto; background-color: #ffffff; border: 1px solid #dadce0; border-radius: 8px; overflow: hidden; }
      .card-inner { padding: 40px 40px 32px 40px; text-align: center; }
      h1 { font-size: 20px; line-height: 26px; color: #202124; font-weight: 400; margin: 24px 0 16px 0; }
      .account-row { font-size: 14px; color: #3c4043; margin: 0 0 24px 0; }
      hr { border: none; border-top: 1px solid #e8eaed; margin: 0 0 24px 0; }
      .body-text { font-size: 14px; line-height: 20px; color: #3c4043; text-align: left; margin: 0 0 16px 0; }
      .cta { display: inline-block; background-color: #1a73e8; color: #ffffff; font-size: 14px; font-weight: 500; padding: 10px 24px; border-radius: 4px; text-decoration: none; margin: 8px 0 24px 0; }
      .footer { max-width: 480px; margin: 0 auto; padding: 0 40px 24px 40px; font-size: 11px; line-height: 16px; color: #70757a; }
      .nowrap-disclaimer { white-space: nowrap; }
    </style>
    </head>
    <body>
    <div class="card">
      <div class="card-inner">
        <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="120" height="40" alt="Example">
        <h1>あなたは otegami に Example アカウントのデータの一部へのアクセスを許可しました</h1>
        <p class="account-row">
          <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="24" height="24" style="border-radius:50%;vertical-align:middle;" alt="">
          user@example.com
        </p>
        <hr>
        <p class="body-text">otegami に Example アカウントのデータの一部へのアクセスを許可していない場合は、第三者が Example アカウントのデータにアクセスしようとしている可能性があります。</p>
        <p class="body-text">今すぐアカウント アクティビティを確認し、アカウントを保護してください。</p>
        <a class="cta" href="https://example.com/security-checkup">アクティビティを確認</a>
      </div>
    </div>
    <div class="footer">
      <p>otegami に付与したあなたのデータへのアクセス権は、Example アカウントでいつでも変更できます。</p>
      <p class="nowrap-disclaimer">このメールは security-noreply@example.com からの重要なお知らせのため配信停止の対象外です。返信はできません。</p>
    </div>
    </body>
    </html>
    """

    /// Task #51 の退行ケースそのもの — `dev/mailstack/seed/fixtures/
    /// 32-plain-html-no-colors.eml` と同内容 (背景色・文字色を一切
    /// 指定しない、最も単純な HTML メール)。ダークモードで開いても
    /// `HTMLDocumentBuilder`の CSS リセット (`color-scheme: light dark`)
    /// だけで元々正しく読めるはずで、`.otegami-invert-for-dark`が
    /// 付いてはいけない (実測が「背景が確定しない」と判定し、無変換の
    /// ままになることを確認する)。
    fileprivate static let uitestFakeHTMLMessageBodyNoColors = """
    <html>
    <body>
    <p>こんにちは、otegami です。</p>
    <p>このメールは背景色・文字色のどちらも一切指定していません。ダークモードで開いたとき、アプリの CSS リセット (color-scheme: light dark) だけに任せて自動的に明るい文字色で表示されるはずです。</p>
    <p>Task #51: ここに「反転」を無条件に適用すると、本来すでに正しく読めていたはずのこのメールが暗地に暗文字になり読めなくなる回帰があった — その再現ケース。</p>
    </body>
    </html>
    """

    /// メール自身が`<meta name="color-scheme">`と`prefers-color-scheme`
    /// メディアクエリの両方で自前のダークモード対応を宣言しているケース
    /// — `HTMLDocumentBuilder.mailDeclaresOwnDarkModeSupport(html:)`が
    /// true を返すため、`wrap(bodyHTML:autoAdjustColorsInDarkMode:)`は
    /// 反転を検討する対象からそもそも除外する (`data-otegami-invert-check`
    /// 属性すら付かない)。ライトモードでは白背景+濃色文字、ダーク
    /// モードでは自前の暗背景+明文字に自分で切り替わる想定で、
    /// どちらのモードでもアプリ側の反転が絶対にかかっていないことを
    /// 目視確認する。
    fileprivate static let uitestFakeHTMLMessageBodySelfDarkAware = """
    <!doctype html>
    <html>
    <head>
    <meta name="color-scheme" content="light dark">
    <style type="text/css">
      body { margin: 0; padding: 0; background-color: #ffffff; color: #202124; font-family: 'Helvetica Neue', Arial, sans-serif; }
      .card { max-width: 480px; margin: 24px auto; padding: 24px; }
      @media (prefers-color-scheme: dark) {
        body { background-color: #1e1e1e; color: #e8eaed; }
      }
    </style>
    </head>
    <body>
    <div class="card">
      <p>このメールは prefers-color-scheme で自前のダークモード対応を宣言しています。</p>
      <p>otegami はこのメールに対して「反転」処理を一切適用しません — ライト・ダークどちらの外観でも、この HTML 自身が指定した配色のまま表示されるはずです。</p>
    </div>
    </body>
    </html>
    """

    /// Task #56 (実機フィードバック: TestFlight通知メールで「1. 画像の
    /// 巨大化」「2. 背景なし+濃色文字が読めない」「3. 高さ切れ」「4. 要約/
    /// 翻訳フローティングボタンが本文に被る」の4点が同時発生) — 見出しの
    /// doc comment参照。`dev/mailstack/seed/fixtures/
    /// 33-beta-testing-notice.eml`と同内容 (cid: 画像をこのファイルの
    /// data: URI プレースホルダに置き換えただけ) — 手で同期を保つ理由は
    /// `uitestFakeHTMLMessageBodySecurityNotice`のdoc comment参照。
    /// 背景色を一切指定せず (1で使う`autoAdjustColorsInDarkMode`の
    /// 「背景が解決しない」経路を踏む)、`color:#444444`を明示指定
    /// (CanvasText由来ではない「著者が明示した暗い文字色」であることが
    /// この再現の肝 — 32番フィクスチャの retention と区別する実測ロジック
    /// の対象)、画像は `width`属性 + `style="width:100%;
    /// max-width:120px;"`という「レスポンシブだが上限あり」手法 (Apple/
    /// 主要ESPのテンプレートで頻出、これが無条件`max-width:100%
    /// !important`に上限を踏み潰されて拡大していた実機バグの再現条件)、
    /// リンク数本、複数段落 — 罫線こそ持たないが31番同様に段落が複数
    /// あるぶん、高さ計測 (3) の回帰確認にも使える。
    fileprivate static let uitestFakeHTMLMessageBodyBetaTestingNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>AppSample 2.1 (45) is ready to test on iOS.</title>
    </head>
    <body style="margin:0; padding:0; font-family: -apple-system, Helvetica, Arial, sans-serif; color:#444444;">
    <div style="max-width:480px; margin:0 auto; padding:24px;">
      <p style="color:#444444; font-size:15px; line-height:22px; margin:0 0 24px 0;">AppSample 2.1 (45) is ready to test on iOS.</p>
      <div style="text-align:center; margin:0 0 24px 0;">
        <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="120" height="120" alt="AppSample" style="width:100%; max-width:120px; height:auto; display:block; margin:0 auto; border-radius:22px;">
      </div>
      <p style="color:#444444; font-size:16px; line-height:24px; text-align:center; margin:0 0 24px 0;">AppSample 2.1 (45) is ready to test on iOS.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">To test this app, open <a href="https://beta.otegami.test/link/">Otegami Beta</a> on your iOS device using iOS 26.0 or later and install the update.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">You can stop testing and manage notifications in the <a href="https://beta.otegami.test/app">Otegami Beta app</a>.</p>
      <p style="color:#444444; font-size:14px; line-height:20px; margin:0 0 16px 0;">To be removed from this developer's list of potential testers, <a href="https://beta.otegami.test/contact">contact the developer</a>.</p>
      <p style="color:#444444; font-size:12px; line-height:18px; margin:24px 0 0 0;">To learn more about installation, testing, sending feedback, supported OS versions and the use of your data, visit <a href="https://beta.otegami.test/">beta.otegami.test</a>.</p>
    </div>
    </body>
    </html>
    """

    /// 実機フィードバック (MakerWorld実メールとの比較報告): ダークモードの
    /// スマート反転で (1) 右端に縦の白帯、(2) セクション間の色ムラ、(3)
    /// 透過PNGロゴが暗背景に沈む、の3点が同時発生した実例を再現する構造 —
    /// `dev/mailstack/seed/fixtures/34-white-canvas-transparent-logo.eml`と
    /// 同内容 (cid: 画像をこのファイルの
    /// `uitestFakeHTMLMessagePlaceholderTransparentLogo`に置き換えただけ)。
    /// `body`自身に`background-color:#ffffff`を明示指定 (`findEffectiveBackground`
    /// が最優先で見つける「body自身の背景」のテストケース — これが
    /// `#otegami-fit-inner`の外、bodyのpaddingの範囲でそのまま透けて残って
    /// いたのが「右端の白帯・色ムラ」の実体)、中央寄せの透過PNGロゴ、薄
    /// グレーの角丸カード、緑のCTAボタン、という組み合わせ。
    fileprivate static let uitestFakeHTMLMessageBodyMakerWorldLikeNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>A boost token is about to expire (UITest)</title>
    <style>
      body { background-color: #ffffff; margin: 0; padding: 0; }
      .otegami-fixture-card { background-color: #f3f3f5; border-radius: 8px; }
    </style>
    </head>
    <body>
    <div style="max-width:520px; margin:0 auto; padding:24px; text-align:center;">
      <img src="\(uitestFakeHTMLMessagePlaceholderTransparentLogo)" width="120" height="40" alt="MakerWorld" style="display:block; margin:0 auto 24px auto;">
      <hr style="border:none; border-top:1px solid #e0e0e0; margin:0 0 24px 0;">
      <p style="color:#222222; font-size:15px; line-height:22px; text-align:left; margin:0 0 24px 0;">Your boost token is nearing expiration. Kindly utilize it to boost your preferred model and win points reward.</p>
      <div class="otegami-fixture-card" style="padding:20px; margin:0 0 24px 0; text-align:left;">
        <p style="color:#7b3fe4; font-size:18px; font-weight:bold; margin:0 0 8px 0;">Boost Token</p>
        <p style="color:#666666; font-size:13px; margin:0 0 4px 0;">Expires on</p>
        <p style="color:#222222; font-size:14px; margin:0;">2026-08-03 10:27 UTC</p>
      </div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px 0;">
        <tr><td style="background-color:#34a853; color:#ffffff; font-size:15px; font-weight:bold; text-align:center; padding:14px 0; border-radius:4px;">Boost to model</td></tr>
      </table>
      <p style="color:#999999; font-size:12px; line-height:18px; text-align:left; margin:0;">If you wish to unsubscribe, or change notification settings: <a href="https://example.test/unsubscribe">Click here</a></p>
    </div>
    </body>
    </html>
    """

    /// Task #98 (実機報告: Google カレンダー招待メールがダークモードでほぼ
    /// 読めない) — 上の`UITestFakeHTMLMessage`配列のdoc comment
    /// (`calendarInviteRealisticNotice`項) 参照。`uitestFakeCalendarInviteHTML`
    /// (Task #84) と同じラベル/値の構造 (`#5f6368`のラベル+`#3c4043`の値、
    /// 背景指定なし) を土台に、実機の実際のメールが持つ「タイトル見出し」
    /// 「〜さんが招待しました、という色未指定の前置き」を本文冒頭に追加
    /// した — この2行 + CTAボタンの白文字で、文書順で見つかる最初の
    /// 6テキストノードのうち3つが明るい色 (見出し/前置きはCanvasText由来、
    /// ボタンは明示的な`#ffffff`) になり、`representativeTextLuminance`の
    /// 単純平均だけでは0.5をわずかに超えて「介入不要」に落ちる
    /// (`explicitDarkTextIsMajority`が無いと再現する回帰)。
    fileprivate static let uitestFakeHTMLMessageBodyCalendarInviteRealisticNotice = """
    <!doctype html>
    <html>
    <body style="font-family:Roboto,Arial,sans-serif; margin:0; padding:0;">
    <h2 style="margin:16px 24px 4px 24px; font-size:18px; font-weight:400;">四半期計画会議 (Quarterly Planning Sync)</h2>
    <p style="margin:0 24px 16px 24px; font-size:14px;">otegami calendar organizer さんがあなたを招待しました</p>
    <div style="margin:0 24px;">
    <table role="presentation" cellpadding="0" cellspacing="0" style="background-color:#1a73e8; border-radius:4px;">
    <tr><td style="padding:12px 24px;"><a href="https://meet.otegami.test/abc-defg-hij" style="color:#ffffff; font-size:14px; font-weight:bold; text-decoration:none;">Google Meet に参加する</a></td></tr>
    </table>
    <p style="color:#5f6368; font-size:12px; margin:16px 0 2px 0;">会議のリンク</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">meet.otegami.test/abc-defg-hij</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">日時</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">2026/08/03 (月曜日) &middot; 15:00 &ndash; 16:00 (日本標準時)</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">ゲスト</p>
    <p style="color:#3c4043; font-size:14px; margin:0;">Otegami Organizer - 主催者</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">Fake Calendar Invite</p>
    <p style="color:#5f6368; font-size:12px; margin:0;">このメールへの返信、またはアプリの「承諾」「辞退」「未定」ボタンで出欠をお知らせください。</p>
    </div>
    </body>
    </html>
    """

    /// Task #104 (実機報告: Readdle Documents のニュースレター等が Task #98
    /// 対策後もダークモードでほぼ読めない) — 上の`UITestFakeHTMLMessage`配列
    /// のdoc comment (`styleBlockGrayTextNotice`項) 参照。文字色をインライン
    /// `style`ではなく`<head>`の`<style>`ブロックのクラス (`.headline`/
    /// `.body-text`/`.footer-text`) で指定する点が、同じ「背景なし+
    /// 中間グレー文字」構造の`calendarInviteRealisticNotice`(Task #98) との
    /// 違い — あちらは全部インライン`style`で色指定していたため、Task #98
    /// 時点の`explicitDarkTextIsMajority`(インライン限定) でも検出できて
    /// いた。冒頭の2行 (色未指定、CanvasText由来で明るく解決) + CTA
    /// ボタンの白文字 (`.cta`、明示的だが明るい色) で最初の6テキストノード
    /// の平均を0.5超に保ちつつ、`.headline`/`.body-text`×2/`.footer-text`
    /// (すべてクラス経由の暗〜中間グレー) が文字数で過半を占める。CTA
    /// ボタン自身の`background-color`はTask #84の30%カバレッジ要件未満
    /// (`inner`に対して小さいボタン1つだけ) のため`findEffectiveBackground`
    /// は`null`のまま — カレンダー招待フィクスチャと同じ「背景なし」
    /// フォールバック経路をたどる。
    fileprivate static let uitestFakeHTMLMessageBodyStyleBlockGrayTextNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>FakeDocs Weekly Update (UITest)</title>
    <style type="text/css">
      body { margin: 0; padding: 0; font-family: -apple-system, Helvetica, Arial, sans-serif; }
      .content { padding: 0 24px; }
      .headline { color: #202124; font-size: 16px; font-weight: bold; margin: 0 0 12px 0; }
      .body-text { color: #5f6368; font-size: 14px; line-height: 20px; margin: 0 0 16px 0; }
      .cta { display: inline-block; background-color: #1a73e8; color: #ffffff; font-size: 14px; font-weight: bold; padding: 10px 24px; border-radius: 4px; text-decoration: none; }
      .footer-text { color: #80868b; font-size: 11px; line-height: 16px; margin: 24px 0 0 0; }
    </style>
    </head>
    <body>
    <p style="margin:16px 24px 4px 24px;">FakeDocs Weekly Update (UITest)</p>
    <p style="margin:0 24px 16px 24px;">FakeDocs をご利用いただきありがとうございます</p>
    <div style="text-align:center; padding:8px 0 24px 0;">
      <img src="\(uitestFakeHTMLMessagePlaceholderImage)" width="320" height="120" alt="FakeDocs">
    </div>
    <div class="content">
      <p class="headline">共同編集がさらに高速になりました</p>
      <p class="body-text">FakeDocs の最新アップデートでは、複数人での同時編集時の反映速度が大幅に改善されました。大きなドキュメントでもストレスなく共同作業を進めていただけます。</p>
      <p class="body-text">今回のアップデートには、コメント通知まわりの改善やモバイル版での表示速度向上も含まれています。詳しい変更点は以下のリンクからご確認いただけます。</p>
      <a class="cta" href="https://example.com/fakedocs-updates">アップデートの詳細を見る</a>
      <p class="footer-text">このメールは FakeDocs アカウントをお持ちの方にお送りしている週刊ニュースレターです。配信停止をご希望の場合は<a href="https://example.com/fakedocs-unsubscribe" style="color:#80868b;">こちら</a>から手続きできます。</p>
    </div>
    </body>
    </html>
    """

    /// Task #112 — see the `UITestFakeHTMLMessage`配列のdoc comment
    /// (`whiteCardHeroNotice`項) 参照。ユーザー提供の実メール `readdle.eml`
    /// の構造 (白背景の本文カード、Gmail限定`u+.body`セレクタによる無害な
    /// `mix-blend-mode`ハック、不可視の結合文字を含む隠しプリヘッダ、
    /// インライン`style`と`<style>`ブロックの両方に混在する`#333333`/
    /// `rgb(51, 51, 51)`系の低輝度文字色) を、架空ブランド・
    /// `example.com`のみで再現したもの。実物とちがい `body`自身に明示的な
    /// 白背景を与えている — `findEffectiveBackground`が
    /// `opaqueBackgroundOf(document.body)`を最優先で信頼する
    /// (`HTMLMessageView.swift`の`fitToWidthScript`参照) ので、実物のように
    /// 面積30%ルールに賭けなくても確実に「背景あり」経路
    /// (`decideDarkInversion`の`if (background)`枝) に入ることを保証できる。
    fileprivate static let uitestFakeHTMLMessageBodyWhiteCardHeroNotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>ScribbleSync is now SOC 2 certified. (UITest)</title>
    <style type="text/css">
      u+.body .gmail-screen { background: #000; mix-blend-mode: screen; }
      u+.body .gmail-difference { background: #000; mix-blend-mode: difference; }
      body { margin: 0; padding: 0; font-family: -apple-system, Helvetica, Arial, sans-serif; background-color: #ffffff; }
      .card { max-width: 480px; margin: 0 auto; padding: 0 24px 24px 24px; }
      .headline { color: #111111; font-size: 16px; font-weight: bold; margin: 0 0 12px 0; }
      .body-text { color: rgb(51, 51, 51); font-size: 14px; line-height: 20px; margin: 0 0 16px 0; }
      .footer-text { color: #333333; font-size: 11px; line-height: 16px; margin: 24px 0 0 0; }
    </style>
    </head>
    <body class="body" style="margin:0;padding:0;background-color:#ffffff;">
    <span style="display:none !important;font-size:0px;line-height:0;color:#ffffff;visibility:hidden;opacity:0;height:0;width:0;">ScribbleSync が SOC 2 認証を取得しました。詳しくは本文をご覧ください ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌ ‌</span>
    <div style="background-image:url(\(uitestFakeHTMLMessagePlaceholderImage)); background-color:#0d1b2a; padding:50px 24px;">
      <span class="gmail-screen"><span class="gmail-difference" style="color:#ffffff; font-size:14px;">What's new</span></span>
      <h1 style="color:#ffffff; font-size:26px; margin:8px 0 0 0;">ScribbleSync is now SOC 2 certified</h1>
    </div>
    <div class="card">
      <p class="headline">セキュリティに関する重要なお知らせ</p>
      <p class="body-text">ScribbleSync は第三者機関による監査を経て、SOC 2 Type II 認証を取得しました。お客様のデータは引き続き高い水準で保護されており、今回の認証はその取り組みを第三者の立場から裏付けるものです。</p>
      <p class="body-text">認証の詳細および監査レポートの請求方法については、以下のリンクからご確認いただけます。ご不明な点がございましたらサポートまでお問い合わせください。</p>
      <a href="https://example.com/scribblesync-soc2" style="display:inline-block;background-color:#128cfc;color:#ffffff;font-size:14px;font-weight:bold;padding:10px 24px;border-radius:4px;text-decoration:none;">詳しく見る</a>
      <p class="footer-text">このメールは ScribbleSync アカウントをお持ちの方にお送りしています。配信停止をご希望の場合は<a href="https://example.com/scribblesync-unsubscribe" style="color:#333333;">こちら</a>から手続きできます。</p>
    </div>
    </body>
    </html>
    """

    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール, scratchpad/signon.eml — 実アドレス入りのため
    /// コミット不可): 実物と同じ「英語のみ・テーブルベースの構造化レイアウト・
    /// SSO/認証プロバイダ系の通知テンプレート」という形を、架空ブランド名
    /// (Example App / IdP) だけで再現したもの。実物の文面・ロゴ・宛先は一切
    /// 含まない — このフィクスチャ自体は翻訳ボタンの表示条件バグ (この上の
    /// `uitestFakeHTMLMessages`配列でこのフィクスチャに付けている
    /// `detectedLanguage: "fr"`が本題) を再現するための入れ物で、HTML の
    /// 構造そのもの (どこかで抽出/接続が壊れるような特殊なマークアップ) を
    /// 疑う調査は本タスクの範囲では実機ログでしか確定できなかった
    /// (`MessageView.translationGateLogger`のdoc comment参照) ため、ここでは
    /// 「一見して英語だと分かる、ごく普通のテーブルベースSSO通知」という
    /// 現実的な最小形にとどめている。
    fileprivate static let uitestFakeHTMLMessageBodySSONotice = """
    <!doctype html>
    <html>
    <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>New sign-in to Example App (UITest)</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">
    <tr><td align="center" style="padding:32px 16px;">
    <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background-color:#ffffff; border-radius:4px;">
    <tr><td style="padding:24px; border-bottom:1px solid #e0e0e0;">
      <span style="color:#1c1c1c; font-size:18px; font-weight:bold;">Example App</span>
    </td></tr>
    <tr><td style="padding:24px;">
      <p style="color:#1c1c1c; font-size:16px; margin:0 0 16px 0;">New sign-in to Example App</p>
      <p style="color:#4a4a4a; font-size:14px; line-height:20px; margin:0 0 16px 0;">We noticed a new sign-in to your Example App account. If this was you, no action is needed.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%; margin:0 0 16px 0;">
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Browser</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">Example Browser</td></tr>
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Location</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">Example City, Example Country</td></tr>
        <tr><td style="color:#767676; font-size:13px; padding:4px 0;">Date</td><td style="color:#1c1c1c; font-size:13px; padding:4px 0;" align="right">August 3, 2026, 9:00 AM UTC</td></tr>
      </table>
      <p style="color:#4a4a4a; font-size:14px; line-height:20px; margin:0 0 16px 0;">If you don't recognize this activity, please secure your account immediately by resetting your password.</p>
      <a href="https://example.com/account/security" style="display:inline-block;background-color:#0066cc;color:#ffffff;font-size:14px;font-weight:bold;padding:10px 24px;border-radius:4px;text-decoration:none;">Secure my account</a>
    </td></tr>
    <tr><td style="padding:16px 24px; border-top:1px solid #e0e0e0;">
      <p style="color:#9a9a9a; font-size:11px; line-height:16px; margin:0;">This is an automated message from Example App. Please do not reply to this email.</p>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """

    /// Task #133 (実機報告「引用折りたたみがHTMLメールで効かない」— #123の
    /// 折りたたみはプレーンテキスト表示限定だったが、実際のGmailはほぼ全部
    /// HTML付きでHTML表示が優先されるため実機で機能しなかった、ユーザー提供
    /// の実メール`yoyaku.eml`で再現・修正): `html-9`シナリオ (index 8はTask #128の
    /// SSO通知フィクスチャがすでに使用中のため、9から採番) — 実物と同じ
    /// Gmail HTML の引用構造 (`<div class="gmail_quote">` が
    /// `<div class="gmail_attr">`(帰属行) と入れ子の
    /// `<blockquote class="gmail_quote" style="...border-left...">`を包む、
    /// 2段ネスト) を持つが、内容は実物と無関係な架空の予約確認シナリオ・
    /// 架空名・example.com アドレスに差し替えた匿名フィクスチャ (実物は
    /// 機微データのためコミット禁止 — `docs/design-system.md`のTask #133
    /// 節「検証」参照。実物での確認はシミュレータへの一時注入で別途行い、
    /// 確認後にコードをrevertした)。
    /// `HTMLMessageView`には新規部分のHTMLだけが渡り、引用履歴 (2段) は
    /// `QuoteHistorySectionView`のトグル+カードに折りたたまれることを
    /// スクリーンショットで確認する用途。
    fileprivate static let uitestFakeHTMLMessageBodyGmailQuoteHistory = """
    <div dir="ltr"><div dir="auto">田中さん</div><div dir="auto">承知しました、21日の11時でお願いします。</div><div dir="auto">当日はよろしくお願いいたします。</div><div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">2026年7月20日(月) 15:00 田中花子 &lt;<a href="mailto:hanako@example.com">hanako@example.com</a>&gt;:</div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex"><div dir="auto">ご予約ありがとうございます。</div><div dir="auto">21日11時でお取りできます。</div><div dir="auto">前日までにお店へご確認のお電話をお願いいたします。</div><div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">2026年7月20日(月) 14:30 佐藤太郎 &lt;<a href="mailto:taro@example.com">taro@example.com</a>&gt;:</div><blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex"><div dir="auto">はじめまして、佐藤です。</div><div dir="auto">7月21日の11時に予約をお願いしたいのですが、空いていますでしょうか。</div><div dir="auto">よろしくお願いいたします。</div></blockquote></div></div></blockquote></div></div></div>
    """

    // MARK: - Task #66 (カレンダー招待メール対応) UITest fixture

    /// `OTEGAMI_UITEST_INSERT_FAKE_CALENDAR_INVITE`'s `text/calendar`
    /// content — same event as `dev/mailstack/seed/fixtures/
    /// 36-calendar-invite-google.eml`'s `METHOD:REQUEST` part, so a
    /// screenshot taken via this escape hatch and one taken against the
    /// real dev mailstack (once IMAP-in-Simulator is reliable, or on a
    /// physical device) show the identical invite.
    fileprivate static let uitestFakeCalendarInviteICS = """
    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART:20260803T060000Z
    DTEND:20260803T070000Z
    DTSTAMP:20260728T000000Z
    ORGANIZER;CN=Otegami Organizer:mailto:organizer@otegami.test
    UID:uitest-fake-calendar-invite-event@otegami.test
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Fake Calendar Invite:mailto:uitest-fake-calendar-invite@example.com
    CREATED:20260728T000000Z
    DESCRIPTION:四半期の計画会議です。事前に資料をご確認ください。
    LAST-MODIFIED:20260728T000000Z
    LOCATION:会議室A / Conference Room A
    SEQUENCE:0
    STATUS:CONFIRMED
    SUMMARY:四半期計画会議 (Quarterly Planning Sync)
    TRANSP:OPAQUE
    END:VEVENT
    END:VCALENDAR
    """

    /// Task #84: real-device report (screenshot) showed a genuine Google
    /// Calendar invite's HTML rendering with washed-out light-gray text on
    /// the app's dark canvas — this reproduces that mail's actual shape
    /// (no `background-color` anywhere, secondary labels in `#5f6368`,
    /// primary values in `#3c4043`, matching `dev/mailstack/seed/fixtures/
    /// 37-calendar-invite-nested-alternative.eml`'s `text/html` part) so
    /// `scripts/verify-screen.sh calendar-invite`'s screenshot can show
    /// whether the dark-mode "keep light" heuristic (`HTMLDocumentBuilder
    /// .wrap`/`fitToWidthScript`'s `decideDarkInversion`, Task #80) actually
    /// fires for this content.
    fileprivate static let uitestFakeCalendarInviteHTML = """
    <html><body style="font-family:Roboto,Arial,sans-serif;">
    <table role="presentation" cellpadding="0" cellspacing="0" style="background-color:#1a73e8; border-radius:4px;">
    <tr><td style="padding:12px 24px;"><a href="https://meet.otegami.test/abc-defg-hij" style="color:#ffffff; font-size:14px; font-weight:bold; text-decoration:none;">Google Meet に参加する</a></td></tr>
    </table>
    <p style="color:#5f6368; font-size:12px; margin:16px 0 2px 0;">会議のリンク</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">meet.otegami.test/abc-defg-hij</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">日時</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">2026/08/03 (月曜日) &middot; 15:00 &ndash; 16:00 (日本標準時)</p>
    <p style="color:#5f6368; font-size:12px; margin:0 0 2px 0;">ゲスト</p>
    <p style="color:#3c4043; font-size:14px; margin:0;">Otegami Organizer - 主催者</p>
    <p style="color:#3c4043; font-size:14px; margin:0 0 16px 0;">Fake Calendar Invite</p>
    <p style="color:#5f6368; font-size:12px; margin:0;">このメールへの返信、またはアプリの「承諾」「辞退」「未定」ボタンで出欠をお知らせください。</p>
    </body></html>
    """
}

/// Bridges `GoogleProfilePhotoAvatarResolver` (an actor with no reachable
/// path to `AppEnvironment` at construction time — it's built inside
/// `AppEnvironment.init()` alongside the other `AvatarImageResolving`
/// sources, before `database`/`tokenStore`/`accounts` exist at all) to the
/// live Gmail account list and `TokenStore` it needs at *call* time, once
/// avatar resolution actually starts happening (well after `init()` has
/// returned). Mirrors `PendingSendCoordinator`'s `weak var environment`/
/// `configure(environment:)` two-phase wiring (see that type's doc comment
/// for the identical reasoning): created with a `nil` `environment` by
/// `AppEnvironment`'s `gmailAccessTokenBridge` property (a default-valued
/// stored property, so it already exists before `init()`'s body runs), then
/// wired to `self` as the very last step of `init()`.
///
/// `@MainActor` (not an `actor`) specifically so `configure(environment:)`
/// can be called synchronously from `AppEnvironment.init()` itself, the same
/// constraint `PendingSendCoordinator.configure(environment:)` is under.
/// `@unchecked Sendable`: every stored property (`environment`) is only ever
/// read/written while isolated to the main actor — the compiler can't verify
/// that automatically for a plain (non-`actor`) class, but the isolation
/// itself makes it safe, matching this codebase's other `@unchecked
/// Sendable` main-actor-isolated types (e.g. `ASWebAuthenticationSessionRunner`'s
/// doc comment).
@MainActor
final class GmailAccessTokenBridge: GmailAccessTokenProviding, @unchecked Sendable {
    private weak var environment: AppEnvironment?

    func configure(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Before `configure(environment:)` has run (a narrow window: only
    /// between `avatarImageResolver`'s construction and the
    /// `configure(environment:)` call a few dozen lines later in the same
    /// `init()`) this returns `[]`, same as "no Gmail accounts yet" — never
    /// a crash, just a resolver that quietly has nothing to offer yet.
    func gmailAccountIds() async -> [String] {
        guard let environment else { return [] }
        return environment.accounts.filter { $0.kind == .gmail }.map(\.id)
    }

    func accessToken(for accountId: String) async throws -> String {
        guard let environment, let tokenStore = environment.tokenStore else {
            throw GoogleOAuth.TokenStoreError.missingRefreshToken
        }
        return try await tokenStore.accessToken(for: accountId)
    }
}
