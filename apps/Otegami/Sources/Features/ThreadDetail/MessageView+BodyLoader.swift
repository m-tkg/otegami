import Foundation
import SwiftUI
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import GRDB
import OtegamiTranslation
import OtegamiTranslationApple
import TranslationEngine

extension MessageView {
    // MARK: - Loading

    /// UITest-only reproduction hook for a real-device bug report: a
    /// `.password` account whose Keychain item genuinely goes missing (not
    /// the M11 "just synced from iCloud, hasn't caught up yet" case) used
    /// to fail body-fetch with an opaque, hardcoded error message and no
    /// account-level banner anywhere — see `AppEnvironment.auth(for:)`'s
    /// `.password` branch and this file's `fetchBodyOverNetwork`/
    /// `fetchAttachmentOverNetwork` doc comments for the actual fixes.
    /// XCUITest can't otherwise force this precondition (there's no UI
    /// action that deletes a Keychain item out from under a working
    /// account), so this mirrors `ComposerView
    /// .attachUITestFixtureIfRequested`'s pattern: a no-op unless a
    /// specific launch-environment flag is set, in which case it deletes
    /// this message's own account's stored password right before `load()`
    /// would otherwise use it — reproducing the exact failure a real
    /// device hit, deterministically, on demand.
    ///
    /// Also resets *this* message's `bodyState`/cached `messageBody` row —
    /// confirmed by an actual test run necessary: `SyncEngine.BodyFetcher
    /// .prefetchRecent` already caches recently-synced messages' bodies in
    /// the background, so a message opened soon after account setup can
    /// already have `bodyState == .fetched` by the time this test taps it,
    /// which makes `load()` take the "read straight from the local
    /// `messageBody` row" branch and never call `fetchBodyOverNetwork`/
    /// `auth(for:)` again at all — the credential deletion above would
    /// otherwise go unnoticed, not because the bug is fixed but because
    /// this particular message never re-authenticates in the first place.
    private func deleteCredentialIfUITestRequested() async {
        guard ProcessInfo.processInfo.environment["OTEGAMI_UITEST_DELETE_CREDENTIAL"] == "1" else { return }
        try? environment.credentialStore.deletePassword(forAccountId: accountId)
        let messageId = messageId
        try? await environment.database.dbWriter.write { db in
            guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return }
            record.bodyState = .notFetched
            try record.update(db)
            try MessageBodyRecord.deleteOne(db, key: messageId)
        }
    }

    func load() async {
        errorMessage = nil
        bodyRecord = nil
        message = nil
        mailboxPath = nil
        isArchived = false
        attachments = []
        attachmentErrorMessages = [:]
        previewURL = nil
        manualPreferPlainText = nil
        calendarInviteLoader.reset()
        resetTranslationState()
        resetSummaryState()
        // Task #59: hides both floating buttons immediately while this
        // message (re-)loads — `syncAIFeaturesState()`'s `message != nil`
        // guard is what actually does that; every exit path below that sets
        // a real `message` calls this again once `aiFeaturesEnabled`/
        // `shouldShowTranslationBar` have something meaningful to read.
        syncAIFeaturesState()
        await deleteCredentialIfUITestRequested()

        guard let loadedMessage = try? await environment.database.dbWriter.read({ db in
            try MessageRecord.fetchOne(db, key: messageId)
        }) else {
            errorMessage = "メッセージが見つかりません。"
            return
        }
        message = loadedMessage
        mailboxPath = try? await environment.database.dbWriter.read { db in
            try MailboxRecord.fetchOne(db, key: loadedMessage.mailboxId)?.path
        }
        isArchived = (try? await environment.database.dbWriter.read { db in
            try ThreadQuery.isMessageArchived(messageId: messageId, db: db)
        }) ?? false
        attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []

        // 2026-07-30 (実機フィードバック: HTML本文の quoted-printable
        // ソフト改行消化漏れ修正 — `MailCoreIMAPSession+Mapping.swift`の
        // `html(from:)` — 後も、同じメールでまだ翻訳が失敗した): その修正は
        // **新規フェッチにしか効かない**。既存の`messageBody`行は修正前の
        // 壊れたhtmlをそのまま保持している (Task #134と同じ制約) —
        // `renderVersion`が現行コードの版数と一致しない行は「本文キャッシュ
        // 未取得」と同等に扱い、このメッセージを開いた今このタイミングで
        // だけ (=遅延的に、一括再取得はせず) 下の`fetchBodyOverNetwork`へ
        // 通す。`MessageBodyRecord.currentRenderVersion`のdoc comment参照。
        if loadedMessage.bodyState == .fetched,
           let existing = try? await fetchBodyRecord(messageId: messageId),
           existing.renderVersion == MessageBodyRecord.currentRenderVersion {
            bodyRecord = existing
            let backfilledMessage = await backfillDetectedLanguageIfNeeded(message: loadedMessage, body: existing)
            markAsReadIfNeeded()
            // Task #59: after `backfillDetectedLanguageIfNeeded`, not
            // before — `shouldShowTranslationBar` reads `message
            // .detectedLanguage`, which that call may have just filled in.
            syncAIFeaturesState()
            kickoffTranslationIfNeeded(message: backfilledMessage)
            loadCalendarInviteIfNeeded(messageUID: loadedMessage.uid)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetchBodyOverNetwork(message: loadedMessage)
            bodyRecord = try await fetchBodyRecord(messageId: messageId)
            // M2's body fetch also replaces `attachment` rows for this
            // message (`BodyFetcher.fetchBody`) — re-read so a message
            // opened for the first time shows its attachment list too, not
            // just the (empty, pre-fetch) snapshot read above.
            attachments = (try? await fetchAttachmentRecords(messageId: messageId)) ?? []
            // design-phase-3: `SyncEngine.BodyFetcher` also sets
            // `detectedLanguage` as part of this same fetch — `loadedMessage`
            // predates it (read *before* the fetch even started). Task #138
            // dropped the translation *bar*'s own dependency on this field
            // (`shouldShowTranslationBar`'s doc comment), but
            // `kickoffTranslationIfNeeded(message:)` below still gates
            // auto-translate on a *confirmed* `detectedLanguage == "en"`, so
            // the freshly re-read row (not the stale `loadedMessage`) still
            // matters here — a message opened for the first time (the
            // common case: body not fetched yet) would otherwise never
            // auto-translate on its first open.
            let refreshed = (try? await environment.database.dbWriter.read { db in
                try MessageRecord.fetchOne(db, key: messageId)
            }) ?? loadedMessage
            message = refreshed
            markAsReadIfNeeded()
            syncAIFeaturesState()
            kickoffTranslationIfNeeded(message: refreshed)
            loadCalendarInviteIfNeeded(messageUID: refreshed.uid)
        } catch {
            // Offline (or any other network failure): fall back to
            // whatever's already in the local database — a `.fetching`
            // message left mid-flight by a previous attempt can still have
            // no row yet, in which case there's genuinely nothing to show.
            if let existing = try? await fetchBodyRecord(messageId: messageId) {
                bodyRecord = existing
                markAsReadIfNeeded()
                syncAIFeaturesState()
                kickoffTranslationIfNeeded(message: loadedMessage)
                loadCalendarInviteIfNeeded(messageUID: loadedMessage.uid)
            } else {
                errorMessage = await missingCredentialAwareErrorMessage(prefix: "本文の取得に失敗しました", underlyingError: error)
            }
        }
    }

    /// Task #147 (実機報告「本文の後着で要約/翻訳ボタンが有効化されない」):
    /// `load()`は開いた時点の一回きりの取得で完結する — その後にローカル
    /// DBへ届いた本文 (`SyncEngine`のバックグラウンドプリフェッチが書き
    /// 込むケース、または`load()`自身の`fetchBodyOverNetwork`と競合して
    /// いた別経路が後から完了するケース) を`load()`自身は二度と観測しない
    /// ため、`bodyRecord`が`nil`のまま`syncAIFeaturesState()`が再実行されず
    /// 要約/翻訳ボタンがアプリ再起動まで有効化されなかった。
    ///
    /// `messageBody`行への`ValueObservation`を張って、この`MessageView`が
    /// 画面上にある間 (`.task(id: messageId)`— `ThreadDetailView`のアコー
    /// ディオンで折りたたまれれば`load()`と一緒に破棄される、#136のアコー
    /// ディオンとの整合) ずっと監視し続ける。`CalendarInviteLoader`(#94) が
    /// 選んだ「独立した`@Observable`クラス、view lifecycle 非依存」という
    /// 形までは踏襲していない — こちらは`bodyRecord`という既存の`@State`
    /// (と、それに連動する`content`の表示切り替え・`syncAIFeaturesState()`
    /// 等の既存メソッド群) をそのまま使い回す方が、新しい並行の状態保持先
    /// を作るより小さな変更で済むため。「届いた値を実際に反映する価値が
    /// あるか」の判定だけは`MessageBodyObservationGate`(`SyncEngine`) に
    /// 切り出してあり、SwiftUIのview lifecycleから独立してテストできる —
    /// `MessageReadMarker`(#96) と同じ「app targetのprivateメソッドから
    /// 純粋ロジックだけ`SyncEngine`へ抜き出す」方針。
    func observeBodyRecordChanges() async {
        let observation = ValueObservation.tracking { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
        do {
            for try await fetched in observation.values(in: environment.database.dbWriter) {
                await applyObservedBodyRecordIfNeeded(fetched)
            }
        } catch {
            // ベストエフォート — この監視自体が失敗しても`load()`が既に
            // 表示している内容 (取得済み本文、または「取得中」/エラー) は
            // そのまま残る。
        }
    }

    /// `observeBodyRecordChanges()`の1配信ごとの反映 — `MessageBodyObservationGate
    /// .shouldApply(current:incoming:)`が`false`を返す間 (本文行がまだ無い、
    /// または前回と実質同じ内容の再配信) は何もしない。`true`のときだけ
    /// `bodyRecord`を更新し、`load()`が「本文がその場で取得できた」ときに
    /// 辿るのと同じ後段パイプライン (言語検出の補完・既読化・AI機能ボタンの
    /// 状態同期・自動翻訳キックオフ) を再実行する — いずれも既存の冪等な
    /// ガード付きメソッド (`markSeen`の「既に`\Seen`か」、`requestTranslation`
    /// の「`translateTask == nil`か」等) なので、`load()`自身の初回反映と
    /// このタイミングが重なっても二重の副作用にはならない。
    private func applyObservedBodyRecordIfNeeded(_ fetched: MessageBodyRecord?) async {
        guard MessageBodyObservationGate.shouldApply(current: bodyRecord, incoming: fetched) else { return }
        guard let fetched else { return }
        bodyRecord = fetched
        // Task #64 (実機報告「まだ読み込み中のように見える」)と同じ理由 —
        // 本文がこの観測経由で埋まったなら、`load()`のネットワーク取得が
        // 失敗して立てた古い`errorMessage`はもう実情に合わない。
        errorMessage = nil
        guard let currentMessage = message else {
            // `message`(メタデータ行)自体がまだ読めていない極端な競合状態
            // — `syncAIFeaturesState()`は`bodyRecord`の更新だけでも安全に
            // 呼べる (`hasSettledBodyState`のガード参照) が、`kickoffTranslationIfNeeded`
            // 等`MessageRecord`が要る後段はここでは呼べないので、次に`load()`
            // か別の配信が`message`を埋めるまで待つ。
            syncAIFeaturesState()
            return
        }
        // Task #147のスコープは要約/翻訳ボタンの有効化 + 本文表示の更新まで
        // — `attachments`/カレンダー招待カードはこの観測 (`messageBody`
        // テーブルのみ追跡) では更新されない別状態のままなので、
        // `loadCalendarInviteIfNeeded`はここでは呼ばない (呼んでも古い
        // (空の可能性がある)`attachments`しか見えず実質no-opなだけで、
        // 「動いているように見えて実は何もしていない」誤解を生むだけ)。
        let backfilled = await backfillDetectedLanguageIfNeeded(message: currentMessage, body: fetched)
        markAsReadIfNeeded()
        syncAIFeaturesState()
        kickoffTranslationIfNeeded(message: backfilled)
    }

    /// Task #94: kicks off (or logs the absence of) the calendar-invite
    /// card's load, using whichever `attachments` this call happens after —
    /// every call site above re-reads `attachments` from the database
    /// immediately before calling this, so `calendarInviteAttachment`
    /// (computed from that same `@State`) reflects the message's current,
    /// real attachment rows. `CalendarInviteLoader.load` itself is a no-op
    /// if this attachment is already loaded/loading, so calling this more
    /// than once per message (offline fallback + a later successful retry,
    /// for instance) is harmless.
    private func loadCalendarInviteIfNeeded(messageUID: Int64) {
        let candidate = calendarInviteAttachment
        CalendarInviteLoader.logRecognition(messageId: messageId, attachments: attachments, primary: candidate)
        guard let candidate, let mailboxPath else { return }
        calendarInviteLoader.load(
            attachment: candidate,
            messageId: messageId,
            messageUID: messageUID,
            mailboxPath: mailboxPath,
            accountId: accountId,
            environment: environment
        )
    }

    /// Real-device bug report (`docs/icloud-sync.md`'s "重複挿入バグ"):
    /// opening a message on a cloud-inserted `.password` account with no
    /// Keychain credential on this device yet used to fail with an opaque
    /// `"本文の取得に失敗しました: authenticationFailed: missingCredential"` — every
    /// word of which is either meaningless to a non-technical user or, in
    /// the case of "authenticationFailed", actively misleading (it reads
    /// like a wrong password, not "this device doesn't have a password to
    /// try at all"). `AppEnvironment.auth(for:)` already flips
    /// `AccountRecord.needsReauth` the moment this happens (both for this
    /// M11 case and for a `.password` account whose Keychain item genuinely
    /// went missing), so this re-reads the account row fresh (not the
    /// `environment.accounts` cache, whose `ValueObservation` update isn't
    /// guaranteed to have landed by the instant this catch block runs) and
    /// swaps in an actionable message — the same "資格情報を待っています" /
    /// "再接続" condition `AccountsSettingsView` already shows a banner and
    /// button for — instead of leaking the raw error. Falls back to the raw
    /// error for every other failure (offline, server error, ...), where
    /// there's no single fix to point at.
    func missingCredentialAwareErrorMessage(prefix: String, underlyingError: Error) async -> String {
        let refreshedAccount = try? await environment.database.dbWriter.read { db in
            try AccountRecord.fetchOne(db, key: accountId)
        }
        guard refreshedAccount?.needsReauth == true, refreshedAccount?.authType == .password else {
            return "\(prefix): \(underlyingError)"
        }
        return "\(prefix): この端末にはこのアカウントの資格情報がありません。設定 → アカウントの「再接続」からパスワードを確認してください。"
    }

    func fetchBodyRecord(messageId: Int64) async throws -> MessageBodyRecord? {
        try await environment.database.dbWriter.read { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
    }

    private func fetchAttachmentRecords(messageId: Int64) async throws -> [AttachmentRecord] {
        try await environment.database.dbWriter.read { db in
            try AttachmentRecord.filter(Column("messageId") == messageId).order(Column("id")).fetchAll(db)
        }
    }

    func fetchBodyOverNetwork(message: MessageRecord) async throws {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        let auth: MailAuth
        do {
            auth = try await environment.auth(for: account)
        } catch {
            // Bug fix: this used to discard whatever `auth(for:)` actually
            // threw and replace it with a fixed "資格情報が見つかりません",
            // which meant a Keychain read failure, an expired OAuth
            // refresh token, and "no GOOGLE_OAUTH_CLIENT_ID configured"
            // all showed the exact same message — indistinguishable from
            // the user-visible side, and useless for diagnosing a real
            // report against it. Preserving `error`'s own description
            // (`AuthResolutionError`/`TokenStoreError` are both named
            // enums, and `KeychainCredentialStore.KeychainError` already
            // has a real `CustomStringConvertible` description) keeps this
            // still wrapped as a `MailTransportError.authenticationFailed`
            // (so existing call sites that only branch on the error *case*
            // keep working) while no longer hiding *why*.
            throw MailTransportError.authenticationFailed(underlyingDescription: "\(error)")
        }
        guard let mailboxPath else {
            throw MailTransportError.mailboxNotFound(path: "")
        }
        try await environment.syncCoordinator.fetchBody(
            for: message,
            mailboxPath: mailboxPath,
            account: account,
            auth: auth
        )
    }

    /// Reflects `\Seen` in the local database immediately, then enqueues
    /// the absolute flag state for `OpQueueProcessor` to mirror to the
    /// server (M3) and makes a best-effort replay attempt right away —
    /// harmless if offline, the op just waits for the next successful
    /// connection (foreground IDLE reconnect, pull-to-refresh, ...).
    ///
    /// Task #96: the actual DB write/enqueue now lives in `SyncEngine
    /// .MessageReadMarker.markSeen` (testable without SwiftUI at all) —
    /// this just wraps it in the same "own unstructured `Task { }`, best-
    /// effort replay after" shape as before. Deliberately reads
    /// `messageId`/`accountId` (the view's `let` constants, always
    /// available) rather than `self.message` (a `@State` that may still be
    /// `nil` the instant `.onAppear` fires, since `.onAppear` and `.task`
    /// aren't ordered against each other) — every call site, including the
    /// ones still inside `load()`'s post-body-fetch branches, is safely
    /// idempotent thanks to `markSeen`'s own "already `\Seen`?" guard.
    func markAsReadIfNeeded() {
        let messageId = messageId
        let accountId = accountId
        Task {
            do {
                let didMark = try await environment.database.dbWriter.write { db in
                    try MessageReadMarker.markSeen(messageId: messageId, accountId: accountId, db: db)
                }
                guard didMark else { return }
                guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let auth = try? await environment.auth(for: account) else { return }
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort: the local flag update simply doesn't happen
                // if this fails.
            }
        }
    }

    // MARK: - Language detection backfill (design-phase-3 follow-up)

    /// Opportunistically fills in (or corrects) `message.detectedLanguage`
    /// for a message whose body was already fetched (so no network call
    /// needed here — just local text already in `body`). Real-device report
    /// (design-phase-3 follow-up): the translation bar/button never appeared
    /// for genuinely English mail, traced to exactly this —
    /// `SyncEngine.BodyFetcher` only sets `detectedLanguage` at the moment
    /// a body is *first* fetched, and never re-runs for a message whose
    /// `bodyState` is already `.fetched` (`prefetchRecent`'s `notFetched`
    /// filter), so any message fetched before this field was added (or
    /// whose short/ambiguous body legitimately didn't yield a confident
    /// guess at the time) stayed `nil` forever. This runs once per message
    /// open, using the same `MessageLanguageDetector`
    /// `SyncEngine.BodyFetcher` itself uses, and persists the result so
    /// later opens (and list-level features keyed on `detectedLanguage`,
    /// e.g. `SearchFilterOption`) see the same backfilled value.
    ///
    /// Task #128 (実機報告「英語メールなのに翻訳ボタンが押せない」— Okta の
    /// サインオン通知メール, hypothesis (2)): this used to be a strict no-op
    /// whenever `detectedLanguage` was already non-`nil`, on the reasoning
    /// that "a confidently-non-English message shouldn't be re-guessed every
    /// time it's opened". That reasoning has a gap: `detectedLanguage` being
    /// non-`nil` only ever meant *some* past detection ran and committed a
    /// value — not that the value was actually correct. A build that stored
    /// a wrong non-`nil` guess (e.g. an early version whose sample text
    /// wasn't yet cleaned the same way `resolvePlainText`/this method's own
    /// `sample` below are — a stray HTML/CSS-heavy sample can plausibly
    /// throw `NLLanguageRecognizer` off) would leave that wrong value stuck
    /// forever, indistinguishable from a *correctly* detected non-English
    /// message — exactly the same permanently-hidden-button symptom as the
    /// `nil` case this method already existed to fix, just with a non-`nil`
    /// value instead of a missing one. Now always re-detects from the
    /// current body text and only writes back when the fresh result
    /// actually *disagrees* with what's stored — a no-op (same `update`
    /// skip, same "don't hammer the DB every open") for the overwhelmingly
    /// common case where the stored value already matches, and self-healing
    /// for the mismatched case without needing a full re-sync or app
    /// reinstall.
    ///
    /// Task #203 (実機フィードバック「HTMLの構造が壊れているメールで言語
    /// 判定に失敗する」— Okta 通知メール, 「翻訳元の言語を判定できません
    /// でした」): the manual plainText-else-HTML choice this used to make
    /// only ever tried *one* candidate — if that one candidate's text was
    /// markup-contaminated (or simply not confidently identifiable), there
    /// was no retry even though the other candidate often exists and is
    /// clean. Now delegates to `MessageLanguageDetector.detectWithFallback`,
    /// which tries `plainText` first and falls back to an HTML extraction
    /// only when needed (see that function's doc comment for the ordering
    /// rationale and the markup-noise pre-filter it applies before ever
    /// calling the recognizer). Every call here is also logged to
    /// `environment.translationDiagnostics` (`recordLanguageDetectionDiagnostics`
    /// below) — since this runs on every message open, opening the
    /// affected message and then checking 設定→翻訳の診断 is enough to see
    /// which candidate (if either) worked, without needing the real eml.
    private func backfillDetectedLanguageIfNeeded(message: MessageRecord, body: MessageBodyRecord) async -> MessageRecord {
        guard message.id != nil else { return message }

        let outcome = MessageLanguageDetector.detectWithFallback(plainText: body.plainText, html: body.html)
        recordLanguageDetectionDiagnostics(body: body, outcome: outcome)

        // A failed re-detection (`outcome == nil`, or the recognizer
        // committing to the same language already stored) never overwrites
        // an existing value — only a confident, *different* result does.
        guard let outcome, outcome.language != message.detectedLanguage else {
            return message
        }

        var updated = message
        updated.detectedLanguage = outcome.language
        let toPersist = updated
        try? await environment.database.dbWriter.write { db in
            try toPersist.update(db)
        }
        self.message = updated
        return updated
    }

    /// Logs which candidate(s) `backfillDetectedLanguageIfNeeded` tried and
    /// which (if any) won, to the same on-device "翻訳の診断" screen the
    /// translate path already logs to (`TranslationDiagnosticsStore`'s doc
    /// comment: no `log collect`/sysdiagnose needed, screenshot-shareable).
    /// F15 (本文非保持) の趣旨どおり `MessageLanguageDetector
    /// .characterClassSummary` の比率のみを渡し、本文そのものは一切渡さない。
    private func recordLanguageDetectionDiagnostics(body: MessageBodyRecord, outcome: MessageLanguageDetector.DetectionOutcome?) {
        let plainTextSummary = body.plainText.map(MessageLanguageDetector.characterClassSummary)
        let htmlSummary = body.html.map { HTMLTextExtractor.plainText(fromHTML: $0) }.map(MessageLanguageDetector.characterClassSummary)
        let recordedOutcome: TranslationDiagnosticsStore.LanguageDetectionAttempt.Outcome
        if let outcome {
            recordedOutcome = .detected(language: outcome.language, source: outcome.source)
        } else {
            recordedOutcome = .undetected
        }
        environment.translationDiagnostics.recordLanguageDetection(
            TranslationDiagnosticsStore.LanguageDetectionAttempt(
                plainTextSummary: plainTextSummary,
                htmlSummary: htmlSummary,
                outcome: recordedOutcome
            )
        )
    }
}
