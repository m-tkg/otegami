import Foundation

/// Task #213 (前段: Task #211 が `NotificationService.enrich(payload:)` の
/// 各段階に OSLog 診断ログを入れたが、**実機のログを読むには Mac に有線
/// 接続して Console.app/`log stream` を操作する必要があり**、ユーザーが
/// 外出中などですぐに確認できない場面があった): 翻訳機能の「翻訳の診断」
/// 画面 (`OtegamiTranslationApple.TranslationDiagnosticsStore`) と同じ発想
/// — 実機のログ採取なしで、端末内の設定画面から直近の通知処理の結果を
/// 確認できるようにするための記録の型と、その保持ロジック。
///
/// **`NotificationService` は別プロセス (App Extension) — `Observable`な
/// インメモリストアでは書き手と読み手をつなげない。** 受け渡しは共有
/// App Group の `UserDefaults` 経由 (`BadgeCenter.setBadge(count:)`/
/// `NotificationContentSettingsStore.mirrorToAppGroup()`と同じ前例) を
/// 採用した。共有コンテナの `AppDatabase` (GRDB) に書く案も検討したが、
/// 採用しなかった理由:
/// - `NotificationService.lookupAccount(id:)`のdoc comment (Task #192) が
///   明記する通り、このExtensionは**現状 `dbWriter.read` のみで一切
///   `.write` しない**ことが前提で「0xDEAD10CC を起こすロックを一度も
///   持たない」という安全性を担保している。診断記録のためだけに新しい
///   `.write` 経路を追加すると、その前提を壊し (Extensionが suspend
///   される瞬間に write トランザクションが未コミットで残るリスクを
///   新たに持ち込む)、この診断機能自体が別の実機バグの温床になりかねない。
/// - 記録する内容は各段階の分類文字列・bool・整数だけ (本文・件名・
///   差出人・資格情報は含まない、`docs/architecture.md`と同じ方針) —
///   スキーマ管理・マイグレーションの要る RDB を持ち出すには小さすぎる。
///   直近`maxRuns`件だけを保持する固定長リストは、単純な JSON エンコード
///   された `[UInt8]`/`Data` 1個としてUserDefaultsに収める方が自然。
///
/// **書き込みが本来の処理を圧迫しないこと**: `NotificationService`は
/// 各段階が終わるたびにこの型のインスタンス (`StageRecord`) をメモリ上の
/// 配列へ追記するだけ (I/O なし)。実際の JSON エンコード + UserDefaults
/// への書き込みは `deliver()` で **1回だけ**、`contentHandler`を呼ぶ直前に
/// 行う — IMAP 接続やフェッチが進行中の間は一切ディスク/UserDefaults に
/// 触れない。
public struct PushDiagnosticsRun: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    /// Recorded in the order `NotificationService.enrich(payload:)`
    /// actually reached each stage — a run that stopped early (e.g. all 3
    /// content toggles off, or account lookup failed) simply has fewer
    /// elements, which is itself diagnostic information (a screen showing
    /// this run doesn't need a separate "stopped at" field).
    public let stages: [StageRecord]
    /// Total wall-clock time for this run, mirroring
    /// `NotificationService.deliver()`'s existing `elapsedMs` OSLog line.
    /// `nil` only if a run were somehow persisted before `didReceive`
    /// recorded a start time — doesn't happen in production.
    public let totalElapsedMs: Int?

    public init(id: UUID = UUID(), date: Date = Date(), stages: [StageRecord], totalElapsedMs: Int?) {
        self.id = id
        self.date = date
        self.stages = stages
        self.totalElapsedMs = totalElapsedMs
    }

    public struct StageRecord: Sendable, Codable, Equatable, Identifiable {
        public var id: Stage { stage }
        public let stage: Stage
        public let outcome: Outcome
        public let elapsedMs: Int?

        public init(stage: Stage, outcome: Outcome, elapsedMs: Int?) {
            self.stage = stage
            self.outcome = outcome
            self.elapsedMs = elapsedMs
        }
    }

    /// The 8 stages named in Task #213's own request text, in the order
    /// `enrich(payload:)` reaches them — `parsePayload`/`preferences` are
    /// checked before any account/IMAP work even starts.
    ///
    /// **`incrementalSync`** (push 通知起点バックグラウンド受信 Phase 1):
    /// added once `enrich(payload:)`'s primary path became
    /// `PushTriggeredInboxSync.run(...)` — a full INBOX-only incremental
    /// sync (not just an envelope re-fetch) that durably persists the new
    /// message into the shared database before the notification shows.
    /// Recorded right after `credential` succeeds and before any of the
    /// `connect`/`select`/`fetchEnvelope`/`fetchBody` stages below, which
    /// now only run as a **fallback** when this stage's own sync didn't
    /// resolve the pushed message (`Outcome.message == nil` — an unknown
    /// account/no-INBOX/busy-database/network failure inside
    /// `PushTriggeredInboxSync.run` all collapse into that same one signal,
    /// since that type's own doc comment explains it deliberately never
    /// exposes *why* it gave up). `.success` here means the sync-first path
    /// alone produced this run's notification content and this run's badge
    /// count is the real post-sync unread count, not the legacy "+1"
    /// estimate — see `NotificationService.applyTrueBadgeCount(_:)`.
    /// **`relayPreview`** (push 通知起点バックグラウンド受信 Phase 3: NSE の
    /// リレー先読み統合): recorded right after `credential` succeeds (before
    /// `incrementalSync`) whenever the payload carries an envelope
    /// (`OtegamiRelayAPI.PushNotificationPayload.latestUid`) and
    /// `showsBodyPreview` is on — `enrich(payload:)` calls `PushRelayClient
    /// .fetchMessagePreviews(...)` (`GET /v1/messages`) to get a body
    /// preview it can show *before* the (slower, IMAP-based)
    /// `incrementalSync` stage below even starts. `.skipped` covers every
    /// reason this stage was reached but not actually attempted (no
    /// envelope in the payload, `showsBodyPreview` off, no relay URL/device
    /// secret configured) or attempted but the relay had no matching entry;
    /// a 404 (feature off relay-side, or no watch for this account) is also
    /// `.skipped`, not `.failure` — it's an expected, unremarkable outcome,
    /// not something gone wrong. Either way, this stage's own outcome never
    /// blocks or changes `incrementalSync`/the rest of `enrich(payload:)` —
    /// it only affects how quickly a body preview can appear on screen.
    ///
    /// **`communicationNotification`** (iOS Communication Notifications,
    /// Task: 送信者アバター付きプッシュ通知): recorded by
    /// `NotificationService.attemptCommunicationNotificationIfNeeded(...)` —
    /// called once this run's sender is as fully known as it will ever get
    /// (right after the sync-first path resolves a message, or right after
    /// the legacy IMAP fallback resolves an envelope; may also resolve
    /// immediately from the push payload's own relay-prefetched envelope,
    /// before either of those). This is the only diagnostic signal for this
    /// feature — it can only be exercised on a real device (Communication
    /// Notifications, `INInteraction.donate()`, and the resulting avatar
    /// rendering all require real `UNUserNotificationCenter`/Intents runtime
    /// state a simulator/unit test can't provide). `.skipped(reason:)`
    /// distinguishes "showsSender off" / "showAvatar off" / "no sender
    /// address" / "avatar cache miss" (`CommunicationNotificationDecision
    /// .SkipReason`'s own raw values); `.failure` covers either
    /// `INInteraction.donate()` or (recorded separately, from
    /// `NotificationService.deliver()` itself, since donation and content
    /// decoration are two different failure points) `UNNotificationContent
    /// .updating(from:)` throwing.
    public enum Stage: String, Sendable, Codable, CaseIterable {
        case parsePayload
        case preferences
        case accountLookup
        case credential
        case relayPreview
        case incrementalSync
        case connect
        case select
        case fetchEnvelope
        case fetchBody
        case communicationNotification
    }

    /// Never carries subject/sender/body/credentials — `category`/
    /// `logDetail` are the same log-safe values
    /// `NotificationServiceDiagnostics.summarize(category:underlyingDescription:)`
    /// already produces for OSLog (this type just gives them a second,
    /// on-device-readable home).
    public enum Outcome: Sendable, Codable, Equatable {
        case success
        /// A stage that was reached but deliberately not attempted (e.g.
        /// `fetchBody` when `showsBodyPreview` is off).
        case skipped(reason: String)
        case failure(category: String, looksRateLimited: Bool, logDetail: String?)
    }
}

