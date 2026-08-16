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
    /// Phase 3 (IMAP 接続の再利用): `syncCoordinator` の `sessionFactory`
    /// (IDLE 以外の全同期パス — `syncAccountIncrementally`/
    /// `replayOpQueue`/本文・添付・cid画像取得/スレッド要約) が経由する
    /// TTL 付き接続プール。バックグラウンド遷移時に `drainAll()` を呼んで
    /// 保持中の接続を実切断するため、`syncCoordinator` と並んでここに
    /// 保持しておく (`OtegamiApp.handleScenePhaseChange` の
    /// `.background`/`.inactive` ケースから呼ばれる `drainIMAPSessionPool()`
    /// 参照)。
    let imapSessionPool: PooledIMAPSessionFactory
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
    /// プッシュ通知起点バックグラウンド受信 Phase 1 — see
    /// `PushDatabaseChangeObserver`'s doc comment. Same default-initialized-
    /// then-wired-last two-phase pattern as `gmailAccessTokenBridge` right
    /// above.
    @ObservationIgnored private let pushDatabaseChangeObserver = PushDatabaseChangeObserver()
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

    func setPushEnabledState(_ isEnabled: Bool) {
        isPushEnabled = isEnabled
    }

    func markDatabaseSuspended() async -> Bool {
        await databaseSuspensionTracker.markSuspended()
    }

    func markDatabaseResumed() async -> Bool {
        await databaseSuspensionTracker.markResumed()
    }

    /// M11: iCloud account-definition sync. `accountCloudSync` reconciles
    /// the local `account` table against the `"accounts.v1"` iCloud KVS key
    /// (`docs/icloud-sync.md`); `cloudSyncSettings` is the "iCloud でアカウン
    /// トを同期" toggle's persistence (`AccountsSettingsView`),
    /// `isCloudSyncEnabled` its `@Observable` mirror for the UI, matching
    /// the `pushSettings`/`isPushEnabled` split above.
    @ObservationIgnored let cloudSyncSettings: CloudSyncSettingsStore
    @ObservationIgnored let accountCloudSync: AccountCloudSyncEngine
    private(set) var isCloudSyncEnabled: Bool

    func setCloudSyncEnabledState(_ isEnabled: Bool) {
        isCloudSyncEnabled = isEnabled
    }

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

    func storeAccountsObservationTask(_ task: Task<Void, Never>) {
        accountsObservationTask = task
    }

    func setObservedAccounts(_ accounts: [AccountRecord]) {
        self.accounts = accounts
    }

    func cancelBadgeObservationTask() {
        badgeObservationTask?.cancel()
    }

    func markBadgeAuthorizationRequestedIfNeeded() -> Bool {
        guard !hasRequestedBadgeAuthorization else { return false }
        hasRequestedBadgeAuthorization = true
        return true
    }

    func storeBadgeObservationTask(_ task: Task<Void, Never>) {
        badgeObservationTask = task
    }

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

    /// Invalidates already-visible `SenderAvatar` tasks after authentication
    /// or diagnostics rebuild changes the Google photo index.
    private(set) var avatarImageRevision = 0

    func invalidateAvatarImages() {
        avatarImageRevision &+= 1
    }

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

    /// 2026-08-05 (実機フィードバック「要約ボタンがグレーアウトして押せない
    /// ことがある」): `isSummarizationAvailable` の値は
    /// `MessageView.syncAIFeaturesState()` が SwiftUI state へ**その場限りの
    /// スナップショット**としてコピーする。ところが `SystemLanguageModel`
    /// (`FoundationModelsTranslationService.availability` の裏側) は
    /// `Observable` に準拠していない (SDK の swiftinterface で確認済み:
    /// `final public class SystemLanguageModel : Swift.Sendable` のみ) ため、
    /// 起動直後などモデル資産の読み込み中 (`.unavailable(.modelNotReady)`)
    /// にスナップショットされると、その後モデルが ready になっても SwiftUI
    /// 側に変化を知らせる手段が無く、メッセージを切り替える・アプリを
    /// バックグラウンドから復帰させるといった無関係な再評価が起きるまで
    /// ボタンが灰色のまま固まってしまう。
    ///
    /// 本リポジトリの既定方針 (Task #128/#138: 「隠して誤診断させるより、
    /// 押せるようにしてその場で失敗を見せる」) に沿い、`modelNotReady` は
    /// 一時的な状態とみなしてユーザー起点の試行を許可する —
    /// `TranslationAvailability.allowsUserInitiatedAttempt` のdoc comment
    /// 参照。もし本当にまだ準備中であれば、要約シート側の
    /// `requireAvailable()` がタップ直後に失敗し、エラー + 再生成ボタンと
    /// して自然に見える。それ以外の unavailable 理由 (端末非対応/Apple
    /// Intelligence 無効/言語未対応) はユーザーがアプリを離れない限り解消
    /// しない状態なので、引き続き無効のまま扱う。
    var isSummarizationActionable: Bool {
        summarizationService.availability.allowsUserInitiatedAttempt
    }

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
        // Communication Notification 対応: `CompositeAvatarImageResolver`
        // が解決した画像を`MirroringAvatarImageResolver`で包み、App Group
        // 共有ディレクトリ (`SharedAvatarStore`)へもミラーする —
        // `SharedAvatarCacheWriter.swift`のドキュメントコメント参照。
        // `SharedAvatarStore(appGroupIdentifier:)`は App Group が使えない
        // 環境 (macOS 常時)で`nil`を返し、その場合このデコレータは`base`
        // への単純な委譲になる。
        let sharedAvatarStore = SharedAvatarStore(appGroupIdentifier: OtegamiAppGroup.identifier)
        self.avatarImageResolver = MirroringAvatarImageResolver(
            wrapping: CompositeAvatarImageResolver(sources: [
                ContactPhotoResolver(),
                googleProfilePhotoAvatarResolver,
                GravatarAvatarResolver(),
                CompanyLogoAvatarResolver()
            ]),
            store: sharedAvatarStore
        )
        // 起動のたびに一度、期限切れ/超過分のエントリをベストエフォートで
        // 掃除する (`SharedAvatarStore.prune()`のドキュメントコメント
        // 参照)。ディレクトリ列挙+削除という同期 I/O を起動をブロックする
        // 場所で行いたくないので`Task.detached`へ逃がす — `.utility`は
        // ユーザー操作に応答する他のタスクより優先度を落とす、という
        // 「後回しでよいベストエフォート処理」の意図を表す。
        if let sharedAvatarStore {
            Task.detached(priority: .utility) {
                sharedAvatarStore.prune()
            }
        }

        let database: AppDatabase
        do {
            // `OTEGAMI_UITEST_DB_DIRECTORY`: this file's other
            // `OTEGAMI_UITEST_*` escape hatches と同じ検証専用フック。
            // macOS の画面検証 (`docs/verify.md`) はシミュレータと違い
            // 実ユーザーの Application Support を共有するため、これを
            // 指定しない検証起動はフィクスチャを実データベースへ注入して
            // しまう — `AppDatabase.makeShared(explicitDirectory:)` の
            // doc comment 参照。
            let uitestDatabaseDirectory = ProcessInfo.processInfo
                .environment["OTEGAMI_UITEST_DB_DIRECTORY"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            database = try AppDatabase.makeShared(
                appGroupIdentifier: OtegamiAppGroup.identifier,
                explicitDirectory: uitestDatabaseDirectory
            )
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
            //
            // 実クラッシュ調査 (TestFlight v1.14.1, iPad, `0xDEAD10CC`)
            // 「穴1」: 以前は `credentialStore.password(forAccountId:)` を
            // 下の `dbWriter.write` クロージャの**内側**から呼んでいた —
            // Keychain デーモンとの実 IPC 往復ぶん、共有 App Group DB の
            // SQLite 書き込みロックを保持したまま待つことになる。この
            // 起動が実際の OS サスペンドと競合すれば `0xDEAD10CC`
            // (`docs/architecture.md`のKnown pitfalls e.)そのもの。
            // `AccountDuplicateMerger.mergeDuplicateAccounts`の
            // `hasCredential`パラメータ自身のdoc commentも元々「write
            // トランザクションの外で取ったスナップショットに対する同期
            // クロージャであるべき (トランザクション中の live 再照会では
            // ない)」と明記していた — 以下は書き込みトランザクションを
            // 開く前に候補アカウント全員分の Keychain 照会を済ませ、
            // write 内は辞書引きだけにする。
            let credentialStore = self.credentialStore
            let candidateAccounts = (try? database.dbWriter.read { db in try AccountRecord.fetchAll(db) }) ?? []
            let passwordAccountHasCredential = Dictionary(uniqueKeysWithValues: candidateAccounts
                .filter { $0.authType == .password }
                .map { ($0.id, ((try? credentialStore.password(forAccountId: $0.id)) ?? nil) != nil) })
            duplicateMerges = (try? database.dbWriter.write { db in
                try AccountDuplicateMerger.mergeDuplicateAccounts(db: db) { account in
                    guard account.authType == .password else { return !account.needsReauth }
                    return passwordAccountHasCredential[account.id] ?? false
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
        // 実機の同期による継続的な DB 書き込みを再現する検証専用フック —
        // `UITestSeeder.startDatabaseChurnIfRequested` の doc comment 参照。
        UITestSeeder.startDatabaseChurnIfRequested(db: database.dbWriter)

        // Phase 3: `sessionFactory` goes through `imapSessionPool` (every
        // short-lived sync/fetch pass reuses a recently-returned
        // connection when possible) while `idleSessionFactory` stays the
        // raw, unpooled `MailCoreIMAPSession` factory — the foreground
        // `IDLE` loop holds its own long-lived connection and must never
        // be checked into/out of the pool's TTL bookkeeping (see
        // `AccountSyncer.idleSessionFactory`'s doc comment).
        let imapSessionPool = PooledIMAPSessionFactory(sessionFactory: { config in MailCoreIMAPSession(config: config) })
        self.imapSessionPool = imapSessionPool
        self.syncCoordinator = SyncCoordinator(
            database: database,
            sessionFactory: imapSessionPool.makeSessionFactory(),
            idleSessionFactory: { config in MailCoreIMAPSession(config: config) },
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
        // プッシュ通知起点バックグラウンド受信 Phase 1: same reasoning, same
        // timing — see `PushDatabaseChangeObserver`'s doc comment. Starts
        // this app's Darwin notification observer (iOS only) right away, so
        // it's live for the entire session, not just while foregrounded.
        pushDatabaseChangeObserver.configure(environment: self)
        // 実クラッシュ調査 (0xDEAD10CC) 「穴2」: same timing, same reasoning
        // — see `SharedAppDatabaseCenter`'s doc comment. Lets
        // `PushNotificationActionHandler.handle(...)` reuse this already-
        // open `database` instead of opening a second `DatabasePool` onto
        // the same shared file whenever a notification action arrives while
        // this process is already alive. iOS-only (that handler only exists
        // on iOS at all — `PushNotificationActionHandler.swift`'s `#if
        // os(iOS)` gating).
        #if os(iOS)
        SharedAppDatabaseCenter.shared.configure(environment: self)
        #endif

        startObservingAccounts()

        // M7: defensive self-heal, in addition to the v7 migration's own
        // one-time backfill (`AppDatabase`) — cheap once caught up (a
        // single `NOT EXISTS` scan that finds nothing), so running it again
        // on every launch costs effectively nothing but guards against any
        // future code path that ever inserts a `message` row without going
        // through `AccountSyncer.upsert`/`BodyFetcher.fetchBody`.
        //
        // Task #221: alongside it, self-heal any `message.bodyState ==
        // .fetching` row a process kill mid-fetch left stuck — see
        // `BodyCacheStateReconciler.resetStuckFetchingStates`'s doc comment
        // for why nothing else in this codebase ever revisits one on its
        // own. Same launch-time, best-effort (`try?`) shape as the FTS
        // backfill right next to it.
        Task { [database] in
            try? await database.dbWriter.write { db in
                try FTSIndexer.backfillIfNeeded(db: db)
                try BodyCacheStateReconciler.resetStuckFetchingStates(db: db)
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




}
