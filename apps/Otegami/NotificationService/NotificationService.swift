import CoreFoundation
import Foundation
import GRDB
import GoogleOAuth
import Intents
import MailTransport
import MailTransportMailCore
import MicrosoftOAuth
import OtegamiCore
import OtegamiRelayAPI
import OtegamiStore
import PushRelayClient
import Security
import SyncEngine
import UserNotifications
import os

/// Serializes the race between enrichment completion, Otegami's short
/// display deadline, and iOS's final extension-expiry callback. Once one
/// path claims delivery, later content/stage mutations are rejected so a
/// slow IMAP task can never mutate content already handed to the OS.
final class NotificationDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false

    @discardableResult
    func withPending(_ mutation: () -> Void) -> Bool {
        lock.withLock {
            guard !delivered else { return false }
            mutation()
            return true
        }
    }

    func claimDelivery() -> Bool {
        lock.withLock {
            guard !delivered else { return false }
            delivered = true
            return true
        }
    }
}

/// Handles otegami-relay's `mutable-content` push (M9, plan §7's privacy
/// design: the payload only ever carries `accountId`/`uidNext`, never
/// subject/sender/body — see `OtegamiRelayAPI.PushNotificationPayload`).
/// This Extension re-fetches just the newest message's envelope over IMAP
/// itself and rewrites the notification's title/body before it's shown.
///
/// Flow:
/// 1. Decode `accountId`/`uidNext` from `userInfo`.
/// 2. Read this device's `NotificationContentPreferences` (Task #176: the
///    3 `PushNotificationSettingsView` toggles) from the shared App Group
///    `UserDefaults` suite — see `notificationContentPreferences()`'s doc
///    comment. If every one is off, stop right here: no account lookup, no
///    Keychain read, no IMAP connection at all (Task #176's own "無駄な
///    通信を避ける" ask) — the notification is left exactly as `didReceive`
///    already set it (`NotificationEnrichment.genericTitle`/`genericBody`).
/// 3. Otherwise, open the shared `AppDatabase` (App Group container,
///    read-only in practice — see `AppDatabase.makeShared(appGroupIdentifier:)`'s
///    doc comment) and look up that account's `AccountRecord`.
/// 4. Resolve credentials for `account.authType`:
///    - `.password`: read the IMAP password from the shared Keychain
///      Access Group, same as always.
///    - `.oauth2` (Task #177 — Gmail/Outlook accounts, following up on
///      Task #175's relay-side OAuth watch support): read the stored OAuth
///      refresh token from the shared Keychain (`GoogleOAuth.TokenStore`/
///      `MicrosoftOAuth.TokenStore`, the exact same types
///      `AppEnvironment.auth(for:)` already uses for a foregrounded sync —
///      see `oauthAccessToken(for:)`) and exchange it for a fresh access
///      token, racing that exchange against `oauthTokenFetchTimeout`
///      (`PushOAuthAccessTokenResolution`) so a slow/hanging token
///      endpoint can't consume this Extension's entire ~30 second OS
///      budget and leave no time for the IMAP half below. Any failure at
///      any point (build has no Client ID configured, no refresh token
///      stored, the refresh itself failing, or the timeout firing) is
///      collapsed into "no credential" and falls straight through to step
///      6's generic fallback — same degraded-but-not-broken behavior as a
///      `.password` account with no Keychain entry.
/// 5. Connect, `SELECT` the watched mailbox, `FETCH` the envelope for UID
///    `uidNext - 1` (the just-arrived message) — and, only if
///    `showsBodyPreview` is on, that same message's body too (a
///    `FETCH`-the-whole-message operation, meaningfully heavier than the
///    envelope-only fetch, so it's skipped whenever the user has that
///    toggle off, same "don't fetch what nothing will use" reasoning as
///    step 2) — and fill in the notification's title/body according to
///    `NotificationEnrichment`.
/// 6. Any failure at any step (account not found, no password, IMAP
///    connect/auth/fetch failure) falls back to a generic "新着メールが
///    あります" body — the notification still shows, just without the
///    enrichment — rather than dropping the notification. A body-fetch
///    failure specifically (step 5's second fetch) only drops the body
///    preview line, not the whole enrichment — the envelope-derived
///    title/subject (if any) still applies.
///
/// **On "件数のみ" for the all-off case**: Task #176's own request text
/// floated "新着メールがあります/複数件なら件数のみ" as an example of what
/// an all-toggles-off notification could look like. This deliberately
/// always uses the plain generic text instead, never a "N件" count: the
/// push payload here carries only one `accountId`/`uidNext` pair (no
/// message count), and the only two ways to get one — an extra IMAP round
/// trip just to count, or reading the locally-synced unread count out of
/// the shared `AppDatabase` — are both wrong for this specific case. The
/// former defeats the entire point of skipping the fetch. The latter would
/// be *stale*: this Extension never inserts the new message into the local
/// database itself (see the badge-increment doc comment on `Task` below),
/// so a DB-read count reflects only messages already synced *before* this
/// push arrived — not the new arrival(s) that triggered it — which would
/// be actively misleading rather than merely imprecise.
///
/// A five-second internal display deadline delivers whatever is already on
/// hand (generic content, or sender/subject if the envelope completed) so
/// slow OAuth/IMAP/body work never holds the notification until iOS's ~30
/// second hard limit. `serviceExtensionTimeWillExpire()` remains the final
/// OS-driven safety net.
///
/// **Diagnostic logging (Task #211)**: 実機で「通知は届くが差出人・件名が
/// 出ない」報告があり (Gmail/iCloud は問題なし、Yahoo! JAPAN だけ)、この
/// ファイルは以前どの段階で失敗しているか一切ログを残していなかった —
/// `enrich(payload:)` のあらゆる失敗が同じ「無言で汎用文言のまま」に
/// 見えてしまい、原因を切り分けられなかった。今は各段階
/// (preferences/account lookup/credential/IMAP connect/select/envelope
/// fetch/body fetch) の成否を `logger` (`os.Logger`, `.notice`以上) へ
/// 記録する。`NotificationServiceDiagnostics.summarize(category:
/// underlyingDescription:)` (`PushRelayClient`, ユニットテスト済み) が
/// 実際のカテゴリ分類/レート制限検知/PII 除去を行い、ここは
/// `MailTransportError` の `switch` とログ呼び出しだけを担う。**本文・
/// 件名・差出人・資格情報は一切ログに出さない** — `authenticationFailed`
/// の `underlyingDescription` (サーバーがログイン名をエコーし返す実装が
/// あり得る) も意図的に落とす。実機での見方・既知の疑い (Yahoo の同時
/// 接続/レート制限) は `docs/architecture.md` の落とし穴 i. の追記
/// (Task #211) を参照。
///
/// **端末内診断画面 (Task #213)**: Task #211 のログは Mac に有線接続して
/// Console.app/`log stream` を操作しないと読めず、実機での即時切り分けが
/// できなかった。`recordStage(_:outcome:since:)` は上記と全く同じ各段階の
/// 成否を、OSLog への書き込みに加えて `stageRecords` (インメモリ配列) にも
/// 積む — `deliver()` が最後に**1回だけ** `PushDiagnosticsHistory
/// .appending(_:toSuite:)` で共有 App Group の `UserDefaults` へ書き出し、
/// アプリ側の「プッシュ通知の診断」画面
/// (`apps/Otegami/Sources/Features/Settings/PushDiagnosticsView.swift`) が
/// そこから読む。共有領域として `UserDefaults` を選んだ理由 (共有DBへの
/// 書き込みは選ばなかった理由) は `PushDiagnosticsRun`
/// (`packages/OtegamiKit/Sources/PushRelayClient/PushDiagnosticsStore.swift`)
/// のdoc commentを参照。
///
/// **`kSecAttrSynchronizable` 抜けのバグ修正 (Task #216)**: 実機の診断画面
/// (Task #213) が、あるアカウントで「Resolving Credential 0ms 失敗:
/// noCredential」— IMAP 接続にすら到達していない — を記録した。当初は
/// Yahoo! 固有の事象と見えたが、その後**同じ端末で iCloud アカウントも
/// 同じ症状**であることが判明し、一方 Gmail (OAuth) は正常だった。整理
/// すると **`.password` 認証のアカウントは全滅、`.oauth2` 認証のアカウント
/// だけ正常** — プロバイダの違いではなく認証方式の違いだった。Task #211/
/// #215 が追った「Yahoo のレート制限/同時接続数」はこの件には無関係
/// (ネットワークに一切触れる前の 0ms 失敗であることに加え、iCloud にまで
/// 同じ症状が出ている時点でサーバー固有の問題ではあり得ない)。
///
/// 真因は `password(forAccountId:)` の Keychain クエリが
/// `kSecAttrSynchronizable` を指定していなかったこと — 指定を省くと
/// `SecItemCopyMatching` は **非同期化 (non-synchronizable) の項目しか
/// 返さない** (Apple のドキュメント上の既定動作)。一方アプリ本体の
/// `KeychainCredentialStore` は M11 (iCloud Keychain 同期) 以降、
/// `setPassword` で書くすべての項目を `kSecAttrSynchronizable = true` に
/// する——**新規アカウント作成時の最初の1回の保存から**すでにそうなる
/// (`addSynchronizable`)。つまり M11 以降にセットアップされた `.password`
/// 認証のアカウントは、プロバイダを問わず最初から全滅していたことになる
/// (「以前は届いていた」という体感があるとすれば、それは pre-M11 の
/// ビルドで作成されて以来一度も再保存されていない、たまたま非同期化の
/// ままの項目が残っていたケース)。**この仮説を直接裏付ける対照実験が
/// コードベース内にすでにある**: OAuth のリフレッシュトークンを保存する
/// `GoogleOAuth.KeychainRefreshTokenStore`/`MicrosoftOAuth
/// .KeychainRefreshTokenStore` (`packages/OtegamiKit/Sources/GoogleOAuth
/// (Microsoft)/RefreshTokenStoring.swift`) は、アプリ本体とこの Extension
/// の**両方から全く同じ型を経由して**読み書きされる (`oauthAccessToken(
/// for:)`が呼ぶ`GoogleOAuth.TokenStore`/`MicrosoftOAuth.TokenStore`のデフォルト
/// 実装がこれ) — そしてその`read(accountId:)`は最初から一貫して
/// `anySynchronizableQuery`(`kSecAttrSynchronizableAny`)を使っている。
/// これが Gmail/Outlook の通知だけ正常だった理由そのもの: OAuth 側は
/// この Extension 専用の手書きクエリではなく、最初から同期状態を問わず
/// マッチする既存の共有実装を使っていたから壊れようがなかった。
///
/// 詳細・検討過程は `docs/architecture.md` の Known pitfalls (j.) を参照。
/// **読み取り側だけの修正で直る** — Keychain に保存されている値自体は
/// 最初から正しいので、ユーザーがパスワードを入れ直す必要は無い。
/// `password(forAccountId:)`は併せて `KeychainCredentialStore
/// .legacyServices` 相当のフォールバックも追加した (このExtensionには
/// 元々無かった)。`resolveAuth(for:)`/`oauthAccessToken(for:)`はこの
/// 調査を機に、診断画面の`credential`段階が常に`noCredential`一色だった
/// 問題も合わせて直した — 戻り値を`CredentialResolution`/
/// `OAuthTokenOutcome`という列挙型にして、「項目が無い/Keychain読み取り
/// エラー/Client ID未設定/トークン取得不可/想定外のkind」を診断画面の
/// カテゴリとして区別できるようにしている (資格情報そのものは相変わらず
/// 一切記録しない)。
///
/// **プッシュ通知起点バックグラウンド受信 Phase 1**: それまで`enrich(
/// payload:)`は読み取り専用 (`fetchEnvelopes`/`fetchBody`、共有DBへは一切
/// 書かない) で、通知の文言を組み立てるためだけに新着メールを再取得して
/// いた — 取得した内容はこの Extension プロセスの生存期間限りで捨てられ、
/// アプリが次に同期するまで共有DBには反映されない。Phase 1 はこの主経路を
/// `SyncEngine.PushTriggeredInboxSync.run(...)` (`account/credential`解決
/// はこのファイルの既存ロジックを流用しつつ、INBOX限定の差分同期を1回
/// 実行して結果を共有DBへ永続化する) に置き換えた —
/// `55e5405`でNSEがこのDBのwriterになれるよう共有DBにbusyMode timeoutが
/// 追加済みなのが前提。通知の文言トグルが全部OFFでもこの同期自体は実行
/// する (このExtensionの主目的が「共有DBへの永続化」に変わったため —
/// 文言の組み立てだけがトグルでスキップされる)。同期が対象メッセージを
/// 解決できなかった場合 (`PushTriggeredInboxSync.Outcome.message == nil`
/// — アカウント未知/INBOX未解決/DB busy/ネットワーク失敗等、その型自身の
/// doc comment通りどれも同じ一つの信号に潰れる) のみ、以前からある
/// 読み取り専用の`legacyEnrich(account:auth:payload:preferences:)`
/// (旧`enrich(payload:)`本体そのもの) にフォールバックする — 文言の
/// 後退がゼロになるようにする設計。バッジは同期が真の未読数
/// (`Outcome.unreadCount`) を返せた場合だけそれで上書きし
/// (`applyTrueBadgeCount(_:)`)、返せなければ`incrementSharedBadgeCount()`
/// の従来の "+1" 見積りのままにする。同期が実際にDBへ書いた場合のみ
/// Darwin notification (`DatabaseChangeDarwinNotification.name`) を post
/// し、フォアグラウンドのアプリ側 (`AppEnvironment`) がそれを合図に
/// `Database.notifyChanges(in: .fullDatabase)`を1回実行して自分の
/// `ValueObservation`を再発火させる — 詳細は
/// `DatabaseChangeDarwinNotification`のdoc comment参照。
///
/// **プッシュ通知起点バックグラウンド受信 Phase 3 (NSE のリレー先読み統合)**:
/// Phase 1 の sync-first 経路は正確だが、IMAP 接続を1回挟む分だけ5秒の
/// 表示予算をよく使い切ってしまう — 遅いネットワーク/サーバーでは
/// `deadlineTask`が先に発火し、汎用文言のまま配信されることも珍しくな
/// かった。Phase 2 (リレー側) が push payload に新着メッセージの
/// 差出人/件名 (`OtegamiRelayAPI.PushNotificationPayload.latestFromName`/
/// `latestFromAddress`/`latestSubject`/`latestUid`) を同梱するように
/// なったのを受け、Phase 3 は`enrich(payload:)`の先頭近くでそれを
/// **ネットワークに一切触れずに**即座に適用する
/// (`envelopeContentDecision(payload:preferences:bodyPreview:)`) —
/// これだけで5秒予算内の表示がほぼ保証される。本文プレビュー設定
/// (`showsBodyPreview`) が on の場合はさらに、リレーの
/// `GET /v1/messages` (`PushRelayClient.fetchMessagePreviews(...)`,
/// `fetchRelayBodyPreview(accountId:latestUid:)`) から本文プレビューを
/// 取得して同じ経路で再適用する — これもIMAP接続を経由しない軽量な
/// HTTPリクエスト1回で完結する。どちらも取得元は"リレーが直近に見た
/// 新着メッセージの内容"であり、Phase 1 の sync-first 経路
/// (`PushTriggeredInboxSync.run(...)`、唯一のIMAP接続・唯一のDB書き込み
/// 経路) はこれまでどおり無変更で実行され、そちらが完了すれば
/// (`syncFirstDecision(outcome:preferences:)`)その内容で上書きする
/// (`deliveryGate`がすでに配信済みなら黙って捨てる、既存の仕組みのまま)。
///
/// 同期が成功した後、取得できていたリレー由来の本文プレビューは
/// 対象メッセージ行の`snippet`列へ**`snippet`がまだ`nil`のときだけ**
/// 書き戻す (`writeBackRelaySnippetIfNeeded(messageId:bodyPreview:)` →
/// `PushTriggeredInboxSync.writeSnippetIfMissing(messageId:bodyPreview:
/// database:)`)。**`bodyState`は絶対に変更しない** — 本文プレビューは
/// 本文全体でも添付でもない切り詰め文字列でしかなく、`.fetched`扱いに
/// すると`BodyFetcher`/`SyncCoordinator`のオンオープン遅延取得が「もう
/// 取得済み」と誤認して本文全体の取得を永久にスキップしてしまう。
///
/// payload に envelope フィールドが1つも無い場合 (旧リレー、または
/// `RELAY_CONTENT_PREVIEW` が off のリレー) は、この Phase 3 の経路は
/// 何もせず (`envelopeContentDecision`が`nil`を返す)、Phase 1 の
/// sync-first + `legacyEnrich`フォールバックのみが動く従来どおりの挙動
/// になる — 既存の"通知文言が後退しない"保証をそのまま維持する。
///
/// リレーURL/端末のデバイスシークレットはこの Extension 独自の
/// `pushRelayBaseURL`/`pushRelayDeviceSecret()`で読む — アプリ本体の
/// `RelayURLConfig`/`PushSettingsStore`はこのExtensionからは
/// importできない別ターゲットのため、`Bundle.main`/`Keychain`から
/// それぞれ小さな複製として読み直している (このファイルの
/// `appGroupIdentifier`/`keychainAccessGroup`/`OAuthConfig`がすでに
/// 同じ理由で行っている複製と同じパターン)。取得試行/成否は診断
/// Stage `.relayPreview` (`PushDiagnosticsRun.Stage`) に記録する。
// `@unchecked Sendable`: `UNNotificationServiceExtension` doesn't itself
// promise `didReceive(_:withContentHandler:)`/`serviceExtensionTimeWillExpire()`
// run on any particular actor, so the compiler can't otherwise prove the
// `Task { ... }` in `didReceive` capturing `self` is race-free — but the OS
// only ever has one `didReceive` in flight per extension process instance,
// and `contentHandler`/`bestAttemptContent` are only ever touched from
// that single in-flight call's continuation, so there's no actual
// concurrent access to reason about.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var deliveryGate = NotificationDeliveryGate()
    private var enrichmentTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    /// Rich notification content is best-effort. Waiting for the OS's
    /// roughly 30-second hard limit makes the notification itself feel
    /// broken when OAuth/IMAP/body fetching is slow. Release the generic or
    /// partially-enriched notification after five seconds instead.
    ///
    /// Phase 1: this budget only bounds how long the notification's own
    /// *display* waits — `enrichmentTask`'s underlying sync-first work
    /// (`PushTriggeredInboxSync.run(...)`, a durable database write) is no
    /// longer cancelled when this budget expires, and keeps running
    /// best-effort for whatever's left of the OS's own much longer ~30
    /// second budget. See the deadline `Task`'s closure in `didReceive`.
    private static let enrichmentDisplayBudget: Duration = .seconds(5)

    /// Set once at the top of `didReceive`, read back by `deliver()` (from
    /// either the normal completion path or `serviceExtensionTimeWillExpire()`)
    /// to log how much of the ~30 second OS budget this run actually used —
    /// see this type's "Diagnostic logging" doc comment. `nil` only if
    /// `deliver()` is somehow reached before `didReceive` ever ran (doesn't
    /// happen in practice; guards the log line, not correctness).
    private var startedAt: Date?

    /// Task #211 — see this type's "Diagnostic logging" doc comment for
    /// what gets written here and why. `com.mtkg.otegami` matches every
    /// other `Logger(subsystem:category:)` call site in the app target
    /// (e.g. `AppDatabase.swift`).
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "NotificationService")

    /// Task #213 — this run's stage results so far, appended to by
    /// `recordStage(_:outcome:since:)` as `didReceive`/`enrich(payload:)`
    /// progress, and persisted (JSON-encoded, one shared App Group
    /// `UserDefaults` write) exactly once by `deliver()`. See this type's
    /// "端末内診断画面" doc comment. Same single-in-flight-instance
    /// reasoning as `bestAttemptContent`/`startedAt` above justifies
    /// touching this directly from both `didReceive`'s synchronous prelude
    /// and the `Task` it spawns.
    private var stageRecords: [PushDiagnosticsRun.StageRecord] = []

    /// Communication Notifications (Task: 送信者アバター付きプッシュ通知):
    /// guards `attemptCommunicationNotificationIfNeeded(...)` so a run only
    /// ever tries once — that function's own doc comment explains exactly
    /// when it's allowed to stay `false` (to retry once more information is
    /// available) versus when it must flip to `true` (a terminal answer was
    /// reached).
    private var communicationNotificationAttempted = false

    /// The already-*donated* intent `attemptCommunicationNotificationIfNeeded(...)`
    /// prepared, if any — read back synchronously by `deliver()`'s
    /// `applyCommunicationNotificationIfAvailable()`. `nil` whenever this
    /// run never reached a `.decorate` decision, the donation itself
    /// failed, or `deliver()` ran (5 second display budget /
    /// `serviceExtensionTimeWillExpire()`) before `enrich(payload:)` got
    /// this far — every one of those cases just delivers the notification
    /// undecorated, never a broken one (this type's own doc comment on the
    /// Phase 1 deadline `Task` already establishes the same "best-effort,
    /// never blocks delivery" pattern for `enrichmentTask` generally).
    private var communicationNotificationIntent: INSendMessageIntent?

    /// The conversation identifier that intent was donated under —
    /// `applyCommunicationNotificationIfAvailable()` also uses this for the
    /// content's `threadIdentifier` so the OS groups repeated notifications
    /// from the same correspondent together. Kept alongside
    /// `communicationNotificationIntent` rather than re-derived from it:
    /// `INSendMessageIntent.conversationIdentifier` is itself optional at
    /// the type level (Objective-C `nullable`), and re-force-unwrapping it
    /// at the use site would be redundant given this value is already on
    /// hand from `CommunicationNotificationSender` at donation time.
    private var communicationNotificationConversationIdentifier: String?

    /// Appends one stage result to `stageRecords` — no I/O here, just an
    /// array append (`deliver()` is the only place that ever touches
    /// `UserDefaults`, see this type's "端末内診断画面" doc comment on why
    /// that split matters for the ~30 second budget). `since` is the
    /// `Date()` captured right before the stage's work started; this
    /// computes `elapsedMs` the same way `deliver()`'s own logging already
    /// does for the whole run.
    private func recordStage(_ stage: PushDiagnosticsRun.Stage, outcome: PushDiagnosticsRun.Outcome, since start: Date) {
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        deliveryGate.withPending {
            stageRecords.append(.init(stage: stage, outcome: outcome, elapsedMs: elapsedMs))
        }
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        enrichmentTask?.cancel()
        deadlineTask?.cancel()
        deliveryGate = NotificationDeliveryGate()
        stageRecords = []
        startedAt = Date()
        communicationNotificationAttempted = false
        communicationNotificationIntent = nil
        communicationNotificationConversationIdentifier = nil
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.title = "Otegami"
        content.body = "新着メールがあります"
        bestAttemptContent = content

        // Parsed synchronously, before spawning the Task below, so the
        // escaping closure only ever captures a plain `Sendable` struct —
        // not `request` (a `UNNotificationRequest`, not provably safe to
        // access concurrently) itself. `enrich(payload:)` below reads/
        // writes `self.bestAttemptContent` rather than taking `content` as
        // a parameter too, for the same reason: capturing the very same
        // `UNMutableNotificationContent` instance both directly and via
        // `self` is what the compiler can't prove race-free, not `self`
        // alone (this class is `@unchecked Sendable`).
        let parsePayloadStart = Date()
        let payload = Self.parsePayload(request.content.userInfo)
        if let payload {
            Self.logger.notice("didReceive: accountId=\(payload.accountId, privacy: .public) uidNext=\(payload.uidNext, privacy: .public)")
            recordStage(.parsePayload, outcome: .success, since: parsePayloadStart)
        } else {
            Self.logger.notice("didReceive: push carried no accountId/uidNext — nothing to enrich, leaving generic content")
            recordStage(.parsePayload, outcome: .skipped(reason: "no accountId/uidNext in push payload"), since: parsePayloadStart)
        }

        let enrichmentTask = Task { [weak self] in
            guard let self else { return }
            if let payload {
                // H「アプリアイコンの未読バッジ」— best-effort increment from
                // whatever count `AppEnvironment.restartBadgeObservationIfNeeded`
                // last wrote to the shared App Group `UserDefaults` suite.
                // Setting `content.badge` here (rather than calling
                // `UNUserNotificationCenter.setBadgeCount` from this
                // Extension process) is the actual supported mechanism for
                // an Extension to affect the badge — the OS applies it the
                // moment this notification is delivered. Deliberately just
                // "+1", not the true unread count: this call happens
                // synchronously, before `enrich(payload:)` below has had any
                // chance to run its (network-bound, potentially slow)
                // sync-first pass — so a real count isn't available yet at
                // this exact point. `enrich(payload:)`'s own
                // `applyTrueBadgeCount(_:)` overwrites this with the real
                // post-sync unread count (Phase 1: `PushTriggeredInboxSync
                // .Outcome.unreadCount`) once that pass completes, if it
                // resolved one; otherwise this "+1" estimate is what ships.
                // Independently, the next time the main app runs its own
                // live `ValueObservation` (any foreground/sync/read-toggle —
                // `AppEnvironment.restartBadgeObservationIfNeeded`'s doc
                // comment) it self-corrects to the real number regardless.
                incrementSharedBadgeCount()
                await enrich(payload: payload)
            }
            deliver()
        }
        self.enrichmentTask = enrichmentTask

        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.enrichmentDisplayBudget)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            Self.logger.notice("enrichment display budget expired — delivering best-effort content without waiting for remaining network work")
            // Phase 1 (push 通知起点バックグラウンド受信): deliberately does
            // *not* cancel `enrichmentTask` here anymore — its sync-first
            // work (`PushTriggeredInboxSync.run(...)`, this type's own doc
            // comment) is a durable write to the shared database, not just
            // display text, so it's worth letting it keep running
            // best-effort for whatever's left of the ~30 second OS budget
            // even after this budget-driven `deliver()` has already shown
            // the notification. `enrichmentTask`'s own trailing `deliver()`
            // call (at the end of the `Task` in `didReceive`) becomes a
            // harmless no-op once this one has already claimed delivery
            // (`NotificationDeliveryGate.claimDelivery()`'s guard) — every
            // further `bestAttemptContent`/`stageRecords` mutation it
            // attempts is silently dropped the same way, via
            // `deliveryGate.withPending`. Only `serviceExtensionTimeWillExpire()`
            // (the OS's own final callback, moments before this whole
            // process is actually killed) still marks the practical end —
            // there's no more budget left for anything to keep running
            // through at that point regardless of whether this Task itself
            // is ever explicitly cancelled.
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called by the OS shortly before the ~30 second budget for this
        // extension process runs out — deliver whatever's on hand (the
        // generic fallback body set in didReceive, if enrich(payload:)
        // hasn't finished) rather than let the notification disappear.
        // Logged unconditionally (Task #211): the immediately-following
        // `deliver()` log's `elapsedMs` tells a real device's next
        // reproduction whether this run actually timed out (elapsedMs near
        // 30000, this line present) versus finished normally well under
        // budget (this line absent).
        Self.logger.notice("serviceExtensionTimeWillExpire: OS budget about to run out — delivering best-effort content")
        deliver()
    }

    private func deliver() {
        guard let contentHandler, let original = bestAttemptContent, deliveryGate.claimDelivery() else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        // Phase 1: `enrichmentTask` is deliberately left running here (not
        // cancelled, not cleared) — see the deadline `Task`'s closure in
        // `didReceive` for why. `didReceive`'s own top (`enrichmentTask?
        // .cancel()`) still cancels whatever's left of it if another push
        // arrives at this same process instance before it finishes on its
        // own.
        self.contentHandler = nil
        // Communication Notifications: applied here, after `claimDelivery()`
        // has already succeeded — this is now the single remaining owner of
        // `bestAttemptContent`, so no `deliveryGate.withPending` guard is
        // needed for this mutation (unlike every earlier mutation of it in
        // this file, which race against `deliver()` itself claiming
        // delivery first).
        //
        // 装飾できなかった場合は `original` がそのまま配信される — この
        // 関数から `return` する経路を作らないこと。ここまで来た時点で
        // `claimDelivery()` は成立済みで、`contentHandler` を呼ばずに
        // 戻ると通知そのものが二度と表示されない (もう誰も配信できない)。
        let finalContent = decoratedContentIfAvailable(from: original) ?? original
        var totalElapsedMs: Int?
        if let startedAt {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            totalElapsedMs = elapsedMs
            Self.logger.notice("deliver: elapsedMs=\(elapsedMs, privacy: .public)")
        }
        let completedStages = stageRecords
        persistDiagnostics(stages: completedStages, totalElapsedMs: totalElapsedMs)
        contentHandler(finalContent)
    }

    /// Communication Notifications (Task: 送信者アバター付きプッシュ通知):
    /// applies the decoration `attemptCommunicationNotificationIfNeeded(...)`
    /// already prepared (an `INSendMessageIntent` that already successfully
    /// donated), if one is available by the time `deliver()` runs — a no-op
    /// when `enrich(payload:)` hasn't gotten that far yet (5 second display
    /// budget, or `serviceExtensionTimeWillExpire()` firing first): in that
    /// case `bestAttemptContent` is delivered exactly as the rest of this
    /// file already built it, no decoration, no error.
    ///
    /// **Why `userInfo`/`categoryIdentifier`/`badge`/`sound` are
    /// unconditionally re-applied after `updating(from:)`, not merely
    /// defensively.** Apple's documentation says `updating(from:)` returns
    /// "a copy of the notification content, updated with the information
    /// from the specified intent" — it makes no promise about which of the
    /// *original* content's own unrelated properties survive that copy.
    /// Without re-asserting them here, a decorated notification could
    /// silently lose the `userInfo` payload `PushTokenCenter.swift`'s
    /// tap-to-open routing depends on, and/or its `categoryIdentifier`
    /// (`PushNotificationActionCategory.swift`'s `NEW_MAIL_ACTIONS`, which
    /// is what makes the "既読にする"/"アーカイブ" actions show up at all) —
    /// a Communication Notification would then look right but behave
    /// subtly worse than an undecorated one.
    ///
    /// `threadIdentifier` is deliberately set to the *same* conversation
    /// identifier `senderDecision`/`donate` used — see
    /// `conversationIdentifier(accountId:senderAddress:)`'s doc comment for
    /// why it's per-sender, not per-thread — so the OS groups repeated
    /// notifications from one correspondent together in Notification
    /// Center.
    ///
    /// Returns `nil` for every "deliver it undecorated" case (no donated
    /// intent, or `updating(from:)` threw) — `deliver()` then falls back to
    /// the content it already had. Deliberately a *return value* rather than
    /// a mutation of `bestAttemptContent`: decoration is always best-effort,
    /// and shaping it this way makes it structurally impossible for a
    /// failure here to leave `deliver()` without a content to hand the
    /// `contentHandler` (which would silently drop the notification
    /// entirely, since `claimDelivery()` has already been claimed by then).
    /// Recorded directly into `stageRecords`
    /// (not via `recordStage(_:outcome:since:)`, whose `deliveryGate
    /// .withPending` guard would silently drop this — `deliver()` has
    /// already called `claimDelivery()` by the time this runs) so a
    /// donation success followed by an `updating(from:)` failure still
    /// shows up in the on-device diagnostics screen as this run's true
    /// outcome.
    private func decoratedContentIfAvailable(from original: UNMutableNotificationContent) -> UNMutableNotificationContent? {
        guard let intent = communicationNotificationIntent,
              let conversationIdentifier = communicationNotificationConversationIdentifier
        else { return nil }
        let start = Date()
        let userInfo = original.userInfo
        let categoryIdentifier = original.categoryIdentifier
        let badge = original.badge
        let sound = original.sound
        do {
            let updated = try original.updating(from: intent)
            guard let mutable = updated.mutableCopy() as? UNMutableNotificationContent else { return nil }
            mutable.userInfo = userInfo
            mutable.categoryIdentifier = categoryIdentifier
            mutable.badge = badge
            mutable.sound = sound
            mutable.threadIdentifier = conversationIdentifier
            Self.logger.notice("deliver: communicationNotification: decoration applied")
            return mutable
        } catch {
            Self.logger.notice("""
            deliver: communicationNotification: updating(from:) threw — delivering undecorated: \
            \(String(describing: error), privacy: .public)
            """)
            stageRecords.append(.init(
                stage: .communicationNotification,
                outcome: .failure(category: "updatingFailed", looksRateLimited: false, logDetail: String(describing: error)),
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
            ))
            return nil
        }
    }

    /// Task #213 — the single `UserDefaults` write this whole feature does
    /// per push (see this type's "端末内診断画面" doc comment): guarded by
    /// this `deliver()`'s own early-return-on-second-call above, so this
    /// runs exactly once per `didReceive`, whether reached from normal
    /// completion or `serviceExtensionTimeWillExpire()` (in which case
    /// `stageRecords` simply holds whatever stages `enrich(payload:)`
    /// managed to reach before the OS budget ran out — itself useful
    /// diagnostic information, not an error case to special-case away).
    /// A silent no-op with no App Group configured (matches
    /// `incrementSharedBadgeCount()`'s existing same-shaped guard) or with
    /// no stages recorded at all (shouldn't happen — `didReceive` always
    /// records `.parsePayload` synchronously before this can be reached —
    /// but guards against persisting an empty, useless run if it ever did).
    private func persistDiagnostics(stages: [PushDiagnosticsRun.StageRecord], totalElapsedMs: Int?) {
        guard !stages.isEmpty,
              let appGroupIdentifier = Self.appGroupIdentifier,
              let defaults = UserDefaults(suiteName: appGroupIdentifier)
        else { return }
        let run = PushDiagnosticsRun(stages: stages, totalElapsedMs: totalElapsedMs)
        PushDiagnosticsHistory.appending(run, toSuite: defaults)
    }

    /// H「アプリアイコンの未読バッジ」— see the `Task` block's doc comment in
    /// `didReceive(_:withContentHandler:)` for the overall "increment here,
    /// main app self-corrects to the true count later" design.
    private func incrementSharedBadgeCount() {
        guard let appGroupIdentifier = Self.appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        let newCount = defaults.integer(forKey: Self.sharedBadgeCountKey) + 1
        defaults.set(newCount, forKey: Self.sharedBadgeCountKey)
        deliveryGate.withPending {
            bestAttemptContent?.badge = NSNumber(value: newCount)
        }
    }

    /// Mirrored copy of `BadgeCenter.sharedCountKey`
    /// (`apps/Otegami/Sources/Support/BadgeCenter.swift`) — must match
    /// byte-for-byte because this Extension target doesn't share source
    /// files with the app target, per `OtegamiAppGroup.swift`'s doc comment.
    private static let sharedBadgeCountKey = "badge.sharedCount"

    private func enrich(payload: PushNotificationPayload) async {
        let preferencesStart = Date()
        let preferences = Self.notificationContentPreferences()
        // Phase 1: unlike before, reading preferences no longer gates the
        // account/credential lookup or the sync below — this Extension's
        // primary job now is persisting the new message into the shared
        // database (`PushTriggeredInboxSync.run(...)`), which has to happen
        // regardless of what this device's 3 notification-content toggles
        // say. Those toggles still gate *display text* — see
        // `legacyEnrich(account:auth:payload:preferences:)`'s own guard,
        // and `syncFirstDecision(outcome:preferences:)` below — just no
        // longer whether the IMAP/DB work happens at all.
        recordStage(.preferences, outcome: .success, since: preferencesStart)
        Self.logger.notice("""
        enrich: preferences showsSender=\(preferences.showsSender, privacy: .public) \
        showsSubject=\(preferences.showsSubject, privacy: .public) \
        showsBodyPreview=\(preferences.showsBodyPreview, privacy: .public)
        """)

        // Phase 3 (NSE のリレー先読み統合), step 1: if the relay already sent
        // this push's envelope (`payload.latestFromName`/`latestFromAddress`/
        // `latestSubject` — `RELAY_CONTENT_PREVIEW`, opt-in relay-side),
        // apply it to the notification *right now* — zero network calls,
        // before account lookup/credential/sync even start. This alone
        // guarantees sender+subject display within the 5 second budget even
        // if everything below stalls or fails; every following step in this
        // function only ever has a chance to *improve* on this (a body
        // preview, then the fully-synced content), never regress below it,
        // since a `return` on any failure path leaves whatever this applied
        // in place. No-op (returns `nil`) when the payload carries no
        // envelope at all — an older/`RELAY_CONTENT_PREVIEW`-off relay.
        if let envelopeDecision = Self.envelopeContentDecision(payload: payload, preferences: preferences) {
            let applied = deliveryGate.withPending {
                bestAttemptContent?.title = envelopeDecision.title
                bestAttemptContent?.body = envelopeDecision.body
            }
            Self.logger.notice("enrich: applied relay-prefetched envelope content immediately applied=\(applied, privacy: .public)")
        }

        // Communication Notifications (Task: 送信者アバター付きプッシュ通知):
        // attempted here first, immediately after the network-free relay
        // envelope — if `payload.latestFromAddress` is present this is
        // already this run's final sender (`senderDecision`'s own
        // address-priority doc comment), so there's no reason to wait for
        // the (slower, IMAP-based) sync/legacy paths below just to donate
        // the exact same address. When the payload names no sender at all,
        // this call's own guard leaves `communicationNotificationAttempted`
        // `false` so the sync-first/legacy call sites further down get a
        // chance to supply one instead.
        await attemptCommunicationNotificationIfNeeded(
            accountId: payload.accountId,
            payload: payload,
            syncSenderName: nil,
            syncSenderAddress: nil,
            preferences: preferences
        )

        let accountLookupStart = Date()
        let account: AccountRecord
        do {
            guard let found = try await Self.lookupAccount(id: payload.accountId) else {
                Self.logger.notice("enrich: account lookup: no row for this accountId — falling back to generic")
                recordStage(.accountLookup, outcome: .failure(category: "notFound", looksRateLimited: false, logDetail: nil), since: accountLookupStart)
                return
            }
            account = found
        } catch {
            Self.logger.error("enrich: account lookup: shared AppDatabase read threw — falling back to generic: \(String(describing: error), privacy: .public)")
            recordStage(.accountLookup, outcome: .failure(category: "dbReadError", looksRateLimited: false, logDetail: nil), since: accountLookupStart)
            return
        }
        Self.logger.notice("""
        enrich: account lookup: found kind=\(account.kind.rawValue, privacy: .public) \
        authType=\(account.authType.rawValue, privacy: .public) host=\(account.imapHost, privacy: .public)
        """)
        recordStage(.accountLookup, outcome: .success, since: accountLookupStart)

        let credentialStart = Date()
        let auth: MailAuth
        switch await Self.resolveAuth(for: account) {
        case .success(let resolved):
            auth = resolved
            Self.logger.notice("enrich: credential: resolved, connecting")
            recordStage(.credential, outcome: .success, since: credentialStart)
        case .failure(let category, let logDetail):
            Self.logger.notice("enrich: credential: no usable credential resolved category=\(category, privacy: .public) — falling back to generic")
            recordStage(.credential, outcome: .failure(category: category, looksRateLimited: false, logDetail: logDetail), since: credentialStart)
            return
        }

        // Phase 3, step 2: fetch a body preview from the relay
        // (`GET /v1/messages`) and, if one comes back, re-apply the
        // notification content with it — still zero IMAP round trips, so
        // this typically finishes well before the (heavier) incremental
        // sync below does. Only attempted when `showsBodyPreview` is on and
        // the payload actually named a target message (`latestUid`) — see
        // `shouldFetchRelayPreview(payload:preferences:)`. `relayBodyPreview`
        // (if non-nil) is also handed to the snippet write-back after the
        // sync below succeeds — see this function's tail.
        var relayBodyPreview: String?
        if Self.shouldFetchRelayPreview(payload: payload, preferences: preferences), let latestUid = payload.latestUid {
            let relayPreviewStart = Date()
            switch await Self.fetchRelayBodyPreview(accountId: account.id, latestUid: latestUid) {
            case .success(let bodyPreview):
                relayBodyPreview = bodyPreview
                if let bodyPreview {
                    Self.logger.notice("enrich: relayPreview: fetched a body preview")
                    recordStage(.relayPreview, outcome: .success, since: relayPreviewStart)
                    if let envelopeDecision = Self.envelopeContentDecision(payload: payload, preferences: preferences, bodyPreview: bodyPreview) {
                        let applied = deliveryGate.withPending {
                            bestAttemptContent?.title = envelopeDecision.title
                            bestAttemptContent?.body = envelopeDecision.body
                        }
                        Self.logger.notice("enrich: relayPreview: applied body preview to notification applied=\(applied, privacy: .public)")
                    }
                } else {
                    Self.logger.notice("enrich: relayPreview: relay had no preview matching this uid — leaving envelope-only content")
                    recordStage(.relayPreview, outcome: .skipped(reason: "no matching preview in relay response"), since: relayPreviewStart)
                }
            case .notConfigured:
                recordStage(.relayPreview, outcome: .skipped(reason: "no relay URL/device secret configured"), since: relayPreviewStart)
            case .notFound:
                Self.logger.notice("enrich: relayPreview: relay returned 404 (feature off relay-side, or no watch for this account)")
                recordStage(.relayPreview, outcome: .skipped(reason: "relay returned 404 (feature off, or no watch)"), since: relayPreviewStart)
            case .failure(let logDetail):
                Self.logger.notice("enrich: relayPreview: fetch failed — leaving whatever content is already applied in place")
                recordStage(.relayPreview, outcome: .failure(category: "fetchFailed", looksRateLimited: false, logDetail: logDetail), since: relayPreviewStart)
            }
        } else {
            recordStage(
                .relayPreview,
                outcome: .skipped(reason: payload.latestUid == nil ? "no envelope in payload" : "showsBodyPreview off"),
                since: Date()
            )
        }

        // Phase 1 sync-first path — see this type's own doc comment
        // ("プッシュ通知起点バックグラウンド受信 Phase 1") for the full design.
        let incrementalSyncStart = Date()
        let syncOutcome = await Self.runIncrementalSync(
            accountId: account.id, uidNext: payload.uidNext, fetchBodyPreview: preferences.showsBodyPreview, auth: auth
        )
        let decision = Self.syncFirstDecision(outcome: syncOutcome, preferences: preferences)

        guard !decision.needsLegacyFallback else {
            Self.logger.notice("enrich: incrementalSync: didn't resolve the pushed message — falling back to the legacy read-only IMAP fetch")
            recordStage(.incrementalSync, outcome: .failure(category: "noMessageResolved", looksRateLimited: false, logDetail: nil), since: incrementalSyncStart)
            await legacyEnrich(account: account, auth: auth, payload: payload, preferences: preferences)
            return
        }
        Self.logger.notice("enrich: incrementalSync: succeeded, message persisted to the shared database")
        recordStage(.incrementalSync, outcome: .success, since: incrementalSyncStart)

        // Communication Notifications: the fallback opportunity for a
        // payload that named no sender — `syncOutcome.message` is exactly
        // the same just-synced message `decision.title`/`.body` below were
        // built from, so its own resolved sender is the best information
        // this run's sync-first path can offer. A no-op (per
        // `communicationNotificationAttempted`'s guard) if the earlier,
        // payload-only attempt already reached a terminal answer.
        let syncSender = syncOutcome.message?.fromAddresses.first
        await attemptCommunicationNotificationIfNeeded(
            accountId: account.id,
            payload: payload,
            syncSenderName: syncSender?.name,
            syncSenderAddress: syncSender?.address,
            preferences: preferences
        )

        if let title = decision.title, let body = decision.body {
            let applied = deliveryGate.withPending {
                bestAttemptContent?.title = title
                bestAttemptContent?.body = body
            }
            if applied {
                Self.logger.notice("enrich: applied sync-first content to notification")
            } else {
                Self.logger.notice("enrich: incrementalSync completed after delivery; discarded late content update")
            }
        }
        if let badgeCount = decision.badgeCount {
            applyTrueBadgeCount(badgeCount)
        }
        // Only posted once the sync above actually persisted a row — a run
        // that fell back to `legacyEnrich` (read-only, this type's own doc
        // comment) never reaches this line, since it `return`s above first.
        postDatabaseChangedDarwinNotification()

        // Phase 3, step 4: write the relay-fetched body preview back into
        // the just-synced row's `snippet` — but *only* if step 2 actually
        // got one, and only as a fallback for whatever `syncOutcome`
        // already resolved. `writeSnippetIfMissing` itself is the one that
        // enforces "only if `snippet` is still nil" and "never touch
        // `bodyState`" — see its own doc comment in `PushTriggeredInboxSync`
        // for why the latter matters (marking a preview-only row `.fetched`
        // would permanently strand it with no real body). Best-effort, same
        // as everything else in this Extension: `syncOutcome.message` is
        // guaranteed non-nil here (`decision.needsLegacyFallback` already
        // `return`ed above when it wasn't), but a missing `id` or a busy/
        // suspended database just silently skips this.
        if let relayBodyPreview, let messageId = syncOutcome.message?.id {
            await Self.writeBackRelaySnippetIfNeeded(messageId: messageId, bodyPreview: relayBodyPreview)
        }
    }

    /// Task (Phase 1 バッジ整合): overwrites whatever `incrementSharedBadgeCount()`'s
    /// "+1" estimate already applied with the real post-sync unread count —
    /// `PushTriggeredInboxSync.Outcome.unreadCount`, computed by
    /// `OtegamiStore.MessageQuery.unreadCount` right after this push's
    /// incremental sync completed. Mirrors `incrementSharedBadgeCount()`'s
    /// own shared-`UserDefaults` write (`BadgeCenter.sharedCountKey`'s doc
    /// comment on why both processes keep that key in sync) so the main
    /// app's next `BadgeCenter.setBadge(count:)` self-correction starts
    /// from an already-accurate baseline instead of this Extension's stale
    /// "+1" — a difference that matters if several pushes land in a row
    /// before the app is ever foregrounded again. Uses `deliveryGate
    /// .withPending` the same way `incrementSharedBadgeCount()` does, so a
    /// late call (the sync finishing after the 5-second display budget
    /// already delivered the notification) only updates the shared
    /// baseline, not a `UNMutableNotificationContent` the OS has already
    /// been handed.
    private func applyTrueBadgeCount(_ count: Int) {
        guard let appGroupIdentifier = Self.appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(count, forKey: Self.sharedBadgeCountKey)
        deliveryGate.withPending {
            bestAttemptContent?.badge = NSNumber(value: count)
        }
    }

    /// Task (Phase 1 クロスプロセス反映): tells the app's own foreground
    /// process (if any is running) that this Extension just durably wrote a
    /// new message into the shared App Group database — see
    /// `DatabaseChangeDarwinNotification`'s doc comment for the full
    /// cross-process design and why a Darwin notification (not
    /// `NotificationCenter.default`) is what reaches it. Best-effort and
    /// fire-and-forget like everything else in this Extension: if no app
    /// process happens to be alive to observe it right now, this is simply
    /// a no-op — the app's own `scenePhase == .active` handler
    /// (`OtegamiApp.handleScenePhaseChange`) independently re-runs the same
    /// `notifyChanges(in:)` write once on every foreground return, which is
    /// what actually guarantees eventual consistency for a suspended app
    /// that missed this specific post.
    private func postDatabaseChangedDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(DatabaseChangeDarwinNotification.name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Task (Phase 1): runs `SyncEngine.PushTriggeredInboxSync.run(...)` for
    /// `accountId` — the actual "pull the new message into the shared
    /// database" work `enrich(payload:)`'s sync-first path is built on. A
    /// `static` function (not an instance method) with no dependency on
    /// `self`, matching `lookupAccount(id:)`/`resolveAuth(for:)` right below
    /// — `database` is a purely local variable here, so its `DatabasePool`
    /// closes (GRDB's own `deinit`) the moment this function returns, well
    /// before `deliver()` ever runs, same 0xDEAD10CC-avoidance reasoning
    /// `lookupAccount(id:)`'s own doc comment (Task #192) already spells
    /// out. `sessionFactory` mirrors `enrich`'s own historical direct
    /// `MailCoreIMAPSession(config:)` construction — this Extension is a
    /// short-lived, per-push process, so there's no connection pool to
    /// reuse across calls the way `AppEnvironment.imapSessionPool` is for
    /// the long-lived app process.
    private static func runIncrementalSync(
        accountId: String,
        uidNext: Int,
        fetchBodyPreview: Bool,
        auth: MailAuth
    ) async -> PushTriggeredInboxSync.Outcome {
        guard let database = try? AppDatabase.makeShared(appGroupIdentifier: appGroupIdentifier) else {
            return PushTriggeredInboxSync.Outcome(message: nil, unreadCount: nil)
        }
        return await PushTriggeredInboxSync.run(
            accountId: accountId,
            uidNext: uidNext,
            fetchBodyPreview: fetchBodyPreview,
            database: database,
            auth: auth,
            sessionFactory: { config in MailCoreIMAPSession(config: config) }
        )
    }

    /// Task (Phase 1) — the pure "what should `enrich(payload:)` do with a
    /// `PushTriggeredInboxSync.Outcome`" policy, factored out (mirroring
    /// `NotificationEnrichment`'s own "no `UNMutableNotificationContent`/
    /// GRDB/IMAP involvement" split) so it's exercisable by
    /// `NotificationServiceTests` without a real shared database or IMAP
    /// session — same "private → internal for tests" pattern
    /// `parsePayload(_:)` already established for this file.
    struct SyncFirstDecision: Equatable {
        /// The notification's title/body built from the just-synced
        /// message, or both `nil` when either the sync needs the legacy
        /// fallback (`needsLegacyFallback`) or every content-preference
        /// toggle is off (Task #176's "全部OFFなら文言を組み立てない" rule
        /// applies here exactly as it always has for the legacy path — the
        /// database write itself still happened, there's just nothing to
        /// show).
        let title: String?
        let body: String?
        /// The real post-sync unread count, when the sync could compute
        /// one — `nil` means "leave whatever `incrementSharedBadgeCount()`'s
        /// existing +1 estimate already applied alone".
        let badgeCount: Int?
        /// `true` when `outcome.message` is `nil` — the sync didn't resolve
        /// the pushed message at all (unknown account, no INBOX known yet,
        /// the sync itself failing for any reason — `PushTriggeredInboxSync
        /// .Outcome`'s own doc comment on why none of those are
        /// distinguishable from here), so `enrich(payload:)` falls back to
        /// `legacyEnrich(account:auth:payload:preferences:)` — the
        /// pre-Phase-1 read-only IMAP envelope/body fetch, unchanged —
        /// rather than showing the plain generic fallback text.
        let needsLegacyFallback: Bool
    }

    static func syncFirstDecision(
        outcome: PushTriggeredInboxSync.Outcome,
        preferences: NotificationContentPreferences
    ) -> SyncFirstDecision {
        guard let message = outcome.message else {
            return SyncFirstDecision(title: nil, body: nil, badgeCount: nil, needsLegacyFallback: true)
        }
        guard NotificationEnrichment.needsFetch(preferences: preferences) else {
            return SyncFirstDecision(title: nil, body: nil, badgeCount: outcome.unreadCount, needsLegacyFallback: false)
        }
        let sender = message.fromAddresses.first
        let title = NotificationEnrichment.title(preferences: preferences, senderName: sender?.name, senderAddress: sender?.address)
        let body = NotificationEnrichment.body(preferences: preferences, subject: message.subject, bodyPreviewSourceText: message.snippet)
        return SyncFirstDecision(title: title, body: body, badgeCount: outcome.unreadCount, needsLegacyFallback: false)
    }

    // MARK: - Phase 3 (NSE のリレー先読み統合)

    /// The title/body `enrich(payload:)`'s Phase 3 step 1 (and, once a body
    /// preview arrives, step 2) apply — built purely from `payload`'s own
    /// relay-prefetched envelope fields plus this device's content
    /// preferences, with no IMAP/GRDB/Keychain involvement, so it's
    /// exercisable by `NotificationServiceTests` the same way
    /// `SyncFirstDecision` is (this file's "private → internal for tests"
    /// convention, `parsePayload(_:)`'s doc comment).
    struct EnvelopeContentDecision: Equatable {
        let title: String
        let body: String
    }

    /// `nil` when `payload` carries no envelope at all (`latestFromName`/
    /// `latestFromAddress`/`latestSubject` all `nil` — an older app build's
    /// relay, or `RELAY_CONTENT_PREVIEW` off relay-side) — the caller
    /// applies nothing in that case, leaving whatever content is already on
    /// `bestAttemptContent` (the plain generic fallback, at step 1's call
    /// site) untouched. `bodyPreview` is `nil` for step 1 (nothing fetched
    /// yet) and the relay-fetched preview text for step 2's re-application;
    /// either way this defers entirely to `NotificationEnrichment.title(
    /// preferences:senderName:senderAddress:)`/`.body(preferences:subject:
    /// bodyPreviewSourceText:)` for what the preferences toggles do to the
    /// result — same policy the sync-first/legacy paths already use, so a
    /// user who turned a toggle off sees the exact same generic fallback
    /// here as everywhere else in this file.
    static func envelopeContentDecision(
        payload: PushNotificationPayload,
        preferences: NotificationContentPreferences,
        bodyPreview: String? = nil
    ) -> EnvelopeContentDecision? {
        guard payload.latestFromName != nil || payload.latestFromAddress != nil || payload.latestSubject != nil else {
            return nil
        }
        return EnvelopeContentDecision(
            title: NotificationEnrichment.title(
                preferences: preferences, senderName: payload.latestFromName, senderAddress: payload.latestFromAddress
            ),
            body: NotificationEnrichment.body(
                preferences: preferences, subject: payload.latestSubject, bodyPreviewSourceText: bodyPreview
            )
        )
    }

    /// Whether `enrich(payload:)` should even attempt the relay body-preview
    /// prefetch (`fetchRelayBodyPreview(accountId:latestUid:)`,
    /// `GET /v1/messages`) at all: both `showsBodyPreview` must be on (same
    /// "don't fetch what nothing will use" reasoning `legacyEnrich`'s own
    /// guard already applies to its IMAP body fetch) and `payload` must
    /// actually name a target message (`latestUid` — without it there's
    /// nothing to ask the relay for a preview *of*). Pure so it's directly
    /// testable without a real relay/Keychain.
    static func shouldFetchRelayPreview(payload: PushNotificationPayload, preferences: NotificationContentPreferences) -> Bool {
        preferences.showsBodyPreview && payload.latestUid != nil
    }

    /// What `fetchRelayBodyPreview(accountId:latestUid:)` resolved — one
    /// level more specific than a plain `String??` so `enrich(payload:)`
    /// can record a precise diagnostics `.relayPreview` stage outcome the
    /// same way `CredentialResolution`/`OAuthTokenOutcome` let `credential`
    /// do (those types' own doc comments explain why a flat `nil` isn't
    /// enough for this screen to be useful).
    private enum RelayPreviewFetchOutcome {
        /// The relay call itself succeeded; `bodyPreview` is the matching
        /// entry's preview text, or `nil` if the relay's response simply
        /// didn't include this exact `latestUid` (e.g. it already aged out
        /// of the relay's small per-watch cache).
        case success(bodyPreview: String?)
        /// No relay URL configured for this build, or no device secret in
        /// the Keychain (push not enabled/never completed registration on
        /// this device) — never even attempted the HTTP call.
        case notConfigured
        /// `GET /v1/messages` returned 404 — `PushRelayClient
        /// .fetchMessagePreviews(...)`'s own doc comment: this relay
        /// doesn't have `RELAY_CONTENT_PREVIEW` enabled, or this device has
        /// no watch for this accountId. Treated as a normal, unremarkable
        /// outcome (`.skipped`, not `.failure`, in the diagnostics stage),
        /// not a real error.
        case notFound
        /// Any other failure (network error, unexpected status, ...).
        case failure(logDetail: String?)
    }

    /// Phase 3 step 2's actual relay call: `GET /v1/messages` for
    /// `accountId`, `sinceUid: max(latestUid - 1, 0)` — matching the
    /// task's own "latestUid - 1 相当" framing, this asks for every
    /// preview with `uid > sinceUid`, i.e. `uid >= latestUid`, which always
    /// includes the exact message this push is about (if the relay still
    /// has it cached). Picks out that one entry by `uid == latestUid`
    /// specifically, rather than just taking the response's first (highest-
    /// uid) entry, so a body preview never gets attached to the wrong
    /// message if the relay's response ever contains more than one.
    private static func fetchRelayBodyPreview(accountId: String, latestUid: Int64) async -> RelayPreviewFetchOutcome {
        guard let baseURL = pushRelayBaseURL else { return .notConfigured }
        guard let deviceSecret = pushRelayDeviceSecret() else { return .notConfigured }
        let client = PushRelayClient()
        do {
            let previews = try await client.fetchMessagePreviews(
                baseURL: baseURL, deviceSecret: deviceSecret, accountId: accountId, sinceUid: Int(max(latestUid - 1, 0))
            )
            return .success(bodyPreview: previews.first(where: { $0.uid == latestUid })?.bodyPreview)
        } catch let PushRelayClient.PushRelayClientError.http(status, _) where status == 404 {
            return .notFound
        } catch {
            return .failure(logDetail: String(describing: error))
        }
    }

    /// Phase 3 step 4: best-effort write-back of the relay-fetched body
    /// preview into the just-synced message's `snippet` column — thin glue
    /// around `PushTriggeredInboxSync.writeSnippetIfMissing(messageId:
    /// bodyPreview:database:)`, which is where the actual "only if `nil`"/
    /// "never touch `bodyState`" policy lives (see that function's own doc
    /// comment). A fresh `AppDatabase.makeShared` call, same reasoning
    /// `lookupAccount(id:)`/`runIncrementalSync(...)` already give for why a
    /// short-lived local `database` handle here is safe (Task #192): it
    /// closes when this function returns, well before the OS could ever
    /// suspend this Extension process. Silently does nothing if the shared
    /// database can't be opened at all.
    private static func writeBackRelaySnippetIfNeeded(messageId: Int64, bodyPreview: String) async {
        guard let database = try? AppDatabase.makeShared(appGroupIdentifier: appGroupIdentifier) else { return }
        await PushTriggeredInboxSync.writeSnippetIfMissing(messageId: messageId, bodyPreview: bodyPreview, database: database)
    }

    /// Own small copy of the app target's `RelayURLConfig` (`apps/Otegami
    /// /Sources/Support/RelayURLConfig.swift`) — same "`Bundle.main` inside
    /// an Extension is its own bundle, not the containing app's" reasoning
    /// `appGroupIdentifier`/`keychainAccessGroup`/`OAuthConfig` below already
    /// document, and the same reason this can't just import that type (it
    /// lives in the `Otegami` app target, which this Extension target can't
    /// depend on). `project.yml`'s `NotificationService` target declares
    /// `OTEGAMI_PUSH_RELAY_URL` in its own `info.properties` to make this
    /// possible, mirroring `GOOGLE_OAUTH_CLIENT_ID`/`OTEGAMI_MICROSOFT_CLIENT_ID`'s
    /// existing precedent there. Validation (`https://` required;
    /// `http://localhost`/`http://127.0.0.1` exempted for local dev) is a
    /// small duplicate of `AppEnvironment.validatedRelayURL(_:)` for the
    /// same "can't depend on the app target" reason — kept in sync with it
    /// by hand since there's no shared home either type could move to
    /// without pulling `SyncEngine`/`OtegamiStore`-shaped app dependencies
    /// into this Extension.
    private static var pushRelayBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_PUSH_RELAY_URL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(")
        else { return nil }
        guard let components = URLComponents(string: raw), let url = components.url else { return nil }
        if components.scheme == "https" { return url }
        if components.scheme == "http", let host = components.host, host == "localhost" || host == "127.0.0.1" {
            return url
        }
        return nil
    }

    /// Mirrors `PushSettingsStore`'s (`apps/Otegami/Sources/Support/Settings
    /// /PushSettingsStore.swift`) Keychain service/account strings for this
    /// device's relay-issued bearer secret — that type can't be imported
    /// here either (same app-target-only reasoning as `pushRelayBaseURL`),
    /// so this is a small read-only counterpart, following the exact same
    /// "hand-rolled `SecItemCopyMatching` query, current service then
    /// legacy fallback" shape `password(forAccountId:)` above already
    /// establishes for IMAP passwords. Unlike that query, this one does
    /// *not* widen with `kSecAttrSynchronizableAny` — `PushSettingsStore
    /// .setDeviceSecret(_:)`'s own doc comment: this secret is deliberately
    /// *never* written as `kSecAttrSynchronizable` (it's paired 1:1 with
    /// this device's own APNs token, which never syncs either), so the
    /// default "non-synchronizable items only" query behavior is already
    /// correct here — there is no synchronizable copy to fail to find.
    private static func pushRelayDeviceSecret() -> String? {
        let services = [Self.pushRelayDeviceSecretKeychainService] + Self.pushRelayDeviceSecretLegacyKeychainServices
        for service in services {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Self.pushRelayDeviceSecretKeychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let keychainAccessGroup { query[kSecAttrAccessGroup as String] = keychainAccessGroup }
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) {
                return secret
            }
        }
        return nil
    }

    private static let pushRelayDeviceSecretKeychainService = "com.mtkg.otegami.push-device-secret"
    private static let pushRelayDeviceSecretLegacyKeychainServices = ["com.m-tkg.otegami.push-device-secret"]
    private static let pushRelayDeviceSecretKeychainAccount = "device"

    /// The pre-Phase-1 `enrich(payload:)` itself, unchanged apart from
    /// taking its already-resolved `account`/`auth` as parameters instead
    /// of resolving them again — `enrich(payload:)` now only reaches this
    /// when `PushTriggeredInboxSync.run(...)` didn't resolve the pushed
    /// message (`SyncFirstDecision.needsLegacyFallback`), so this remains
    /// the read-only IMAP re-fetch this type's own doc comment (steps 4-6)
    /// describes: connect, `SELECT INBOX`, `FETCH` the envelope for the
    /// inferred UID, and (only if `showsBodyPreview`) that message's body
    /// too — filling in the notification's title/body directly from IMAP
    /// rather than the shared database. Guarantees zero text regression
    /// from before Phase 1: any account/preference/IMAP condition that used
    /// to produce enriched content still does, now just after one extra
    /// (best-effort) sync attempt first.
    private func legacyEnrich(
        account: AccountRecord,
        auth: MailAuth,
        payload: PushNotificationPayload,
        preferences: NotificationContentPreferences
    ) async {
        // Task #176: every toggle off -> nothing below would ever be used,
        // so skip the IMAP connection entirely — see this type's doc
        // comment, step 2. (Unlike before Phase 1, this guard no longer
        // also skips the account/credential lookup — `enrich(payload:)`
        // already did those unconditionally, since the sync-first path
        // needs them regardless of these toggles.)
        guard NotificationEnrichment.needsFetch(preferences: preferences) else {
            Self.logger.notice("legacyEnrich: all 3 content toggles are off — nothing to enrich, skipping the IMAP fallback fetch")
            return
        }

        let session = MailCoreIMAPSession(config: account.imapConfig)
        let mailbox = "INBOX"

        let connectStart = Date()
        do {
            try await session.connect(auth: auth)
            Self.logger.notice("legacyEnrich: connect: succeeded")
            recordStage(.connect, outcome: .success, since: connectStart)
        } catch {
            let summary = Self.log(error, stage: "connect")
            recordStage(.connect, outcome: summary.asOutcome, since: connectStart)
            await session.disconnect()
            return
        }

        let selectStart = Date()
        do {
            _ = try await session.select(mailbox)
            Self.logger.notice("legacyEnrich: select: succeeded")
            recordStage(.select, outcome: .success, since: selectStart)
        } catch {
            let summary = Self.log(error, stage: "select")
            recordStage(.select, outcome: summary.asOutcome, since: selectStart)
            await session.disconnect()
            return
        }

        let latestUID = UInt32(max(payload.uidNext - 1, 1))
        let fetchEnvelopeStart = Date()
        let envelopes: [FetchedEnvelope]
        do {
            envelopes = try await session.fetchEnvelopes(mailboxPath: mailbox, uids: .uid(latestUID), batchSize: 1)
            Self.logger.notice("legacyEnrich: fetchEnvelope: succeeded count=\(envelopes.count, privacy: .public)")
        } catch {
            let summary = Self.log(error, stage: "fetchEnvelope")
            recordStage(.fetchEnvelope, outcome: summary.asOutcome, since: fetchEnvelopeStart)
            await session.disconnect()
            return
        }

        guard let envelope = envelopes.first else {
            Self.logger.notice("""
            legacyEnrich: fetchEnvelope: no results for uid=\(latestUID, privacy: .public) \
            (uidNext=\(payload.uidNext, privacy: .public)) — already expunged/moved, \
            or a uidNext/UID mismatch; falling back to generic
            """)
            recordStage(.fetchEnvelope, outcome: .failure(category: "noEnvelopeResult", looksRateLimited: false, logDetail: nil), since: fetchEnvelopeStart)
            await session.disconnect()
            return
        }
        recordStage(.fetchEnvelope, outcome: .success, since: fetchEnvelopeStart)

        // Apply the cheap envelope-derived content immediately. If the
        // heavier whole-body fetch below exceeds the display budget, the
        // user still sees sender + subject instead of losing all
        // enrichment to the generic fallback.
        let sender = envelope.from.first
        deliveryGate.withPending {
            bestAttemptContent?.title = NotificationEnrichment.title(
                preferences: preferences, senderName: sender?.name, senderAddress: sender?.address
            )
            bestAttemptContent?.body = NotificationEnrichment.body(
                preferences: preferences, subject: envelope.subject, bodyPreviewSourceText: nil
            )
        }

        // Communication Notifications: reached only when the sync-first
        // path above couldn't resolve the pushed message at all
        // (`needsLegacyFallback`) — this envelope's own sender is the last
        // opportunity this run gets. A no-op if the earlier, payload-only
        // attempt in `enrich(payload:)` already reached a terminal answer.
        await attemptCommunicationNotificationIfNeeded(
            accountId: account.id,
            payload: payload,
            syncSenderName: sender?.name,
            syncSenderAddress: sender?.address,
            preferences: preferences
        )

        // Only pay for the (meaningfully heavier) whole-message fetch when
        // `showsBodyPreview` is actually on — see this type's doc comment,
        // step 5. A body-fetch failure here only drops the preview line,
        // not the envelope-derived title/subject already in hand, so it's
        // logged but never treated as this whole call failing.
        let fetchBodyStart = Date()
        var bodyPreviewSourceText: String?
        if preferences.showsBodyPreview {
            do {
                bodyPreviewSourceText = try await session.fetchBody(mailboxPath: mailbox, uid: latestUID).plainText
                Self.logger.notice("legacyEnrich: fetchBody: succeeded")
                recordStage(.fetchBody, outcome: .success, since: fetchBodyStart)
            } catch {
                let summary = Self.log(error, stage: "fetchBody")
                recordStage(.fetchBody, outcome: summary.asOutcome, since: fetchBodyStart)
            }
        } else {
            recordStage(.fetchBody, outcome: .skipped(reason: "showsBodyPreview off"), since: fetchBodyStart)
        }

        let applied = deliveryGate.withPending {
            bestAttemptContent?.title = NotificationEnrichment.title(
                preferences: preferences, senderName: sender?.name, senderAddress: sender?.address
            )
            bestAttemptContent?.body = NotificationEnrichment.body(
                preferences: preferences, subject: envelope.subject, bodyPreviewSourceText: bodyPreviewSourceText
            )
        }
        if applied {
            Self.logger.notice("legacyEnrich: applied enrichment to notification content")
        } else {
            Self.logger.notice("legacyEnrich: completed after notification delivery; discarded late content update")
        }
        await session.disconnect()
    }

    /// Classifies `error` (expected to be a `MailTransport.MailTransportError`
    /// from one of `enrich(payload:)`'s IMAP calls, but handled defensively
    /// for anything `Error`-shaped) and writes exactly one `.error`-level
    /// OSLog line naming `stage` and the failure category — see this type's
    /// "Diagnostic logging" doc comment. Only unwraps the
    /// `MailTransportError` case here (a `switch`, not practically unit
    /// testable — it's a straight one-to-one string mapping); the actual
    /// redaction/rate-limit-detection logic lives in
    /// `NotificationServiceDiagnostics.summarize(category:
    /// underlyingDescription:)` (`PushRelayClient`), which is.
    ///
    /// Returns the computed `ErrorSummary` (Task #213) so callers can also
    /// feed it to `recordStage(_:outcome:since:)` via `ErrorSummary
    /// .asOutcome` below, without re-deriving the same classification a
    /// second time.
    @discardableResult
    private static func log(_ error: Error, stage: String) -> NotificationServiceDiagnostics.ErrorSummary {
        let category: String
        let underlyingDescription: String?
        switch error {
        case let transportError as MailTransportError:
            switch transportError {
            case .connectionFailed(let description):
                category = "connectionFailed"
                underlyingDescription = description
            case .authenticationFailed(let description):
                category = "authenticationFailed"
                underlyingDescription = description
            case .serverError(let description):
                category = "serverError"
                underlyingDescription = description
            case .tooManyConnections(let description):
                // 通知拡張はアプリ本体とは別プロセスで自前の IMAP 接続を
                // 張るので、アカウントの同時接続数を押し上げる側でもある。
                // `serverError` に混ぜず独立したカテゴリで記録して、実機
                // 診断のときに切り分けられるようにする。
                category = "tooManyConnections"
                underlyingDescription = description
            case .malformedResponse(let description):
                category = "malformedResponse"
                underlyingDescription = description
            case .mailboxNotFound(let path):
                category = "mailboxNotFound"
                underlyingDescription = path
            case .notConnected:
                category = "notConnected"
                underlyingDescription = nil
            case .cancelled:
                category = "cancelled"
                underlyingDescription = nil
            case .notImplemented(let description):
                category = "notImplemented"
                underlyingDescription = description
            case .invalidAddress:
                category = "invalidAddress"
                underlyingDescription = nil
            }
        default:
            category = "unknown"
            underlyingDescription = String(describing: type(of: error))
        }

        let summary = NotificationServiceDiagnostics.summarize(category: category, underlyingDescription: underlyingDescription)
        if let detail = summary.logDetail {
            Self.logger.error("""
            enrich: \(stage, privacy: .public) failed category=\(summary.category, privacy: .public) \
            rateLimited=\(summary.looksRateLimited, privacy: .public) detail=\(detail, privacy: .public)
            """)
        } else {
            Self.logger.error("""
            enrich: \(stage, privacy: .public) failed category=\(summary.category, privacy: .public) \
            rateLimited=\(summary.looksRateLimited, privacy: .public)
            """)
        }
        return summary
    }

    /// Task #176: this device's current `NotificationContentPreferences`,
    /// read from the shared App Group `UserDefaults` suite —
    /// `NotificationContentSettingsStore.mirrorToAppGroup()` (app-side) is
    /// what keeps that suite's copy of these 3 keys up to date; this
    /// Extension only ever reads them, never writes. Falls back to
    /// `.allEnabled` (today's pre-#176 behavior) when the App Group
    /// container isn't reachable at all, or a key was never written there
    /// yet (a device that upgraded to this app version but hasn't launched
    /// the main app even once since — `AppEnvironment.init()`'s unconditional
    /// launch-time mirror call is what normally prevents that gap, but this
    /// Extension can in principle run before the containing app ever has).
    private static func notificationContentPreferences() -> NotificationContentPreferences {
        guard let appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return .allEnabled
        }
        return NotificationContentPreferences(
            showsSender: (defaults.object(forKey: NotificationContentPreferences.showsSenderKey) as? Bool) ?? true,
            showsSubject: (defaults.object(forKey: NotificationContentPreferences.showsSubjectKey) as? Bool) ?? true,
            showsBodyPreview: (defaults.object(forKey: NotificationContentPreferences.showsBodyPreviewKey) as? Bool) ?? true
        )
    }

    // MARK: - Communication Notifications (Task: 送信者アバター付きプッシュ通知)

    /// Mirrors `ListDisplaySettingsStore.showAvatarKey`
    /// ("listDisplay.showAvatar", `apps/Otegami/Sources/Support/Settings
    /// /ListDisplaySettingsStore.swift`) — the "送信者のプロフィールアイコン
    /// を表示" toggle in `MailListSettingsView` — into the same shared App
    /// Group `UserDefaults` suite `notificationContentPreferences()` above
    /// already reads. The app is responsible for mirroring it there (this
    /// Extension only ever reads, same "app writes, Extension reads" shape
    /// as everything else in this suite, `notificationContentPreferences()`'s
    /// own doc comment).
    ///
    /// **Why this toggle gates a *notification* feature at all**:
    /// `NotificationEnrichment`'s own doc comment states the underlying
    /// design principle — a notification the user configured to hide
    /// something must look identical to one that simply failed to enrich,
    /// never a "we know but you said not to show it" half-measure. Showing
    /// an avatar in a push notification when the user has explicitly turned
    /// sender avatars off everywhere else in this app would be exactly that
    /// kind of inconsistency.
    ///
    /// Defaults to `true` when the key is missing entirely — same reasoning
    /// `notificationContentPreferences()`'s own `.allEnabled` fallback
    /// gives: an existing install that upgraded but hasn't mirrored this
    /// key yet (or whose app hasn't launched since this feature shipped)
    /// must not silently lose a feature it never explicitly turned off.
    ///
    /// **Key name intentionally not a shared constant.** Unlike
    /// `NotificationContentPreferences.showsSenderKey`/etc — a small value
    /// type that already lives in the `PushRelayClient` package both
    /// targets link — `ListDisplaySettingsStore` itself lives in the
    /// `Otegami` app target, which this Extension can't import (the same
    /// reasoning `pushRelayBaseURL`/`OAuthConfig` elsewhere in this file
    /// already document for other app-target-only constants duplicated by
    /// hand here). Changing `ListDisplaySettingsStore.showAvatarKey`'s raw
    /// string requires updating this literal too.
    private static func showsAvatarPreference() -> Bool {
        guard let appGroupIdentifier, let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return true
        }
        return (defaults.object(forKey: "listDisplay.showAvatar") as? Bool) ?? true
    }

    /// Attempts to promote this notification into a Communication
    /// Notification once this run's sender is as fully resolved as it's
    /// going to get at this call site — see `CommunicationNotification.swift`'s
    /// top doc comment for the overall feature design, and
    /// `NotificationService.senderDecision(...)`'s own doc comment for the
    /// payload-vs-sync address priority this defers to entirely.
    ///
    /// Called from up to three places in `enrich(payload:)`/`legacyEnrich`,
    /// earliest-opportunity first: immediately after the network-free relay
    /// envelope (payload-only, no sync info yet), after the sync-first path
    /// resolves a message, and — only if sync-first didn't resolve one at
    /// all — after the legacy IMAP fallback resolves an envelope. Guarded by
    /// `communicationNotificationAttempted` so only the first call that
    /// reaches a *terminal* answer actually does anything:
    /// - `.decorate` and every `SkipReason` other than `.noSenderAddress`
    ///   are terminal — none of preferences/cache state/a payload address
    ///   already in hand can change for the rest of this run, so a later
    ///   call would just repeat the same answer (and duplicate this run's
    ///   `.communicationNotification` diagnostics stage record).
    /// - `.noSenderAddress` from a call that itself passed no
    ///   `syncSenderAddress` (i.e. the very first, payload-only call, when
    ///   the payload named no sender) is **not** terminal — a later call
    ///   with sync/legacy-resolved sender info deserves a real chance to
    ///   still decorate. `.noSenderAddress` from a call that *did* pass a
    ///   `syncSenderAddress` (meaning `senderDecision` still rejected it —
    ///   only possible if that address was empty) is terminal: there is no
    ///   further fallback source left.
    private func attemptCommunicationNotificationIfNeeded(
        accountId: String,
        payload: PushNotificationPayload,
        syncSenderName: String?,
        syncSenderAddress: String?,
        preferences: NotificationContentPreferences
    ) async {
        guard !communicationNotificationAttempted else { return }
        let start = Date()
        let showsAvatar = Self.showsAvatarPreference()
        let avatarStore = SharedAvatarStore(appGroupIdentifier: Self.appGroupIdentifier)
        let decision = Self.senderDecision(
            accountId: accountId,
            payloadSenderAddress: payload.latestFromAddress,
            payloadSenderName: payload.latestFromName,
            syncSenderAddress: syncSenderAddress,
            syncSenderName: syncSenderName,
            preferences: preferences,
            showsAvatar: showsAvatar,
            avatarStore: avatarStore
        )
        switch decision {
        case .skip(let reason):
            if reason != .noSenderAddress || syncSenderAddress != nil {
                communicationNotificationAttempted = true
            }
            Self.logger.notice("enrich: communicationNotification: skipped reason=\(reason.rawValue, privacy: .public)")
            recordStage(.communicationNotification, outcome: .skipped(reason: reason.rawValue), since: start)
        case .decorate(let sender):
            communicationNotificationAttempted = true
            switch await CommunicationNotificationBuilder.donate(sender: sender) {
            case .success(let intent):
                let applied = deliveryGate.withPending {
                    communicationNotificationIntent = intent
                    communicationNotificationConversationIdentifier = sender.conversationIdentifier
                }
                Self.logger.notice("enrich: communicationNotification: donated, will decorate at deliver() applied=\(applied, privacy: .public)")
                recordStage(.communicationNotification, outcome: .success, since: start)
            case .failure(let error):
                Self.logger.notice("enrich: communicationNotification: donate threw — delivering without decoration")
                recordStage(
                    .communicationNotification,
                    outcome: .failure(category: "donateFailed", looksRateLimited: false, logDetail: String(describing: error)),
                    since: start
                )
            }
        }
    }

    // MARK: - Payload / account lookup

    // Task (apps 層ユニットテストターゲット新設): private → internal に緩和 —
    // `NotificationServiceTests` (`project.yml` の同ターゲットの doc comment
    // 参照: `NotificationService.swift` 自体をテストターゲットの sources に
    // も加えて同一モジュール内で直接コンパイルしている) がこの純粋ロジック
    // だけを直接テストできるようにするため。Phase2d/Phase4 で確立済みの
    // 「テスト到達のための private → internal 緩和」と同じパターンで、これ
    // 以上の公開範囲拡大 (public 化等) はしていない。
    // Phase 3 (NSE のリレー先読み統合): `latestUid`/`latestFromName`/
    // `latestFromAddress`/`latestSubject`/`previewCount` are all optional,
    // relay-side-opt-in fields (`OtegamiRelayAPI.PushNotificationPayload`'s
    // doc comment) — every one is simply absent from `userInfo` on a
    // legacy relay/older push, and each `as?` below yields `nil` for a
    // missing key exactly like every other optional cast here, so this
    // stays exactly as lenient as before for `accountId`/`uidNext`.
    // `latestUid` arrives from APNs' JSON→plist bridging as an `NSNumber`
    // (same as `uidNext`, just held as `Int64` on the Swift side since a
    // UID can in principle exceed `Int32.max`) — `NSNumber.int64Value`
    // handles both an integral and (defensively) a non-integral JSON number
    // the same way `as? Int` already does for `uidNext`.
    static func parsePayload(_ userInfo: [AnyHashable: Any]) -> PushNotificationPayload? {
        guard let accountId = userInfo["accountId"] as? String,
              let uidNext = userInfo["uidNext"] as? Int
        else { return nil }
        return PushNotificationPayload(
            accountId: accountId,
            uidNext: uidNext,
            latestUid: (userInfo["latestUid"] as? NSNumber)?.int64Value,
            latestFromName: userInfo["latestFromName"] as? String,
            latestFromAddress: userInfo["latestFromAddress"] as? String,
            latestSubject: userInfo["latestSubject"] as? String,
            previewCount: userInfo["previewCount"] as? Int
        )
    }

    /// Task #192 (0xDEAD10CC 対策の調査): this `DatabasePool` shares the same
    /// App Group container/file the main app's `AppDatabase.makeShared`
    /// opens, and `AppDatabase.makeConfiguration
    /// (observesSuspensionNotifications:)` now enables GRDB's suspension
    /// observing for *any* caller that resolves to that shared container —
    /// including this Extension — so it would react correctly to a
    /// `Database.suspendNotification` if one were ever posted here. In
    /// practice none is needed: confirmed this Extension only ever reads
    /// (`dbWriter.read` below — never `.write`), so it never holds a lock
    /// capable of triggering `0xDEAD10CC` in the first place, and `database`
    /// is a local variable that goes out of scope (closing the connection
    /// via GRDB's own `deinit`, matching `DatabaseReader.close()`'s doc
    /// comment — "you do not have to call this method... automatically
    /// closed when they are deinitialized") the moment this function
    /// returns, well before the OS could ever suspend this short-lived
    /// Extension process. See `docs/architecture.md`'s Known pitfalls
    /// (Task #192) for the full writeup.
    private static func lookupAccount(id: String) async throws -> AccountRecord? {
        let database = try AppDatabase.makeShared(appGroupIdentifier: appGroupIdentifier)
        return try await database.dbWriter.read { db in
            try AccountRecord.fetchOne(db, key: id)
        }
    }

    /// Task #216: what `password(forAccountId:)` found (or didn't) — one
    /// level more specific than a plain `String?` so `resolveAuth(for:)` can
    /// report *why* on the diagnostics screen (`CredentialResolution`'s doc
    /// comment) instead of a single opaque `noCredential`. `keychainError`'s
    /// `OSStatus` is a small numeric code (e.g.
    /// `errSecInteractionNotAllowed`/`-25308`, meaning the item's data
    /// protection class requires the device to be unlocked) — not the
    /// password itself, so safe to surface (Task #211's same reasoning).
    private enum PasswordLookupOutcome {
        case found(String)
        case notFound
        case keychainError(OSStatus)
    }

    /// Real-device bug found investigating Task #216 (every `.password`-auth
    /// account's `Resolving Credential` failing `noCredential` in 0ms — IMAP
    /// never even attempted — while every `.oauth2` account worked fine):
    /// this query never specified `kSecAttrSynchronizable`. Per Apple's
    /// documented default ("if the key is not specified in a search, only
    /// non-synchronizable items are returned" — exactly the reasoning
    /// `KeychainCredentialStore.anySynchronizableQuery`'s own doc comment
    /// already spells out for the *app* side), that made this query blind
    /// to every item `KeychainCredentialStore.setPassword` writes as
    /// synchronizable (`addSynchronizable`/`migrateToSynchronizableAndWrite`
    /// both always set `kSecAttrSynchronizable = true` — M11, iCloud
    /// Keychain sync), which is *every* password, from the very first save
    /// (not just a later edit-screen re-save) — so this broke every
    /// `.password`-auth account created since M11, regardless of provider.
    /// The `.oauth2` side's untouched success is direct confirmation: its
    /// refresh-token store (`oauthAccessToken(for:)`'s doc comment) has
    /// always widened with the equivalent `anySynchronizableQuery`, so it
    /// never had this bug to begin with. Widening this query with
    /// `kSecAttrSynchronizableAny` (matching every app-side query and the
    /// OAuth side) fixes this on the *read* side alone — no re-migration or
    /// password re-entry needed, the item was always correctly stored. See
    /// `docs/architecture.md`'s Known pitfalls (j.) for the full writeup.
    ///
    /// Also now falls back through `NotificationServiceKeychainQuery
    /// .legacyServices` (mirrors `KeychainCredentialStore.legacyServices` —
    /// the `52df393` service-name rename) — this Extension never did before
    /// Task #216, for the same "an item from an even older rename is
    /// otherwise permanently invisible" reason that store's own doc comment
    /// gives. No "ignoring access group" fallback the way the app-side
    /// macOS store needs: this Extension is iOS-only (no
    /// `NotificationService` target on macOS — `OtegamiAppGroup.swift`'s
    /// doc comment), and `project.yml` gives both the `Otegami` app target
    /// and this one the exact same non-`nil` `OTEGAMI_KEYCHAIN_GROUP`
    /// access group on iOS.
    ///
    /// Which service names to try, in what order, and whether to widen
    /// matching to any synchronizable state (the actual Task #216 fix) is
    /// `NotificationServiceKeychainQuery.attemptsInOrder(accountId:
    /// accessGroup:)` (`PushRelayClient`, unit-tested) — a plain-value type
    /// with no `Security` dependency, since `SecItemCopyMatching` itself
    /// can't be exercised from `swift test` and this Extension target isn't
    /// `swift test`-reachable either. This function is the thin glue that
    /// turns each `Attempt` into the real `[String: Any]` CFDictionary.
    private static func password(forAccountId accountId: String) -> PasswordLookupOutcome {
        func query(for attempt: NotificationServiceKeychainQuery.Attempt) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: attempt.service,
                kSecAttrAccount as String: attempt.accountId,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if attempt.matchesAnySynchronizableState {
                query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            }
            if let accessGroup = attempt.accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            return query
        }

        let attempts = NotificationServiceKeychainQuery.attemptsInOrder(accountId: accountId, accessGroup: keychainAccessGroup)
        for attempt in attempts {
            var result: AnyObject?
            let status = SecItemCopyMatching(query(for: attempt) as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) {
                return .found(password)
            }
            if status != errSecItemNotFound {
                Self.logger.notice("auth: password branch: SecItemCopyMatching failed service=\(attempt.service, privacy: .public) status=\(status, privacy: .public)")
                return .keychainError(status)
            }
        }
        return .notFound
    }

    // MARK: - Task #177: OAuth (`.oauth2`) account credentials

    /// Task #216: replaces this function's previous plain `MailAuth?`
    /// return. Before, every failure of either `authType` branch collapsed
    /// into the diagnostics screen's `credential` stage always showing the
    /// same `noCredential` category (Task #213) — enough to know *that* it
    /// failed, but not *why*, which is exactly what this account's bug
    /// needed to get root-caused. `category` mirrors
    /// `NotificationServiceDiagnostics.ErrorSummary.category`'s shape (an
    /// opaque, log-safe string) without reusing that type itself — this
    /// failure never comes from a `MailTransportError`, since no IMAP
    /// connection is even attempted before this resolves.
    private enum CredentialResolution {
        case success(MailAuth)
        case failure(category: String, logDetail: String?)
    }

    /// The `MailAuth` `enrich(payload:)` connects with, for either
    /// `authType` — `.password`'s Keychain-password lookup (Task #216: see
    /// `password(forAccountId:)`'s doc comment for the `kSecAttrSynchronizable`
    /// bug this fixes), or (Task #177) `.oauth2`'s
    /// Keychain-refresh-token-to-access-token exchange
    /// (`oauthAccessToken(for:)`).
    private static func resolveAuth(for account: AccountRecord) async -> CredentialResolution {
        switch account.authType {
        case .password:
            switch Self.password(forAccountId: account.id) {
            case .found(let password):
                return .success(.password(username: account.imapUsername, password: password))
            case .notFound:
                Self.logger.notice("auth: password branch: no Keychain item found for this account (checked current + legacy service names, any synchronizable state)")
                return .failure(category: "passwordNotFound", logDetail: nil)
            case .keychainError(let status):
                return .failure(category: "passwordKeychainError", logDetail: "status=\(status)")
            }
        case .oauth2:
            switch await Self.oauthAccessToken(for: account) {
            case .token(let accessToken):
                return .success(.xoauth2(username: account.imapUsername, accessToken: accessToken))
            case .noClientId:
                return .failure(category: "oauthNoClientId", logDetail: nil)
            case .unavailable:
                Self.logger.notice("auth: oauth2 branch: no access token resolved (see preceding log line for which sub-reason)")
                return .failure(category: "oauthTokenUnavailable", logDetail: nil)
            case .unsupportedAccountKind:
                return .failure(category: "oauthUnsupportedAccountKind", logDetail: nil)
            }
        }
    }

    /// Bounds the OAuth request itself even though the independent five-
    /// second notification display deadline normally wins first. Keeping a
    /// transport-level bound matters because task cancellation is not a
    /// promise that every underlying networking implementation stops
    /// immediately; this prevents abandoned enrichment work from lingering
    /// for the Extension process's entire lifetime.
    private static let oauthTokenFetchTimeout: TimeInterval = 10

    /// Task #216: what `oauthAccessToken(for:)` resolved (or didn't) — see
    /// `CredentialResolution`'s doc comment for why the diagnostics screen
    /// benefits from more than a plain `String?` here. `.unavailable` still
    /// collapses "no refresh token stored" / "refresh itself failed" /
    /// "timed out" into one bucket, by design — `PushOAuthAccessTokenResolution`
    /// deliberately never logs internally (its own doc comment), so there's
    /// no finer-grained reason available here without changing that type's
    /// contract, and the OSLog line right above each `.unavailable` return
    /// below already says which provider (`gmail`/`microsoft`) was involved.
    private enum OAuthTokenOutcome {
        case token(String)
        case noClientId
        case unavailable
        case unsupportedAccountKind
    }

    /// Resolves a currently-valid XOAUTH2 access token for `account`
    /// (`.oauth2`-kind only — Gmail/Outlook). This build having no Client ID
    /// configured for `account.kind`'s provider (`OAuthConfig`) returns
    /// `.noClientId`; everything else that can go wrong — no refresh token
    /// is stored for this account (never signed in via this provider, or a
    /// previous `invalid_grant` already wiped it — see `GoogleOAuth
    /// .TokenStore`/`MicrosoftOAuth.TokenStore`'s own doc comments), the
    /// refresh itself failed, or it simply took longer than
    /// `oauthTokenFetchTimeout` (`PushOAuthAccessTokenResolution`) — returns
    /// `.unavailable`.
    ///
    /// Uses the exact same `TokenStore`/OAuth client types
    /// `AppEnvironment.auth(for:)` uses for a foregrounded `.oauth2` sync
    /// (`AppEnvironment.swift`'s "Auth resolution" section) — a fresh
    /// `TokenStore` instance per call (this Extension is a short-lived,
    /// per-push process; there's no long-lived `AppEnvironment` to hold
    /// one), backed by the same default `KeychainRefreshTokenStore` (no
    /// explicit access group — see this file's doc comment on why that
    /// alone is already enough to read what the main app wrote: both
    /// targets' entitlements list the same single Keychain Access Group,
    /// which is therefore each process's *default* group too). A
    /// successful refresh here that hits `invalid_grant` has the exact
    /// same side effect it would in the main app: `TokenStore` wipes the
    /// now-dead refresh token from that same shared Keychain, so the next
    /// time the main app itself calls `auth(for:)` it correctly reports
    /// "要再認証" rather than retrying a token Google has already rejected.
    private static func oauthAccessToken(for account: AccountRecord) async -> OAuthTokenOutcome {
        guard account.kind == .gmail || account.kind == .microsoft else {
            Self.logger.notice("auth: oauth2 branch: account.kind is neither gmail nor microsoft — unreachable in practice, no token")
            return .unsupportedAccountKind
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = oauthTokenFetchTimeout
        configuration.timeoutIntervalForResource = oauthTokenFetchTimeout
        let urlSession = URLSession(configuration: configuration)
        let sessionRunner = UnreachableAuthorizationSessionRunner()

        switch account.kind {
        case .gmail:
            guard let clientId = OAuthConfig.googleClientId else {
                Self.logger.notice("auth: oauth2 branch (gmail): this build has no Google Client ID configured")
                return .noClientId
            }
            let client = GoogleOAuthClient(
                endpoints: .standard(clientId: clientId),
                sessionRunner: sessionRunner,
                urlSession: urlSession
            )
            let tokenStore = GoogleOAuth.TokenStore(refresher: client)
            let token = await PushOAuthAccessTokenResolution.resolve(timeout: oauthTokenFetchTimeout) {
                try await tokenStore.accessToken(for: account.id)
            }
            // Collapses "no stored refresh token" / "refresh itself failed
            // (e.g. invalid_grant)" / "timed out" into one line by design —
            // `PushOAuthAccessTokenResolution`'s own doc comment: "this
            // type never logs at all", so this is the closest this
            // Extension gets to knowing *that* the gmail branch lost
            // without ever touching the token value itself.
            guard let token else {
                Self.logger.notice("auth: oauth2 branch (gmail): token resolution returned nil (no refresh token / refresh failed / timed out)")
                return .unavailable
            }
            return .token(token)
        case .microsoft:
            guard let clientId = OAuthConfig.microsoftClientId else {
                Self.logger.notice("auth: oauth2 branch (microsoft): this build has no Microsoft Client ID configured")
                return .noClientId
            }
            let client = MicrosoftOAuthClient(
                endpoints: .standard(clientId: clientId),
                sessionRunner: sessionRunner,
                urlSession: urlSession
            )
            let tokenStore = MicrosoftOAuth.TokenStore(refresher: client)
            let token = await PushOAuthAccessTokenResolution.resolve(timeout: oauthTokenFetchTimeout) {
                try await tokenStore.accessToken(for: account.id)
            }
            guard let token else {
                Self.logger.notice("auth: oauth2 branch (microsoft): token resolution returned nil (no refresh token / refresh failed / timed out)")
                return .unavailable
            }
            return .token(token)
        case .generic, .icloud:
            return .unsupportedAccountKind
        }
    }

    /// `Bundle.main` here is the Extension's own bundle (not the
    /// containing app's) — see `apps/Otegami/Sources/Support
    /// /OtegamiAppGroup.swift`'s doc comment on why this is a separate,
    /// identically-named copy rather than a shared import.
    private static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiAppGroupIdentifier") as? String
    }

    private static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OtegamiKeychainAccessGroup") as? String
    }
}