/// Pure list-management logic for `PushDiagnosticsRun` (insert-at-front +
/// cap, JSON encode/decode) plus the `UserDefaults` suite key both
/// `NotificationService` (writer) and the app's `PushDiagnosticsStore`
/// (reader) use — kept in this one package (both targets already link
/// `PushRelayClient`, see `NotificationService.swift`'s existing `import
/// PushRelayClient`) rather than duplicated across the two targets.
public enum PushDiagnosticsHistory {
    /// How many recent runs to keep. **20**, not 5 like
    /// `TranslationDiagnosticsStore` — a device can have several accounts
    /// (Gmail/iCloud/Yahoo/…) sharing this one history, and only one of
    /// them may be the account actually failing (Yahoo, per
    /// `docs/architecture.md`'s pitfall i.). 20 gives enough headroom that
    /// a handful of unrelated accounts' pushes arriving in between don't
    /// immediately push the run you actually want to inspect out of the
    /// window, while each run is tiny (a handful of small stage records,
    /// no body text) — 20 of them is comfortably under 10KB of JSON, far
    /// below any practical `UserDefaults` size concern.
    public static let maxRuns = 20

    /// The shared App Group `UserDefaults` key both sides use — see
    /// `PushDiagnosticsRun`'s doc comment for why this lives in the shared
    /// package instead of being a mirrored string constant.
    public static let userDefaultsKey = "pushDiagnostics.runs"

