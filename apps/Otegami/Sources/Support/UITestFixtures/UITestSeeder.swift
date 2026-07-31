import Foundation
import GRDB
import OtegamiCore
import OtegamiStore
import SyncEngine

enum UITestSeeder {
    static func seedIfRequested(db: any DatabaseWriter) -> Int64? {
        var directOpenThreadId: Int64?

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
        // flags' inline, documented, launch-environment-gated pattern. The
        // next sort order is read directly from `db`, keeping this seeder
        // independent from `AppEnvironment` instance methods.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_GMAIL_ACCOUNT"] == "1" {
            let fakeGmailEmail = "uitest-fake@gmail.com"
            let nextSortOrder = ((try? db.read { db in
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
            // `capturedThreadId`'s pattern elsewhere in this file), then
            // copied into `directOpenThreadId` after the database closure.
            var capturedArchivedThreadId: Int64?
            // Gmail 二重ラベルによるスレッド内メッセージ重複バグの検証用
            // (実機報告: 同じメールが INBOX と All Mail の両方に同期され、
            // スレッド詳細画面で二重表示される) — 下で挿入する`inboxThread`
            // (INBOX/All Mail に同じ`gmailMessageId`で重複した2行) を
            // `OTEGAMI_UITEST_OPEN_GMAIL_DUPLICATE_THREAD_DIRECTLY`が立って
            // いれば`capturedArchivedThreadId`と同じ仕組みで直接開く。
            var capturedDuplicateThreadId: Int64?
            try? db.write { db in
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
                capturedDuplicateThreadId = inboxThread.id
            }
            // Task #151 (「アーカイブ済みの可視化」検証): `scripts/
            // verify-screen.sh archived-message-detail`向け — タップ無しで
            // 上の「アーカイブ済みメール (UITest)」を直接開き、
            // `MessageHeaderCompactView`の`ArchivedBadge`が出ることを確認
            // する。`uitestDirectOpenThreadId`の既存の仕組み (`MailScreenView
            // .task`) をそのまま再利用 — 新規の画面遷移コードは不要。
            if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_OPEN_GMAIL_ARCHIVED_MESSAGE_DIRECTLY"] == "1" {
                directOpenThreadId = capturedArchivedThreadId
            } else if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_OPEN_GMAIL_DUPLICATE_THREAD_DIRECTLY"] == "1" {
                directOpenThreadId = capturedDuplicateThreadId
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
            // Declared outside the database closure, then copied into the
            // function's return value after the write completes.
            var capturedDirectOpenThreadId: Int64?
            try? db.write { db in
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
                    messageCount: UITestHTMLFixtures.uitestFakeHTMLMessages.count
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
                // long-press-select, per `docs/verify.md`
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
                // as an ordinary local. After the database write returns,
                // its value is copied into `directOpenThreadId`, which this
                // function returns to `AppEnvironment`.
                for (index, fixture) in UITestHTMLFixtures.uitestFakeHTMLMessages.enumerated() {
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
                        let sizeFiller = index == 0 ? "\n\n\(UITestHTMLFixtures.uitestFakeLargeRawSourceQuotedHistory)" : ""
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
            directOpenThreadId = capturedDirectOpenThreadId
        }

        // Task #162 (実機フィードバック「署名が本文に混ざって編集しづらい」):
        // `scripts/verify-screen.sh composer-signature` insert the fake HTML
        // account above (`OTEGAMI_UITEST_INSERT_FAKE_HTML_MESSAGE`) to
        // populate the Composer's From picker, but that account has no
        // signature of its own — this flag additionally scopes a signature
        // to it and sets it as the account's default (`defaultSignatureId`),
        // so `ComposerView.loadAvailableSignatures()`'s auto-select actually
        // picks it for a brand-new composition (no prior
        // `LastSignatureSettingsStore` entry exists for this fake account
        // either, so the priority chain falls through to exactly this) —
        // the same tap-free scenario can then screenshot the Composer's
        // "署名: <名前>" label *and* its read-only body preview, not just
        // the picker itself, without a real IMAP round trip or any
        // tap-driven Settings navigation to create/select one.
        if ProcessInfo.processInfo.environment["OTEGAMI_UITEST_INSERT_FAKE_SIGNATURE"] == "1" {
            let fakeAccountEmail = "uitest-fake-html@example.com"
            try? db.write { db in
                // Idempotent across repeated `app.launch()`s within the
                // same install — same rationale/guard as the HTML fixture
                // block above.
                guard var fakeAccount = try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) else { return }
                guard try SignatureTemplateRecord.filter(Column("name") == "UITest署名").fetchOne(db) == nil else { return }
                var signature = SignatureTemplateRecord(
                    name: "UITest署名",
                    body: "よろしくお願いいたします。\nUITest 太郎",
                    accountIds: [fakeAccount.id]
                )
                try signature.insert(db)
                fakeAccount.defaultSignatureId = signature.id
                try fakeAccount.update(db)
            }
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
            try? db.write { db in
                // Idempotent across repeated `app.launch()`s within the
                // same install — same rationale/guard as the HTML fixture
                // block above.
                guard try AccountRecord.filter(Column("email") == fakeAccountEmail).fetchOne(db) == nil else { return }
                try fakeAccount.insert(db)
                var mailbox = MailboxRecord(accountId: fakeAccount.id, path: "INBOX", displayPath: "INBOX", role: .inbox, messageCount: 1)
                try mailbox.insert(db)

                let icsText = UITestHTMLFixtures.uitestFakeCalendarInviteICS.replacingOccurrences(of: "\n", with: "\r\n")
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
                    html: UITestHTMLFixtures.uitestFakeCalendarInviteHTML,
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
            directOpenThreadId = capturedThreadId
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
            try? db.write { db in
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
                    plainText: UITestHTMLFixtures.uitestFakeQuotedPlainMessageBody,
                    html: nil,
                    fetchedAt: Date()
                )
                try body.insert(db)
                capturedThreadId = try? ThreadAssigner.assignThread(messageId: message.id!, accountId: fakeAccount.id, db: db)
            }
            directOpenThreadId = capturedThreadId
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
            try? db.write { db in
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
                directOpenThreadId = capturedThreadId
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
            try? db.write { db in
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

        return directOpenThreadId
    }
}
