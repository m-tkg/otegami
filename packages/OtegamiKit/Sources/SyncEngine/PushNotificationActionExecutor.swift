import Foundation
import GRDB
import MailTransport
import OtegamiStore

/// An action a push notification's action buttons ("既読にする"/
/// "アーカイブ") can request. The app target's `AppDelegate` maps
/// `UNNotificationResponse.actionIdentifier` to one of these and hands it,
/// along with the triggering `PushNotificationPayload`, to
/// `PushNotificationActionExecutor.execute(action:accountId:uidNext:
/// database:auth:sessionFactory:)`.
public enum PushNotificationAction: Sendable {
    case markRead
    case archive
}

/// Executes a push notification action against the local database (and,
/// best-effort, the server), entirely outside the app process — a Notification
/// Service Extension or the app's own background handler calls this with no
/// UI in scope and no chance to show an error, so every step here is designed
/// to degrade to "leave it for the next normal sync" rather than surface a
/// failure anywhere.
///
/// The push payload only carries `accountId`/`uidNext`
/// (`OtegamiRelayAPI.PushNotificationPayload`), not a message id — the
/// target message is inferred the same way
/// `NotificationService.enrich(...)` (`apps/Otegami/NotificationService/
/// NotificationService.swift:480`) already infers "the new message" for
/// rich-notification enrichment: `uid = max(uidNext - 1, 1)`, mailbox
/// INBOX. That's a heuristic (the newest UID a `uidNext` observation
/// implies), not a guarantee — good enough for a notification action, which
/// has no stronger signal available either.
///
/// Deliberately has no dependency on `MailTransportMailCore`, Keychain, or
/// any OAuth client: IMAP session construction (`sessionFactory`) and
/// credential resolution (`auth`) are both injected by the caller, mirroring
/// `OpQueueProcessor`'s own `sessionFactory` injection
/// (`OpQueueProcessor.swift`) — this keeps `SyncEngine` independent of any
/// specific transport/credential backend, letting the app wire the real
/// ones while tests inject fakes.
public enum PushNotificationActionExecutor {
    /// Applies `action` for the message a push notification identifies
    /// (`accountId`/`uidNext`) to the local database — updating a
    /// already-synced local copy directly (`MessagePinReadState`/
    /// `MessageRemoval`, the same local-DB logic swipe actions use) or, if
    /// no local copy exists yet, enqueuing the equivalent `OpQueue`
    /// operation directly against `(mailboxId, uid)` — then makes one
    /// best-effort attempt to replay the opQueue immediately so the change
    /// reaches the server without waiting for the next foreground sync or
    /// IDLE wake.
    ///
    /// Every failure mode here (unknown account, no INBOX known yet, no
    /// local message row, credential resolution failure, the replay attempt
    /// itself failing) is handled by doing nothing further and returning —
    /// there is no UI to report an error to, and the local DB write (when
    /// it succeeds) is durable, so a normal sync later reconciles anything
    /// this best-effort replay didn't manage to push through.
    public static func execute(
        action: PushNotificationAction,
        accountId: String,
        uidNext: Int,
        database: AppDatabase,
        auth: @Sendable (AccountRecord) async -> MailAuth?,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) async {
        guard let account = try? await database.dbWriter.read({ db in
            try AccountRecord.fetchOne(db, key: accountId)
        }) else { return }

        guard let mailbox = try? await MailboxRoleResolver.mailbox(role: .inbox, accountId: accountId, database: database) else {
            return
        }

        // Mirrors `NotificationService.enrich(...)`'s identical heuristic
        // (`NotificationService.swift:480`) for inferring the target
        // message from a bare `uidNext` observation.
        let uid = UInt32(max(uidNext - 1, 1))

        let applied: Bool
        do {
            applied = try await database.dbWriter.write { db in
                try Self.apply(action: action, accountId: accountId, mailbox: mailbox, uid: uid, db: db)
            }
        } catch {
            return
        }
        guard applied else { return }

        guard let resolvedAuth = await auth(account) else { return }
        let processor = OpQueueProcessor(database: database, sessionFactory: sessionFactory)
        _ = try? await processor.replay(account: account, auth: resolvedAuth)
    }

