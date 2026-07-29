import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine
import os
#if os(iOS)
import UIKit
#endif

/// C6/C7: coordinates the gap between "送信" being tapped in `ComposerView`
/// and the message actually leaving over SMTP. `ComposerView.send()` already
/// commits the message durably (an `outboxMessage` row + a `.send` opQueue
/// op, in one transaction — see that method's doc comment) before this type
/// gets involved at all, so **the message can never be lost** even if the
/// process is killed mid-countdown: a future launch's ordinary opQueue
/// replay picks the row up regardless of whether this coordinator ever runs
/// again (C6 「送信の消失防止」).
///
/// What this type actually owns is *when* the already-durable send is
/// allowed to actually reach the network, and how to fully undo it if the
/// user taps "送信を取り消す" in time:
///
/// - `schedule(...)` starts a countdown (`SendCancelSettingsStore`'s
///   window); `SendCountdownBar` (iOS's `OtegamiTabRootView`) reads
///   `pendingSend` to render the bar and animate it via `TimelineView`
///   against `startedAt`/`duration` directly, so this type never needs to
///   tick a timer itself just to drive UI.
/// - `finalizeNow()` — called both when the countdown elapses naturally and
///   from `OtegamiTabRootView`'s scene-phase observer the instant the app
///   leaves the foreground (C7 「アプリを離脱したら即座に送信を確定」,
///   deliberately cutting the window short rather than letting it keep
///   counting down unobserved in the background — `SendCancelSettingsStore`
///   's doc comment on why 30s/60s aren't offered explains the same
///   underlying background-execution constraint) — hands the send to
///   `OpQueueProcessor.replay` via `SyncCoordinator`, wrapped in an iOS
///   `beginBackgroundTask` so the just-triggered network send gets a grace
///   period to finish even though the app is backgrounding at that exact
///   moment.
/// - `cancelPendingSend()` reverses the local write `ComposerView.send()`
///   made (deletes the `outboxMessage`/`outboxAttachment` rows, their staged
///   files, and the matching `.send` opQueue row) and returns the snapshot
///   `ComposerView` needs to reopen with the exact same fields
///   (`PendingSendDraftSnapshot`).
///
/// `@MainActor`/`@Observable`: `pendingSend` drives `SendCountdownBar`
/// directly, the same pattern `AppEnvironment` itself uses for UI-facing
/// state.
@MainActor
@Observable
final class PendingSendCoordinator {
    struct PendingSend: Identifiable {
        let id = UUID()
        var outboxMessageId: Int64
        var accountId: String
        var startedAt: Date
        var duration: TimeInterval
        var snapshot: PendingSendDraftSnapshot
    }

    private(set) var pendingSend: PendingSend?

    /// Task #124 — shared with `OpQueueProcessor`/`ComposerView` so one
    /// send's whole enqueue → schedule → finalize → replay → SMTP lifecycle
    /// reads as a single interleaved stream in Console.app.
    private static let logger = Logger(subsystem: "com.mtkg.otegami", category: "PendingSend")

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// Set once, right after `AppEnvironment.init()` constructs this
    /// coordinator — `weak` since `AppEnvironment` owns this coordinator
    /// strongly (the reverse reference must not create a cycle). Both
    /// objects live for the app's entire process lifetime in practice, so
    /// there's no realistic teardown-ordering hazard from the weak
    /// reference going `nil` mid-use.
    @ObservationIgnored private weak var environment: AppEnvironment?

    func configure(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Starts the countdown for an already-durably-written send — normally
    /// there is only ever one composer session's send in flight at a time
    /// (the doc comment above), but nothing actually prevents a user from
    /// reopening Composer and sending a *second* message while the first's
    /// countdown bar is still showing. Task #124: a naive "just overwrite
    /// `pendingSend`" here used to silently orphan that first send —
    /// `countdownTask?.cancel()` killed the only `Task` that would ever
    /// have called `finalizeNow()` for it, so the message stayed durably
    /// queued but with nothing left to trigger its replay until some
    /// *unrelated* opportunistic replay call (a swipe action, the next
    /// foreground, ...) happened to pick it up — exactly the "カウントダウン
    /// 満了後、そのセッション内でreplayがトリガーされない" symptom reported. Calling
    /// `finalizeNow()` first (a fast no-op guard return in the ordinary
    /// single-send case) guarantees whatever was pending before this call
    /// is fully handed off to replay before it's ever overwritten below.
    func schedule(outboxMessageId: Int64, accountId: String, duration: TimeInterval, snapshot: PendingSendDraftSnapshot) async {
        if pendingSend != nil {
            Self.logger.notice("schedule() called while a previous pendingSend is still active — finalizing it before overwriting (Task #124)")
        }
        await finalizeNow()
        Self.logger.notice("countdown scheduled: outboxMessageId=\(outboxMessageId, privacy: .public) accountId=\(accountId, privacy: .private) duration=\(duration, privacy: .public)s")
        pendingSend = PendingSend(outboxMessageId: outboxMessageId, accountId: accountId, startedAt: Date(), duration: duration, snapshot: snapshot)
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            Self.logger.notice("countdown elapsed naturally: outboxMessageId=\(outboxMessageId, privacy: .public)")
            await self?.finalizeNow()
        }
    }

