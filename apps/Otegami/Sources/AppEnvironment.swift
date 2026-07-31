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
import OtegamiTranslationApple
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
    /// Task #200 (Composer 宛先サジェスト) — see `RecipientSuggestionSource`'s
    /// doc comment for sourcing/caching. One shared instance so its cache
    /// (built from a scan of message history) is reused across every
    /// composer session in this launch, not rebuilt from scratch each time.
    let recipientSuggestionSource: RecipientSuggestionSource
    /// Task #56 — see `UITestSeeder`'s
    /// `OTEGAMI_UITEST_OPEN_HTML_MESSAGE_AT_INDEX` documentation. Non-nil
    /// only when that env var was set at launch; `nil` in
    /// every real launch. `MailScreenView`'s matching `.task` reads this
    /// once and pushes straight to that thread — the "UITest の直接遷移
    /// 経路" fallback for when this simulator/toolchain's `MessageListRow`
    /// tap doesn't register.
    var uitestDirectOpenThreadId: Int64? = nil
    /// C6/C7 送信キャンセル — see `PendingSendCoordinator`'s doc comment.
    let pendingSendCoordinator = PendingSendCoordinator()
    /// Task #192 (実機クラッシュ 0xDEAD10CC 対策) — see
    /// `suspendSharedDatabaseIfNeeded()`/`resumeSharedDatabaseIfNeeded()`'s
    /// doc comments below and `DatabaseSuspensionTracker`'s for the dedup
    /// this exists for. Not `#if os(iOS)`-gated itself (a plain, inert
    /// value on macOS too) — only the two methods that actually post GRDB's
    /// suspend/resume notifications are, matching `OtegamiAppGroup
    /// .identifier`'s "App Group stays iOS-only" scoping.
    @ObservationIgnored private let databaseSuspensionTracker = DatabaseSuspensionTracker()
    /// アバター強化バッチ「Google プロフィール写真」— see `GmailAccessTokenBridge`'s
    /// doc comment. Default-initialized here (no dependency on anything else
    /// in this class), same "wired to `self` at the very end of `init()`"
    /// two-phase pattern as `pendingSendCoordinator` right above — this is
    /// what makes it safe to already be usable when `avatarImageResolver`
    /// below is built, well before `database`/`tokenStore` exist.
    @ObservationIgnored private let gmailAccessTokenBridge = GmailAccessTokenBridge()
    /// M9: push opt-in. `pushSettings` is the persistence layer
    /// (`PushSettingsStore`'s doc comment); `isPushEnabled` mirrors it into
    /// `@Observable` state so `PushNotificationSettingsView` doesn't read
    /// `UserDefaults` directly. The relay *URL* itself is no longer part of
    /// this state (Task #173 follow-up: `RelayURLConfig`, a build-time
    /// value like `RelayRegistrationSecretConfig`) — see that type's doc
    /// comment.
    let pushRelayClient = PushRelayClient()
    @ObservationIgnored let pushSettings: PushSettingsStore
    private(set) var isPushEnabled: Bool

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
    /// Task #186 (「iCloud でアカウントの設定以外も全て同期して欲しい」): the
    /// signature/mail-template counterpart to `accountCloudSync` — syncs
    /// `signatureTemplate`/`mailTemplate` rows through the `"templates.v1"`
    /// KVS key (`TemplateCloudSyncEngine`, `docs/icloud-sync.md`'s Task
    /// #186 section), gated by the exact same `cloudSyncSettings`/
    /// `isCloudSyncPermittedOnThisBuild()` toggle as `accountCloudSync`/
    /// `settingsCloudSync`.
    @ObservationIgnored let templateCloudSync: TemplateCloudSyncEngine
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

    /// design-phase-3 (1i/1k, `docs/translation.md`); Task #159 (メール翻訳を
    /// Apple Translation フレームワークの専用 NMT へ切替): the raw engine —
    /// `HybridTranslationService` (`OtegamiTranslation`) in every normal
    /// build, which routes `translate`/`translateParagraphs`/`translateStream`
    /// to `AppleTranslationService` (`OtegamiTranslationApple`, backed by
    /// `Translation.TranslationSession`) and `summarize`/`summarizePlain`/
    /// `summarizeThreadDigest` to `FoundationModelsTranslationService`
    /// unchanged (a general-purpose on-device LLM remains the right tool for
    /// summarization; a dedicated NMT model is not — see
    /// `HybridTranslationService`'s own doc comment). `ComposerView`'s old
    /// "英語に翻訳して送る" one-off use of this property (no `messageId` for a
    /// draft still being typed, so `MessageTranslator`'s per-message cache
    /// didn't apply) was itself removed by Task #139
    /// (`ComposerLaunchPayload`'s own doc comment) — this app's deployment
    /// target being iOS/macOS 26+ (`project.yml`) still means both engines
    /// are unconditionally available at *compile* time regardless. Whether
    /// translation can actually run on *this* device/language-pack state is
    /// a runtime question `isTranslationAvailable` below answers by reading
    /// `availability`, which `HybridTranslationService` forwards from its
    /// translation engine specifically, not its summarization one — see
    /// `isSummarizationAvailable` for the separate (Foundation Models-only)
    /// question. `init()`'s `OTEGAMI_UITEST_FAKE_TRANSLATION` check is the
    /// one exception — swaps in `FakeTranslationService` (normally a tests/
    /// previews-only type, `OtegamiTranslation`'s own doc comment) for
    /// *both* translate and summarize, purely so 1i's HTML-preserving
    /// translation display can still be verified end-to-end on a Simulator
    /// where neither Foundation Models nor (likely — unverified, see
    /// `docs/translation.md`'s Task #159 section) the Translation framework
    /// itself runs.
    @ObservationIgnored let translationService: any TranslationService
    /// Task #159: `FoundationModelsTranslationService`'s own `availability`,
    /// read directly (not through `translationService`, whose `availability`
    /// now answers for the *translation* engine only — see that property's
    /// doc comment) — what `isSummarizationAvailable` below reports.
    /// `OTEGAMI_UITEST_FAKE_TRANSLATION` swaps this for `FakeTranslationService`
    /// too, in lockstep with `translationService`, so a UITest run gates the
    /// summarize button the same fake-availability way it already gated the
    /// translate button before this task.
    @ObservationIgnored let summarizationService: any TranslationService
    /// Task #159: the bridge `AppleTranslationService` uses to obtain a live
    /// `Translation.TranslationSession` — `TranslationSession` has no public
    /// initializer, so this coordinator's `configuration` has to be read by
    /// an actual SwiftUI view's `.translationTask(_:action:)` somewhere in
    /// the tree (`TranslationSessionHostView`, mounted once at
    /// `ThreadDetailView`'s root) for a session to ever come back at all.
    /// One instance for the whole app (not per-thread-detail-screen): a
    /// second `ThreadDetailView` instance reusing the same coordinator just
    /// means both share the one already-obtained session for a given target
    /// language rather than each needing its own — see
    /// `TranslationSessionCoordinator`'s own doc comment. Constructed
    /// unconditionally (even under `OTEGAMI_UITEST_FAKE_TRANSLATION`, which
    /// never actually uses it) so `TranslationSessionHostView` always has a
    /// non-optional coordinator to read from.
    @ObservationIgnored let translationSessionCoordinator = TranslationSessionCoordinator()
    /// 2026-07-30 (実機フィードバック: ログ採取できない状況での端末内診断
    /// 画面「翻訳の診断」): `AppleTranslationService`の直近の呼び出し記録
    /// — `TranslationDiagnosticsStore`のdoc comment参照。コーディネータと
    /// 同じくアプリ全体で1つ (UITest フェイク翻訳経路では書き込まれない
    /// — 実エンジンだけが対象)。
    @ObservationIgnored let translationDiagnostics = TranslationDiagnosticsStore()
    /// Task #213: reads (never writes) the shared App Group `UserDefaults`
    /// record of `NotificationService`'s recent runs — see
    /// `PushDiagnosticsStore`'s own doc comment. One instance for the whole
    /// app, same "single shared instance" shape as `translationDiagnostics`
    /// right above.
    @ObservationIgnored let pushDiagnostics = PushDiagnosticsStore()
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

    /// Drives the translation bar's/toolbar button's enabled state — `false`
    /// covers every `TranslationUnavailableReason` the *translation* engine
    /// (`AppleTranslationService`, since Task #159) reports with one check,
    /// matching how `isGmailOAuthConfigured` above collapses its own
    /// availability question to a single `Bool` for view code.
    /// `AppleTranslationService.availability` always reports `.available`
    /// (its own doc comment — Task #159 point 3, "翻訳ボタンは常時有効の現仕様
    /// 維持") except through `OTEGAMI_UITEST_FAKE_TRANSLATION`'s
    /// `FakeTranslationService`, so this is effectively always `true` in a
    /// normal build now — an undownloaded language pack surfaces as a
    /// `TranslationServiceError` from an actual translate attempt instead,
    /// not as this flag going false.
    var isTranslationAvailable: Bool { translationService.availability.isAvailable }

    /// Task #159: the *summarization* engine's own availability
    /// (`FoundationModelsTranslationService.availability`, unchanged —
    /// `SystemLanguageModel.default.availability`, a real device-eligibility
    /// check), read from `summarizationService` directly rather than through
    /// `translationService` — before this task, one `TranslationService`
    /// backed both features, so a single `isTranslationAvailable` flag
    /// correctly gated both the summarize and translate buttons
    /// (`MessageDetailFooterToolbar.isSummarizeEnabled`/`isTranslateEnabled`
    /// both read it). Now that translation and summarization are two
    /// different engines with two different availability stories, they need
    /// two different flags — `isSummarizeEnabled` was updated to read this
    /// one instead.
    var isSummarizationAvailable: Bool { summarizationService.availability.isAvailable }

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
        self.recipientSuggestionSource = RecipientSuggestionSource(dbWriter: database.dbWriter)

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

        self.uitestDirectOpenThreadId = UITestSeeder.seedIfRequested(db: database.dbWriter)

        self.syncCoordinator = SyncCoordinator(
            database: database,
            sessionFactory: { config in MailCoreIMAPSession(config: config) },
            smtpSessionFactory: { config in MailCoreSMTPSession(config: config) },
            messageBuilder: { draft in MailCoreMessageBuilder.build(draft) }
        )
        // `credentialStore` itself was constructed further up — see the
        // duplicate-account-merge block's comment on why.

        // design-phase-3: see `translationService`/`messageTranslator`'s
        // doc comments. Task #159 (メール翻訳を Apple Translation フレーム
        // ワークの専用 NMT へ切替): `translationService` is now
        // `HybridTranslationService` — `AppleTranslationService` (this
        // engine's `translate`/`translateParagraphs`/`translateStream`) needs
        // `translationSessionCoordinator` below, bridged into a live
        // `Translation.TranslationSession` by `TranslationSessionHostView`
        // (mounted in `ThreadDetailView`); `summarize`/`summarizePlain`/
        // `summarizeThreadDigest` still go to `FoundationModelsTranslationService`
        // unchanged, kept separately as `summarizationService` too (for
        // `isSummarizationAvailable`'s own doc comment).
        //
        // `OTEGAMI_UITEST_FAKE_TRANSLATION`: this project's Simulator/host
        // combination can't actually run Foundation Models from inside the
        // sandboxed `.app` process (`FoundationModelsTranslationService.translateParagraphs`
        // consistently throws `FoundationModels.LanguageModelError error -1`
        // there, confirmed not a code bug — the identical call succeeds in
        // 2-5s run instead as a plain `swift test` process on the same host;
        // `docs/translation.md`'s "既知の制限" section has the full
        // writeup) — and, per that same doc's Task #159 section, likely
        // can't run the Translation framework either (unverified — no
        // Simulator repro attempted yet, same category of known Simulator
        // unreliability). That makes the HTML-preserving translation display
        // path (1i) impossible to verify end-to-end via either real on-
        // device engine on this Simulator — this flag substitutes
        // `FakeTranslationService` for *both* translate and summarize
        // (deterministic `"[ja] ..."` output, no Apple Intelligence/
        // Translation-framework dependency) so a UITest/manual verify run
        // can still drive the actual DOM-rewrite/layout-preservation code
        // path, matching this file's other `OTEGAMI_UITEST_*` launch-
        // environment overrides (`deleteCredentialIfUITestRequested`'s doc
        // comment in `MessageView`, `OTEGAMI_UITEST_DISABLE_CLOUD_SYNC`
        // below).
        let translationService: any TranslationService
        let summarizationService: any TranslationService
        let translationEngineIdentifier: String
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FAKE_TRANSLATION"] == "1" {
            translationService = FakeTranslationService()
            summarizationService = translationService
            translationEngineIdentifier = MessageTranslator.EngineIdentifier.fake
        } else {
            let foundationModelsService = FoundationModelsTranslationService()
            translationService = HybridTranslationService(
                translationEngine: AppleTranslationService(coordinator: translationSessionCoordinator, diagnostics: translationDiagnostics),
                summarizationEngine: foundationModelsService
            )
            summarizationService = foundationModelsService
            translationEngineIdentifier = MessageTranslator.EngineIdentifier.appleTranslation
        }
        self.translationService = translationService
        self.summarizationService = summarizationService
        self.messageTranslator = MessageTranslator(
            database: database,
            service: translationService,
            engineIdentifier: translationEngineIdentifier
        )

        let pushSettings = PushSettingsStore(accessGroup: OtegamiAppGroup.keychainAccessGroup)
        self.pushSettings = pushSettings
        self.isPushEnabled = pushSettings.isEnabled
        // Task #171/#173 follow-up cleanup — see `PushSettingsStore
        // .deleteLegacyRegistrationSecretIfPresent()`/
        // `.deleteLegacyRelayURLIfPresent()`'s doc comments: wipes
        // whatever a device that used the now-removed "登録シークレット"/
        // relay-URL Settings fields under an earlier build still has left
        // in the Keychain/UserDefaults. Unconditional/every-launch, not
        // gated behind a one-time-only flag — cheap no-op once the item is
        // actually gone.
        pushSettings.deleteLegacyRegistrationSecretIfPresent()
        pushSettings.deleteLegacyRelayURLIfPresent()

        // Task #176: unconditional/every-launch, same style as the two
        // cleanup calls right above — guarantees the App Group mirror
        // `NotificationService` actually reads is never more than one
        // launch stale, even for a device that upgraded to this app
        // version without ever opening `PushNotificationSettingsView` or
        // receiving a settings.v2 pull (`NotificationContentSettingsStore`'s
        // doc comment has the other 2 call sites that keep it fresh after
        // this).
        NotificationContentSettingsStore.mirrorToAppGroup()

        // Task #173 (`scripts/verify-screen.sh`'s `push-settings-watches`
        // scenario): screenshotting `PushWatchStatusSection`'s populated
        // states needs push "enabled" and a non-empty, varied watch list —
        // neither of which this dev machine can produce for real without
        // either driving the full APNs/notification-permission flow (the
        // Simulator can't get a device token at all, `PushTokenCenter`'s
        // doc comment) or making a live request to whatever real relay
        // this build happens to be configured against. Forcing
        // `isPushEnabled` here is display-only — it never touches
        // `pushSettings.isEnabled` (the persisted value `enable()`/
        // `disable()` actually manage), so nothing about this survives a
        // fresh, non-UITest launch.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FORCE_PUSH_ENABLED"] == "1" {
            self.isPushEnabled = true
        }
        // Three fake `.password`-auth accounts covering the three
        // relay-dependent statuses `PushWatchDisplayRow.Status` can be in
        // (`.registered`/`.stopped`/`.notRegistered`) — paired with
        // `OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES` below providing
        // fixed `WatchSummary` entries for the first two, and simply
        // having no entry at all for the third. The existing
        // `OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT` fixture (used
        // elsewhere) already covers `.unsupported`. Display-only: no
        // Keychain password is stored for these, since nothing here ever
        // calls `registerWatch`/hits the network.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_PUSH_WATCH_ACCOUNTS"] == "1" {
            let baseSortOrder = ((try? database.dbWriter.read { db in
                try AccountRecord.fetchAll(db)
            })?.map(\.sortOrder).max() ?? -1) + 1
            let fixtures: [(id: String, displayName: String, email: String)] = [
                ("uitest-fake-registered", "Fake Registered (UITest)", "uitest-fake-registered@otegami.test"),
                ("uitest-fake-stopped", "Fake Stopped (UITest)", "uitest-fake-stopped@otegami.test"),
                ("uitest-fake-notregistered", "Fake Not Registered (UITest)", "uitest-fake-notregistered@otegami.test"),
            ]
            try? database.dbWriter.write { db in
                for (offset, fixture) in fixtures.enumerated() {
                    guard try AccountRecord.filter(Column("id") == fixture.id).fetchOne(db) == nil else { continue }
                    let account = AccountRecord(
                        id: fixture.id,
                        displayName: fixture.displayName,
                        email: fixture.email,
                        authType: .password,
                        imapHost: "imap.example.test",
                        imapPort: 993,
                        imapSecurity: .tls,
                        imapUsername: fixture.email,
                        sortOrder: baseSortOrder + offset
                    )
                    try account.insert(db)
                }
            }
        }

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
                // Task #186 (「iCloud でアカウントの設定以外も全て同期して
                // 欲しい」) — ユーザー指示によりこのゲートを撤回した。旧
                // 実装 (2026-07-29〜) は、macOS の操作体系再設計のときに
                // 出た別の指示「mac では、アカウント以外の情報は iCloud
                // 同期しなくて良い」を受けて settings.v2 を macOS だけ
                // 読み書きしない `#if os(macOS) { false }` にしていた —
                // 今回はその方針そのものが覆り、両プラットフォームで
                // アカウント以外の設定も同期する形に統一する。反転の経緯
                // は `docs/icloud-sync.md`「macOS でも設定を同期する
                // (Task #186、方針の反転)」節参照。
                cloudSyncSettings.isEnabled && AppEnvironment.isCloudSyncPermittedOnThisBuild()
            }
        )
        self.templateCloudSync = TemplateCloudSyncEngine(
            store: SystemUbiquitousStore(),
            local: CloudTemplateDirectory(database: database),
            isEnabled: { [cloudSyncSettings] in
                // Task #186: same toggle, same guard, both platforms — no
                // macOS-only gate here either (this engine post-dates the
                // reversal above, so it never had one to begin with).
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
        // Task #186: `templateCloudSync` joins the same two trigger points
        // as `settingsSync` — see this type's doc comment for why it shares
        // `accountCloudSync`'s architecture but not its KVS key.
        let templateSync = templateCloudSync
        Task {
            await cloudSync.reconcile()
            await settingsSync.reconcile()
            await templateSync.reconcile()
        }
        cloudSyncNotificationObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: nil
        ) { _ in
            Task {
                await cloudSync.reconcile()
                await settingsSync.reconcile()
                await templateSync.reconcile()
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

    /// `GeneralSettingsView`'s "iCloud でアカウントを同期" toggle (moved
    /// there from `AccountSettingsCategoryView` by Task #189; the identifier
    /// string above is stale history, not this method's current call site).
    /// Flipping it
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

    /// Task #186: `pushAccountToCloud`'s counterpart for a locally-added or
    /// -edited signature — called from `SignatureTemplateEditView.save()`
    /// right after its `dbWriter.write` insert/update, instead of waiting
    /// for the next full `templateCloudSync.reconcile()`.
    func pushSignatureToCloud(_ signature: SignatureTemplateRecord) async {
        await templateCloudSync.pushLocalSignatureChange(CloudSignatureSnapshot(record: signature))
    }

    /// Called from `SignatureTemplatesSettingsView.deleteSignature(_:)`
    /// right after the local `deleteOne`.
    func pushSignatureDeletionToCloud(syncId: String) async {
        await templateCloudSync.pushLocalSignatureDeletion(syncId: syncId)
    }

    /// `pushSignatureToCloud`'s counterpart for mail templates (C8) —
    /// called from `TemplateEditView.save()`.
    func pushMailTemplateToCloud(_ template: MailTemplateRecord) async {
        await templateCloudSync.pushLocalMailTemplateChange(CloudMailTemplateSnapshot(record: template))
    }

    /// Called from `TemplatesSettingsView.deleteTemplate(_:)`.
    func pushMailTemplateDeletionToCloud(syncId: String) async {
        await templateCloudSync.pushLocalMailTemplateDeletion(syncId: syncId)
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
        /// Task #173 follow-up: this *build* has no relay URL baked in
        /// (`RelayURLConfig.value == nil`) — there's nowhere left for the
        /// user to type one, so `enablePushNotifications()` refuses up
        /// front rather than the old "type a bad URL" failure mode.
        /// `PushNotificationSettingsView` disables its "有効にする" button
        /// whenever `RelayURLConfig.isConfigured == false`, so reaching
        /// this case in practice would mean the button's own guard had a
        /// bug — kept as a safety net, not an expected user-facing path.
        case relayNotConfigured
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
        /// `NotificationService`).
        case unsupportedPlatform
        /// Task #171 (follow-up: build-time secret, see
        /// `RelayRegistrationSecretConfig`): `POST /v1/devices` came back
        /// 401 — the relay has `RELAY_DEVICE_REGISTRATION_SECRET`
        /// configured and either this build has no
        /// `OTEGAMI_RELAY_REGISTRATION_SECRET` baked in, or the one it has
        /// doesn't match what the relay expects.
        /// `PushNotificationSettingsView` surfaces this without repeating
        /// the relay's own error text (`DeviceRoutes
        /// .authorizeRegistration`'s message is an operator/debugging
        /// detail, not something to show the end user verbatim), and
        /// distinguishes the two cases via `isRelayRegistrationSecretConfigured`.
        case registrationSecretRejected
    }

    /// Requests notification authorization + an APNs device token,
    /// registers this device with the build's baked-in relay
    /// (`RelayURLConfig.value` — Task #173 follow-up), and creates a watch
    /// for every currently push-watch-eligible account
    /// (`isPushWatchCandidate(_:)` — every `.password` account, plus
    /// `.oauth2` Gmail/Microsoft accounts as of Task #175, which sends the
    /// account's refresh token to the relay instead of an IMAP password;
    /// see `watchAuth(for:)`'s doc comment for what that changes). Persists
    /// everything via `pushSettings` as it goes, so a failure partway
    /// through (e.g. the device registers fine but one account's watch
    /// creation fails) still leaves whatever succeeded in place rather than
    /// needing to be redone from scratch.
    func enablePushNotifications() async throws {
        guard let baseURL = RelayURLConfig.value else {
            throw PushError.relayNotConfigured
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
            let response: RegisterDeviceResponse
            do {
                response = try await pushRelayClient.registerDevice(
                    baseURL: baseURL,
                    apnsToken: apnsToken,
                    environment: apnsEnvironment,
                    registrationSecret: RelayRegistrationSecretConfig.value
                )
            } catch let PushRelayClient.PushRelayClientError.http(status, _) where status == 401 {
                throw PushError.registrationSecretRejected
            }
            deviceId = response.deviceId
            deviceSecret = response.deviceSecret
            try pushSettings.setDeviceSecret(deviceSecret)
        }

        pushSettings.deviceId = deviceId

        for account in accounts where Self.isPushWatchCandidate(account) {
            await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
        }

        pushSettings.isEnabled = true
        isPushEnabled = true
    }

    /// Deletes every watch this device has registered (best-effort — a
    /// relay that's unreachable at the moment shouldn't leave the user
    /// stuck unable to turn push back off locally) and clears all local
    /// push state.
    ///
    /// Task #174 (実機バグ2 followup): "disable" is meant to fully undo
    /// this device's relay footprint, so it fetches this device's actual
    /// watch list from the relay (`GET /v1/watches`, ground truth —
    /// already device-scoped server-side) rather than trusting only the
    /// local `accountWatchMap`, which can drift (a previous register/
    /// reregister call may have created a watch on the relay but never
    /// got as far as persisting its id locally). See
    /// `WatchReconciler.watchIdsToDeleteForDisable`'s doc comment.
    func disablePushNotifications() async {
        if let baseURL = RelayURLConfig.value,
           let deviceSecret = try? pushSettings.deviceSecret() {
            let serverWatches = (try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)) ?? []
            let watchIdsToDelete = WatchReconciler.watchIdsToDeleteForDisable(
                serverWatches: serverWatches,
                localWatchMap: pushSettings.accountWatchMap
            )
            for watchId in watchIdsToDelete {
                try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
            }
        }
        pushSettings.reset()
        isPushEnabled = false
    }

    /// Whether this *build* has a relay registration secret baked in (see
    /// `RelayRegistrationSecretConfig`) — lets
    /// `PushNotificationSettingsView` tell apart "this relay requires a
    /// secret and this build doesn't have one configured" from "this
    /// build has one configured but the relay rejected it anyway" when it
    /// catches `PushError.registrationSecretRejected`.
    var isRelayRegistrationSecretConfigured: Bool {
        RelayRegistrationSecretConfig.isConfigured
    }

    /// Registers a watch for `account` if push is enabled and it doesn't
    /// already have one — called both from `enablePushNotifications` (for
    /// every existing account) and should be called again whenever a new
    /// push-watch-eligible account (`isPushWatchCandidate(_:)`) is added
    /// while push is already enabled.
    func registerWatchIfNeeded(for account: AccountRecord) async {
        guard isPushEnabled, Self.isPushWatchCandidate(account) else { return }
        guard pushSettings.accountWatchMap[account.id] == nil else { return }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret)
    }

    /// Task #175: every account whose credential the relay could
    /// meaningfully watch on this device's behalf — `.password` (an IMAP
    /// password) or `.oauth2` Gmail/Microsoft (an OAuth refresh token,
    /// `WatchAuth(type: .oauth, ...)`). A generic `.oauth2` account with
    /// neither `kind` (shouldn't exist in practice — every `.oauth2`
    /// account this app creates is `.gmail` or `.microsoft`) is excluded,
    /// same as before Task #175.
    nonisolated static func isPushWatchCandidate(_ account: AccountRecord) -> Bool {
        switch account.authType {
        case .password:
            return true
        case .oauth2:
            return account.kind == .gmail || account.kind == .microsoft
        }
    }

    @discardableResult
    private func registerWatch(for account: AccountRecord, baseURL: URL, deviceSecret: String) async -> Bool {
        guard let auth = await watchAuth(for: account) else { return false }
        let request = CreateWatchRequest(
            accountId: account.id,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapUseTLS: account.imapSecurity != .plain,
            imapUsername: account.imapUsername,
            auth: auth,
            mailbox: "INBOX"
        )
        guard let response = try? await pushRelayClient.createWatch(baseURL: baseURL, deviceSecret: deviceSecret, request: request) else {
            return false
        }
        pushSettings.setWatchId(response.watchId, forAccountId: account.id)
        return true
    }

    /// Task #175: the `WatchAuth` the relay needs for `account`'s watch —
    /// an IMAP password for `.password`, or an OAuth refresh token
    /// (`type: .oauth`) for a Gmail/Microsoft `.oauth2` account. `nil` if
    /// `account` isn't push-watch-eligible at all
    /// (`isPushWatchCandidate(_:)`), or if the credential it needs isn't
    /// actually available locally (Keychain password missing, or no
    /// refresh token stored/no token store configured for this build —
    /// e.g. `GOOGLE_OAUTH_CLIENT_ID` unset).
    ///
    /// **Sends the refresh token itself to the relay** — see
    /// `docs/relay-deployment.md`'s threat model on what that changes
    /// versus an IMAP password (both are credentials the relay operator
    /// could misuse, but a live refresh token keeps working until revoked,
    /// unlike a changed password).
    private func watchAuth(for account: AccountRecord) async -> WatchAuth? {
        switch account.authType {
        case .password:
            guard let password = try? credentialStore.password(forAccountId: account.id) else { return nil }
            return WatchAuth(secret: password)
        case .oauth2:
            switch account.kind {
            case .gmail:
                guard let tokenStore, let refreshToken = await tokenStore.rawRefreshToken(for: account.id) else { return nil }
                return WatchAuth(type: .oauth, secret: refreshToken, provider: .google)
            case .microsoft:
                guard let microsoftTokenStore,
                      let refreshToken = await microsoftTokenStore.rawRefreshToken(for: account.id)
                else { return nil }
                return WatchAuth(type: .oauth, secret: refreshToken, provider: .microsoft)
            case .generic, .icloud:
                return nil
            }
        }
    }

    private func unregisterWatch(forAccountId accountId: String) async {
        guard let watchId = pushSettings.accountWatchMap[accountId] else { return }
        defer { pushSettings.setWatchId(nil, forAccountId: accountId) }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
    }

    /// Task #173: fetches this device's current watch list straight from
    /// the relay (`GET /v1/watches`) so `PushNotificationSettingsView` can
    /// show *which* `.password` account's watch is stopped — the
    /// motivating 実機 report was a relay-side log line ("3 watches, 1
    /// auth-failed") with no way to tell which account from the app.
    /// `nil` on any failure (relay unreachable, push not enabled, etc.) —
    /// the view treats that as "status unavailable" rather than an error
    /// dialog, matching this file's existing "best-effort, no user-facing
    /// failure" posture for everything else push-related.
    func fetchPushWatchSummaries() async -> [WatchSummary]? {
        // `scripts/verify-screen.sh`'s `push-settings-watches` scenario —
        // see `OTEGAMI_UITEST_FORCE_PUSH_ENABLED`'s doc comment in
        // `init()` for why this exists: screenshotting every status
        // `PushWatchDisplayRow` can render needs fixed data, not a live
        // relay round trip this dev machine can't make safely/
        // deterministically here.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_FIXED_PUSH_WATCH_SUMMARIES"] == "1" {
            return Self.uitestFixedPushWatchSummaries
        }
        guard isPushEnabled,
              let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return nil }
        return try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)
    }

    /// Paired with `OTEGAMI_UITEST_INSERT_FAKE_PUSH_WATCH_ACCOUNTS`'s
    /// fixture accounts in `init()` — one active, one stopped, and (by
    /// omission) one account with no watch at all, covering
    /// `.registered`/`.stopped`/`.notRegistered` between them.
    private static var uitestFixedPushWatchSummaries: [WatchSummary] {
        let now = Date()
        return [
            WatchSummary(
                watchId: "uitest-watch-registered",
                accountId: "uitest-fake-registered",
                imapHost: "imap.example.test",
                mailbox: "INBOX",
                createdAt: now.addingTimeInterval(-3600),
                status: .active,
                lastConnectedAt: now.addingTimeInterval(-180)
            ),
            WatchSummary(
                watchId: "uitest-watch-stopped",
                accountId: "uitest-fake-stopped",
                imapHost: "imap.example.test",
                mailbox: "INBOX",
                createdAt: now.addingTimeInterval(-3600),
                status: .stopped,
                lastErrorKind: .authFailure,
                lastErrorAt: now.addingTimeInterval(-180)
            ),
        ]
    }

    /// Task #173: "re-register" a single stopped watch — deletes whatever
    /// watch the relay currently has for this account (if any; best-effort,
    /// same as `unregisterWatch`) and creates a fresh one, resending the
    /// account's current IMAP credential. This is the one operation the
    /// motivating 実機 report actually needed: a relay-side "watch stopped
    /// after repeated auth failures" only recovers once the account's
    /// password is fixed *and* something re-creates the watch — the relay
    /// itself never retries a `.stopped` watch on its own.
    ///
    /// Throws rather than silently no-op'ing (unlike most of this file's
    /// push plumbing) because this is a direct user action from a "有効化
    /// されていません"/"認証情報が見つかりません" button tap —
    /// `PushNotificationSettingsView` surfaces the failure instead of
    /// leaving the row looking like nothing happened.
    ///
    /// Task #174 (実機バグ2: 再登録後もリレー側に古い watch が孤児として
    /// 残る): a 実機 test of the Task #173 re-register button reconnected
    /// successfully, but the relay ended up with 3 watches for 2 apps-known
    /// accounts — the old, now-stopped watch never got deleted. The bug
    /// was that this method only ever deleted `pushSettings
    /// .accountWatchMap[account.id]` — the *local* record — which can lose
    /// track of a watch the relay still has (see
    /// `WatchReconciler.watchIdsToDelete(forReregisteringAccountId:...)`'s
    /// doc comment for why). Fixed by asking the relay itself
    /// (`GET /v1/watches`) which watch(es) it has for this account before
    /// deleting, falling back to the local map too so a failed/unreachable
    /// list call still cleans up at least as much as before this fix.
    func reregisterWatch(for account: AccountRecord) async throws {
        guard isPushEnabled else { throw PushError.relayNotConfigured }
        guard Self.isPushWatchCandidate(account) else { throw PushError.relayNotConfigured }
        guard let baseURL = RelayURLConfig.value else { throw PushError.relayNotConfigured }
        guard let deviceSecret = try? pushSettings.deviceSecret() else { throw PushError.relayNotConfigured }
        // Task #175: `.credentialUnavailable` now also covers a Gmail/
        // Microsoft account with no refresh token available locally (no
        // token store configured for this build, or nothing stored) —
        // `watchAuth(for:)` is the single source of truth for whether a
        // usable credential exists, so this just previews its result
        // rather than duplicating the per-authType logic here.
        guard await watchAuth(for: account) != nil else {
            throw ReregisterWatchError.credentialUnavailable
        }

        let serverWatches = (try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret)) ?? []
        let watchIdsToDelete = WatchReconciler.watchIdsToDelete(
            forReregisteringAccountId: account.id,
            serverWatches: serverWatches,
            localWatchId: pushSettings.accountWatchMap[account.id]
        )
        for watchId in watchIdsToDelete {
            // Best-effort, same as `unregisterWatch` — a delete failure
            // here means (at worst) one more orphan for a future
            // `reconcilePushWatchesIfNeeded()` pass to clean up, not a
            // reason to block the user from getting a working watch back.
            try? await pushRelayClient.deleteWatch(baseURL: baseURL, deviceSecret: deviceSecret, watchId: watchId)
        }
        pushSettings.setWatchId(nil, forAccountId: account.id)

        guard await registerWatch(for: account, baseURL: baseURL, deviceSecret: deviceSecret) else {
            throw ReregisterWatchError.relayRejectedWatch
        }
    }

    enum ReregisterWatchError: Error, Equatable {
        /// `KeychainCredentialStore` has no password for this account —
        /// shouldn't happen for a `.password`-auth account in normal use,
        /// but a Keychain item can vanish (e.g. an iCloud Keychain sync
        /// glitch, or the item was deleted outside the app).
        case credentialUnavailable
        /// The relay reachable-but-rejected the new watch (bad
        /// credentials, network error reaching the *IMAP* server isn't
        /// checked synchronously here — `POST /v1/watches` itself failed
        /// or the relay's SSRF/validation checks rejected the request).
        case relayRejectedWatch
    }

    /// Task #210 backoff after a *failed* `GET /v1/watches` attempt — see
    /// `reconcilePushWatchesIfNeeded()`'s doc comment. Deliberately much
    /// shorter than the old daily `watchReconcileInterval` this replaces:
    /// this only protects against hammering a relay that's *currently*
    /// unreachable across rapid foreground/background cycles, not against
    /// running the (cheap) fetch itself when everything is healthy.
    private static let watchReconcileFailureBackoffInterval: TimeInterval = 60 * 5

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
    ///   - a local push-watch-eligible account (`isPushWatchCandidate(_:)`)
    ///     with no live relay watch gets a fresh one registered (the
    ///     initial `createWatch` failed, or the local map fell out of sync
    ///     some other way).
    ///   - the local accountId→watchId map is repaired to match the
    ///     relay wherever it disagrees — no network call needed for that
    ///     part, just local bookkeeping.
    ///
    /// **Task #210** (実機バグ3: Task #208 のリレー・スキーマ入れ替えで
    /// リレー側の watch テーブルが空になった後、両デバイスとも通知が
    /// 最大24時間止まったまま): this used to throttle the `GET /v1/watches`
    /// fetch itself to roughly once a day (`PushSettingsStore
    /// .lastWatchReconcileDate`), reasoning that once healed this shouldn't
    /// need to run often. That reasoning missed the case where the *relay*
    /// silently loses its watches independent of anything the client did —
    /// the local `accountWatchMap` cache stayed populated (a server-side
    /// migration doesn't touch it), so there was no local signal that
    /// anything was wrong, and the daily gate meant nobody asked the relay
    /// again for up to 24h. See `docs/architecture.md`'s Task #210 note for
    /// the full incident and why a narrower "only bypass the throttle when
    /// the local map looks empty" fix wouldn't have caught this specific
    /// case either (the map wasn't empty, just stale).
    ///
    /// Fixed by no longer gating the fetch on staleness at all — `GET
    /// /v1/watches` now runs on every foreground unconditionally, same
    /// cadence as `syncAllAccountsOnce()` (which does far more real work
    /// per foreground already). `WatchReconciler.plan` is a pure in-memory
    /// diff, so an empty result (the common, healthy case) costs nothing
    /// beyond that one request. What still needs throttling is retrying a
    /// fetch that just *failed* — `WatchReconciler.shouldAttemptReconcile`
    /// backs that off via `PushSettingsStore.lastWatchReconcileFailureDate`
    /// so a relay outage doesn't get hit on every single foreground for as
    /// long as it lasts.
    func reconcilePushWatchesIfNeeded() async {
        guard isPushEnabled else { return }
        guard WatchReconciler.shouldAttemptReconcile(
            now: Date(),
            lastFailureDate: pushSettings.lastWatchReconcileFailureDate,
            failureBackoffInterval: Self.watchReconcileFailureBackoffInterval
        ) else { return }
        guard let baseURL = RelayURLConfig.value,
              let deviceSecret = try? pushSettings.deviceSecret()
        else { return }
        guard let serverWatches = try? await pushRelayClient.listWatches(baseURL: baseURL, deviceSecret: deviceSecret) else {
            // Records the failure so the next few foregrounds back off
            // rather than re-hitting an unreachable relay immediately —
            // same "best-effort, no user-visible failure" posture as the
            // rest of this file's push plumbing, just no longer silent
            // about *when* to retry.
            pushSettings.lastWatchReconcileFailureDate = Date()
            return
        }
        pushSettings.lastWatchReconcileFailureDate = nil
        // Diagnostic only now (Task #210) — see `lastWatchReconcileDateKey`'s
        // doc comment; nothing branches on this anymore.
        pushSettings.lastWatchReconcileDate = Date()

        // Task #175: despite the parameter's name (unchanged, to keep this
        // diff scoped to `AppEnvironment` — `WatchReconciler` itself has no
        // opinion on *why* an account is watch-eligible), this now also
        // includes `.oauth2` Gmail/Microsoft accounts —
        // `isPushWatchCandidate(_:)` is the single source of truth for
        // "should this account have a relay watch at all".
        let localPasswordAccountIds = Set(accounts.filter(Self.isPushWatchCandidate).map(\.id))
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

    /// Task #192 (実機クラッシュ解析: `EXC_CRASH`/`SIGKILL`,
    /// `RUNNINGBOARD`/`0xDEAD10CC` — the shared App Group database's
    /// `DatabasePool` held a lock while this app was suspended in the
    /// background; see `AppDatabase.makeConfiguration
    /// (observesSuspensionNotifications:)`'s doc comment for the full
    /// analysis and `docs/architecture.md`'s matching Known pitfalls
    /// entry). Posts GRDB's
    /// `Database.suspendNotification`, which — because `makeShared`
    /// enables `observesSuspensionNotifications` exactly when the database
    /// actually lives in the App Group container — makes every
    /// `DatabasePool` sharing that file (this process's, and whichever
    /// `NotificationService` Extension instance happens to be alive right
    /// now) refuse to acquire any *new* SQLite lock from this point on,
    /// failing such an access with `SQLITE_INTERRUPT`/`SQLITE_ABORT`
    /// instead — see `DatabaseSuspensionSupport.isSuspensionError(_:)`'s
    /// doc comment for how `SyncEngine` treats that.
    ///
    /// Called from `RootView.handleScenePhaseChange`'s `.background`/
    /// `.inactive` case, `#if os(iOS)`-gated there — macOS has no shared
    /// App Group container to race a background suspend over in the first
    /// place (`OtegamiAppGroup.identifier` always returns `nil` there), so
    /// this method exists on both platforms (for `AppEnvironment`'s own
    /// simplicity) but is only ever actually *called* on iOS.
    /// `databaseSuspensionTracker` dedups so an ordinary `.active →
    /// .inactive → .background` sequence — both legs of which map to
    /// "suspend" in that same `handleScenePhaseChange` switch — doesn't
    /// post this notification twice for one real suspend.
    func suspendSharedDatabaseIfNeeded() async {
        guard await databaseSuspensionTracker.markSuspended() else { return }
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// The `.active`-side counterpart to `suspendSharedDatabaseIfNeeded()`
    /// — posts `Database.resumeNotification`, letting every `DatabasePool`
    /// sharing the App Group database acquire new locks again. Called
    /// first thing in `RootView.handleScenePhaseChange`'s `.active` case
    /// (`#if os(iOS)`-gated there, same reasoning as
    /// `suspendSharedDatabaseIfNeeded()`), before any of that case's own
    /// database access (`startIdleLoops`/`syncAllAccountsOnce`/...) —
    /// otherwise a foreground return immediately after a real suspend would
    /// have those calls racing GRDB's still-active suspension and failing
    /// with `SQLITE_INTERRUPT`/`SQLITE_ABORT` for no reason.
    func resumeSharedDatabaseIfNeeded() async {
        guard await databaseSuspensionTracker.markResumed() else { return }
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
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
    /// port) exempted for local dev against a relay run with `go run`
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
