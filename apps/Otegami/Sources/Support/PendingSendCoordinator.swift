import Foundation
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine
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

    /// Starts (or restarts, cancelling whatever was already pending —
    /// there is only ever one composer session's send in flight at a time
    /// in this app) the countdown for an already-durably-written send.
    func schedule(outboxMessageId: Int64, accountId: String, duration: TimeInterval, snapshot: PendingSendDraftSnapshot) {
        countdownTask?.cancel()
        pendingSend = PendingSend(outboxMessageId: outboxMessageId, accountId: accountId, startedAt: Date(), duration: duration, snapshot: snapshot)
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
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
        await replay(accountId: pending.accountId)
    }

    private func replay(accountId: String) async {
        guard let environment else { return }
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }

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

        guard let auth = try? await environment.auth(for: account) else { return }
        _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
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