    /// "送信を取り消す": reverses `ComposerView.send()`'s local write and
    /// returns what `ComposerView` needs to reopen with the same fields.
    /// `nil` if nothing is actually pending (e.g. the countdown already
    /// finalized in a race with the tap — the button is expected to be
    /// gone by then, but this stays defensive regardless).
    func cancelPendingSend() async -> PendingSendDraftSnapshot? {
        guard let pending = pendingSend else { return nil }
        countdownTask?.cancel()
        countdownTask = nil
        pendingSend = nil
        Self.logger.notice("send cancelled by user: outboxMessageId=\(pending.outboxMessageId, privacy: .public)")

        guard let environment else { return pending.snapshot }
        await Self.deleteOutboxMessage(id: pending.outboxMessageId, accountId: pending.accountId, database: environment.database)
        return pending.snapshot
    }

    /// Cuts the countdown short and hands the send to `OpQueueProcessor`
    /// right away — called both when the countdown elapses on its own and
    /// (immediately, no matter how much of the window is left) the instant
    /// the app leaves the foreground. A no-op if nothing is pending (the
    /// scene-phase observer calls this unconditionally on every background
    /// transition, pending send or not).
    func finalizeNow() async {
        guard let pending = pendingSend else { return }
        countdownTask?.cancel()
        countdownTask = nil
        pendingSend = nil
        Self.logger.notice("finalizing: outboxMessageId=\(pending.outboxMessageId, privacy: .public) accountId=\(pending.accountId, privacy: .private)")
        await replay(accountId: pending.accountId)
    }

    private func replay(accountId: String) async {
        Self.logger.notice("replay kicked for accountId=\(accountId, privacy: .private)")
        guard let environment else {
            Self.logger.error("replay aborted: no AppEnvironment configured")
            return
        }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            Self.logger.error("replay aborted: accountId=\(accountId, privacy: .private) not found among environment.accounts")
            return
        }

        #if os(iOS)
        // The network send this triggers may start right as the app is
        // backgrounding (`finalizeNow()`'s scene-phase call site) — without
        // an explicit background task, iOS can suspend the process before
        // `OpQueueProcessor.replay`'s SMTP round trip finishes, silently
        // leaving the send stuck until the next foreground/IDLE wake (not
        // data loss — the durable outbox row is still there — but exactly
        // the sluggish "disappeared for a while" experience C6 exists to
        // avoid). `beginBackgroundTask` asks iOS for extra runtime past the
        // normal background-suspend point; the expiration handler is a
        // last-resort cleanup if that grace period itself runs out before
        // replay finishes.
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "otegami.pendingSend") {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
        }
        defer {
            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
            }
        }
        #endif

        // Task #124: both of these were plain `try?`, silently swallowing
        // the error on failure — a real observed symptom ("送信待ちのまま
        // スタックし、次回起動でようやく送信された") was consistent with `auth(for:)`
        // failing right here (e.g. a token refresh hiccup at exactly the
        // moment the app is backgrounding) and nothing in this session ever
        // finding out. Logging on both failure paths doesn't change the
        // best-effort behavior (the durable outbox row + opQueue op are
        // untouched either way — a later opportunistic replay, or the next
        // launch's own foreground-active replay pass, still picks it up —
        // see `OtegamiApp.syncAllAccountsOnce()`), but makes a repeat of
        // this failure mode diagnosable from device logs instead of only
        // reproducible by luck.
        do {
            let auth = try await environment.auth(for: account)
            let result = try await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            Self.logger.notice("replay finished for accountId=\(accountId, privacy: .private): succeeded=\(result.succeeded) retrying=\(result.retrying) permanentlyFailed=\(result.permanentlyFailed)")
        } catch {
            Self.logger.error("replay failed for accountId=\(accountId, privacy: .private): \(String(describing: error)) — the durable outbox row/opQueue op are untouched, a later opportunistic replay or the next foreground will still pick it up")
        }
    }

    /// Reverses the durable write `ComposerView.send()` made: deletes the
    /// `outboxMessage` row (cascading its `outboxAttachment` rows via the
    /// schema's FK), the matching `.send` opQueue row (found by decoding
    /// each pending `.send` op's payload — there are normally at most one
    /// or two in flight at once, so a linear scan is fine), and the staged
    /// attachment files on disk — same "read paths before the row delete,
    /// unlink after" order `OpQueueProcessor.deleteOutboxMessage` uses, for
    /// the same reason (the FK cascade removes the rows that would
    /// otherwise identify the files).
    private static func deleteOutboxMessage(id outboxMessageId: Int64, accountId: String, database: AppDatabase) async {
        try? await database.dbWriter.write { db in
            let attachmentPaths = try OutboxAttachmentRecord
                .filter(Column("outboxMessageId") == outboxMessageId)
                .fetchAll(db)
                .map(\.localPath)

            let sendOps = try OpQueueRecord
                .filter(Column("accountId") == accountId)
                .filter(Column("kind") == OpQueueKind.send.rawValue)
                .fetchAll(db)
            for op in sendOps {
                guard let payload = try? JSONDecoder().decode(SendOpPayload.self, from: op.payload) else { continue }
                guard payload.outboxMessageId == outboxMessageId else { continue }
                try op.delete(db)
            }

            _ = try OutboxMessageRecord.deleteOne(db, key: outboxMessageId)

            for path in attachmentPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