    /// Inserts `run` at the front of `existing` (newest first — matches
    /// `TranslationDiagnosticsStore.record(_:)`'s ordering, which a
    /// diagnostics screen can display directly) and trims to `maxRuns`.
    public static func inserting(_ run: PushDiagnosticsRun, into existing: [PushDiagnosticsRun]) -> [PushDiagnosticsRun] {
        var updated = existing
        updated.insert(run, at: 0)
        if updated.count > maxRuns {
            updated.removeLast(updated.count - maxRuns)
        }
        return updated
    }

    public static func encode(_ runs: [PushDiagnosticsRun]) -> Data? {
        try? JSONEncoder().encode(runs)
    }

    /// `nil`/undecodable input (never persisted yet, or a future app
    /// version's shape this one doesn't understand) decodes to an empty
    /// list rather than throwing — a diagnostics screen with no history is
    /// a normal, expected state, not an error.
    public static func decode(_ data: Data?) -> [PushDiagnosticsRun] {
        guard let data, let decoded = try? JSONDecoder().decode([PushDiagnosticsRun].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Reader side (`PushDiagnosticsStore`, app target): the current
    /// history, newest first.
    public static func loadRuns(fromSuite suite: UserDefaults) -> [PushDiagnosticsRun] {
        decode(suite.data(forKey: userDefaultsKey))
    }

    /// Writer side (`NotificationService`, Extension target): a single
    /// read-modify-write against `suite` — the only `UserDefaults` I/O this
    /// whole feature does per push, called exactly once from
    /// `NotificationService.deliver()`.
    public static func appending(_ run: PushDiagnosticsRun, toSuite suite: UserDefaults) {
        let updated = inserting(run, into: loadRuns(fromSuite: suite))
        suite.set(encode(updated), forKey: userDefaultsKey)
    }
}