    /// `resolveOpenTarget`のローカル読み取りが `nil`(対象メッセージが
    /// まだ未同期)を返した場合、まず対象UID 1通だけを狙い撃ちで取得する
    /// 高速経路 (`fetchTargetEnvelopeDirectly`) を試み、それでも解決でき
    /// なければそのアカウントのINBOXだけを対象にした優先的な差分同期を
    /// 1回試みてから再度 `resolveOpenTarget` を呼び直す。
    /// 「通知をタップしたら他の通信より先に対象メールを読み込んで開く」
    /// ための経路 — 全アカウント・全メールボックスを回す通常の起動時同期
    /// (`OtegamiApp.syncAllAccountsOnce()`)を待たず、この呼び出し自身が
    /// 対象メールだけを狙って取得する。
    ///
    /// 高速経路が先なのは実機報告「通知からメールを開くと表示まで数十秒
    /// かかる」への対処: INBOX全体の差分同期は未同期の新着が溜まっている
    /// ほど (数日ぶりの起動など) envelope 取得だけで数十秒かかりうるが、
    /// 通知タップが今すぐ必要なのは対象の1通だけ。残りの新着はこの解決と
    /// 無関係に走る通常の起動時同期が取り込む。
    ///
    /// 資格情報が解決できない、同期そのものが失敗する、同期後も対象UIDが
    /// 見つからない、のいずれも `nil` — 呼び出し側は通常どおり遷移を諦め、
    /// 統合受信トレイへフォールバックする（`resolveOpenTarget`と同じ
    /// 「表示できるものだけ表示する」設計）。
    public static func fetchAndResolveOpenTarget(
        accountId: String,
        uidNext: Int,
        database: AppDatabase,
        auth: @Sendable (AccountRecord) async -> MailAuth?,
        sessionFactory: @escaping @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) async -> (threadId: Int64, messageId: Int64)? {
        if let target = await resolveOpenTarget(accountId: accountId, uidNext: uidNext, database: database) {
            return target
        }

        guard let account = try? await database.dbWriter.read({ db in
            try AccountRecord.fetchOne(db, key: accountId)
        }), let resolvedAuth = await auth(account) else { return nil }

        if await fetchTargetEnvelopeDirectly(
            account: account, uidNext: uidNext, database: database,
            auth: resolvedAuth, sessionFactory: sessionFactory
        ), let target = await resolveOpenTarget(accountId: accountId, uidNext: uidNext, database: database) {
            return target
        }

        let coordinator = SyncCoordinator(database: database, sessionFactory: sessionFactory)
        _ = try? await coordinator.syncAccountIncrementally(
            account, auth: resolvedAuth, scope: .inboxOnly, autoRetry: false
        )

        return await resolveOpenTarget(accountId: accountId, uidNext: uidNext, database: database)
    }

    /// 高速経路: ローカル既知のINBOXに対して `connect → select → 対象UID
    /// 1通の envelope fetch → upsert` だけを行う。INBOX全体の差分同期
    /// (listMailboxes・溜まった新着全件の取得・Drafts 同期) を一切伴わない
    /// ので、新着が何百通溜まっていても所要時間は接続確立+1往復のまま。
    ///
    /// `false` を返して全体同期へフォールバックするのは:
    /// - INBOXのメールボックス行がまだローカルに無い (初回同期前) —
    ///   listMailboxes からやり直す必要がある。
    /// - `SELECT` が返した uidValidity がローカル記録と不一致 — UIDが全て
    ///   振り直されており、`(mailboxId, uid)` キーでの単発 upsert は別の
    ///   メールを上書きしうるため、uidValidity 変化を正しく処理する
    ///   `MailboxSyncer.incrementalSync` に任せる。
    /// - 対象UIDの envelope がサーバーに無い (既に移動/削除、または
    ///   `uidNext - 1` 推測が外れた) — 全体同期後の再照合に望みを残す。
    /// - 接続・fetch・DB書き込みのいずれかが失敗。
    private static func fetchTargetEnvelopeDirectly(
        account: AccountRecord,
        uidNext: Int,
        database: AppDatabase,
        auth: MailAuth,
        sessionFactory: @Sendable (IMAPConfig) -> any IMAPSessionProtocol
    ) async -> Bool {
        guard let mailbox = try? await MailboxRoleResolver.mailbox(role: .inbox, accountId: account.id, database: database),
              let mailboxId = mailbox.id
        else { return false }

        let uid = UInt32(max(uidNext - 1, 1))
        let session = sessionFactory(account.imapConfig)
        do {
            try await session.connect(auth: auth)
        } catch {
            return false
        }
        defer {
            let session = session
            Task { await session.disconnect() }
        }

        guard let status = try? await session.select(mailbox.path),
              Int64(status.uidValidity) == mailbox.uidValidity
        else { return false }

        guard let envelope = try? await session.fetchEnvelopes(
            mailboxPath: mailbox.path, uids: UIDRange(lowerBound: uid, upperBound: uid), batchSize: 1
        ).first(where: { $0.uid == uid }) else { return false }

        let accountId = account.id
        do {
            try await database.dbWriter.write { db in
                try EnvelopePersister.upsert(envelope: envelope, mailboxId: mailboxId, accountId: accountId, db: db)
            }
        } catch {
            return false
        }
        return true
    }