/// Task #213 — the one place `NotificationServiceDiagnostics.ErrorSummary`
/// (OSLog-oriented) turns into `PushDiagnosticsRun.Outcome` (on-device
/// screen-oriented); the two types carry the exact same 3 fields
/// (category/looksRateLimited/logDetail) by design, so this is a plain
/// field-for-field mapping, not a second classification.
extension NotificationServiceDiagnostics.ErrorSummary {
    fileprivate var asOutcome: PushDiagnosticsRun.Outcome {
        .failure(category: category, looksRateLimited: looksRateLimited, logDetail: logDetail)
    }
}

/// Task #177: mirrors `GoogleOAuthConfig`/`MicrosoftOAuthConfig`
/// (`apps/Otegami/Sources/Features/Settings/Auth/`) — reads the same two
/// xcconfig-sourced Client ID `Info.plist` keys those two enums read, but
/// against *this* target's own `Bundle.main` (this Extension's bundle, not
/// the containing app's — same reasoning `appGroupIdentifier`/
/// `keychainAccessGroup` above already document, and why this is a small
/// separate copy rather than an import: those two enums live in the
/// `Otegami` app target itself, which an app extension target can't depend
/// on). `project.yml`'s `NotificationService` target now declares both
/// `GOOGLE_OAUTH_CLIENT_ID`/`OTEGAMI_MICROSOFT_CLIENT_ID` in its own
/// `info.properties` to make that possible.
private enum OAuthConfig {
    static var googleClientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_OAUTH_CLIENT_ID") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    static var microsoftClientId: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OTEGAMI_MICROSOFT_CLIENT_ID") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }
}

/// `GoogleOAuthClient`/`MicrosoftOAuthClient` both require a concrete
/// `AuthorizationSessionRunning` conformer at `init`, but this Extension
/// only ever calls `TokenStore.accessToken(for:)` — a plain silent refresh,
/// never the interactive `requestAuthorization()` flow that's the only
/// caller of `sessionRunner.run(authorizationURL:callbackURLScheme:)`.
/// Satisfies both packages' identically-shaped (but distinct) protocols
/// with one throwing implementation, so a latent bug that somehow *did*
/// reach this path degrades to "this account's push falls back to the
/// generic notification body" (same as every other failure in
/// `oauthAccessToken(for:)`) rather than crashing the Extension process —
/// there is no UI to present a web authentication session from here even
/// if it were somehow reached.
private struct UnreachableAuthorizationSessionRunner: GoogleOAuth.AuthorizationSessionRunning, MicrosoftOAuth.AuthorizationSessionRunning {
    struct UnexpectedCallError: Error {}

    func run(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        throw UnexpectedCallError()
    }
}