    /// 通知の default action (本体タップ) 向け: `execute`と同じ `uidNext →
    /// uid = max(uidNext - 1, 1)` の推測でINBOXの対象メッセージを特定し、
    /// 既にローカル同期済みならその `threadId`/`id` を返す (書き込みなし、
    /// `OpQueue`への enqueue もしない)。未同期の場合は `nil` — 呼び出し側は
    /// `fetchAndResolveOpenTarget`経由なら優先同期後に再試行、そうでなけ
    /// れば遷移を諦めて通常の起動画面 (統合受信トレイ) にフォールバックする。
    public static func resolveOpenTarget(
        accountId: String,
        uidNext: Int,
        database: AppDatabase
    ) async -> (threadId: Int64, messageId: Int64)? {
        guard let mailbox = try? await MailboxRoleResolver.mailbox(role: .inbox, accountId: accountId, database: database),
              let mailboxId = mailbox.id
        else { return nil }

        let uid = UInt32(max(uidNext - 1, 1))
        return try? await database.dbWriter.read { db in
            guard let message = try MessageRecord
                .filter(Column("mailboxId") == mailboxId)
                .filter(Column("uid") == Int64(uid))
                .fetchOne(db),
                let threadId = message.threadId,
                let messageId = message.id
            else { return nil }
            return (threadId, messageId)
        }
    }

    /// The local-DB half of `execute`, run inside a single write
    /// transaction: locates a local `MessageRecord` at `(mailbox.id, uid)`
    /// and, if found, applies `action` through the same shared logic swipe
    /// actions use (`MessagePinReadState`/`MessageRemoval`); otherwise
    /// enqueues the equivalent absolute `OpQueue` operation directly against
    /// the `(mailboxId, uid)` pair, since there's no local row to update.
    /// Returns whether anything was actually applied/enqueued — `false`
    /// lets `execute` skip the best-effort replay attempt entirely when
    /// there was nothing to replay (e.g. an `.archive` on a pinned thread
    /// that `MessageRemoval.ArchiveGuardError.pinned` silently rejected).
    private static func apply(
        action: PushNotificationAction,
        accountId: String,
        mailbox: MailboxRecord,
        uid: UInt32,
        db: Database
    ) throws -> Bool {
        guard let mailboxId = mailbox.id else { return false }

        if let message = try MessageRecord
            .filter(Column("mailboxId") == mailboxId)
            .filter(Column("uid") == Int64(uid))
            .fetchOne(db) {
            guard let threadId = message.threadId else { return false }
            switch action {
            case .markRead:
                try MessagePinReadState.applyReadState(
                    markingRead: true, messages: [message], threadId: threadId, accountId: accountId, db: db
                )
                return true
            case .archive:
                guard let thread = try ThreadRecord.fetchOne(db, key: threadId) else { return false }
                let summary = try ThreadQuery.summaries(forThreads: [thread], db: db).first
                guard let summary else { return false }
                do {
                    let snapshot = try MessageRemoval.commit(.archive, summary: summary, accountId: accountId, db: db)
                    return snapshot != nil
                } catch is MessageRemoval.ArchiveGuardError {
                    // Pinned — silently do nothing (`MessageRemoval
                    // .ArchiveGuardError`'s doc comment: no UI here to
                    // surface "can't archive a pinned thread" to).
                    return false
                }
            }
        }

        // No local copy synced yet: enqueue the equivalent absolute op
        // directly against `(mailboxId, uid)` — the next normal sync
        // discovers the message row itself.
        switch action {
        case .markRead:
            // `op: .add` (IMAP `+FLAGS`), not the default `.replace` — there
            // is no local message row here to know the message's *other*
            // flags from, so a `.replace` would clobber server-side state
            // (e.g. `\Answered`/`\Flagged`) this app never learned about.
            // See `SetFlagsOpPayload`'s doc comment.
            try OpQueue.enqueueSetFlags(
                accountId: accountId, mailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                uids: [uid], flags: .seen, op: .add, db: db
            )
        case .archive:
            try OpQueue.enqueueArchive(
                accountId: accountId, sourceMailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                uids: [uid], db: db
            )
        }
        return true
    }
}
