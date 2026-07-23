import Foundation
import SwiftUI
import OtegamiCore
import OtegamiStore
import SyncEngine
import MailTransport
import GRDB

/// Single-message reading view (M2's "ThreadDetail"; real multi-message
/// thread collapsing lands in M4). Shows the header, then the body: if
/// `message.bodyState` is already `.fetched`, reads straight from
/// `messageBody` (works offline); otherwise fetches it over IMAP via
/// `SyncCoordinator.fetchBody`, showing a spinner meanwhile.
///
/// Takes `messageId` rather than an already-loaded `MessageRecord`: the id
/// is what `MessageListView`'s `List(selection:)` binding (and `RootView`'s
/// "last opened message" restoration) naturally deal in, and re-reading
/// the row here means this view always reflects the current database state
/// (e.g. a flag change from another source) rather than a snapshot passed
/// in at selection time.
struct MessageView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Which account to authenticate against for a lazy body fetch —
    /// derived from `message.mailboxId` for everything else (M4: a message
    /// embedded in `ThreadDetailView` doesn't necessarily belong to
    /// whichever mailbox the sidebar has selected, e.g. the unified inbox
    /// or a thread that spans mailboxes), so this is the one piece of
    /// context a caller must still supply.
    let accountId: String
    let messageId: Int64

    @State private var message: MessageRecord?
    @State private var bodyRecord: MessageBodyRecord?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message {
                header(for: message)
                    .padding()
                Divider()
            }
            // HTML bodies scroll internally (inside `HTMLMessageView`'s own
            // `WKWebView`) and need the remaining space handed to them
            // directly; plain-text bodies get their own `ScrollView` below
            // instead of wrapping the header in one too, so a long HTML
            // message never ends up nested inside two independent
            // scrollers.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("messageDetail.scrollView")
        .navigationTitle(displaySubject)
        .task(id: messageId) { await load() }
    }

    private var displaySubject: String {
        message?.subject?.isEmpty == false ? message!.subject! : "(件名なし)"
    }

    private func header(for message: MessageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displaySubject)
                .font(.title2)
                .bold()
                .accessibilityIdentifier("messageDetail.subject")
            Text(addressListText(message.fromAddresses, prefix: "From"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("messageDetail.from")
            if !message.toAddresses.isEmpty {
                Text(addressListText(message.toAddresses, prefix: "To"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("messageDetail.to")
            }
            Text(message.date ?? message.internalDate, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("messageDetail.date")
        }
    }

    private func addressListText(_ addresses: [EmailAddress], prefix: String) -> String {
        let formatted = addresses.map { $0.name?.isEmpty == false ? "\($0.name!) <\($0.address)>" : $0.address }
        return "\(prefix): \(formatted.joined(separator: ", "))"
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView("本文を取得しています…")
                        .accessibilityIdentifier("messageDetail.loadingIndicator")
                    Spacer()
                }
                Spacer()
            }
        } else if let bodyRecord {
            if let html = bodyRecord.html, !html.isEmpty {
                HTMLMessageView(html: html)
                    .accessibilityIdentifier("messageDetail.htmlBody")
            } else if let plainText = bodyRecord.plainText, !plainText.isEmpty {
                ScrollView {
                    linkifiedText(plainText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("messageDetail.plainTextBody")
                }
            } else {
                Text("本文はありません。")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding()
                .accessibilityIdentifier("messageDetail.errorMessage")
        }
    }

    // MARK: - Loading

    private func load() async {
        errorMessage = nil
        bodyRecord = nil
        message = nil

        guard let loadedMessage = try? await environment.database.dbWriter.read({ db in
            try MessageRecord.fetchOne(db, key: messageId)
        }) else {
            errorMessage = "メッセージが見つかりません。"
            return
        }
        message = loadedMessage

        if loadedMessage.bodyState == .fetched, let existing = try? await fetchBodyRecord(messageId: messageId) {
            bodyRecord = existing
            markAsReadIfNeeded()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await fetchBodyOverNetwork(message: loadedMessage)
            bodyRecord = try await fetchBodyRecord(messageId: messageId)
            markAsReadIfNeeded()
        } catch {
            // Offline (or any other network failure): fall back to
            // whatever's already in the local database — a `.fetching`
            // message left mid-flight by a previous attempt can still have
            // no row yet, in which case there's genuinely nothing to show.
            if let existing = try? await fetchBodyRecord(messageId: messageId) {
                bodyRecord = existing
                markAsReadIfNeeded()
            } else {
                errorMessage = "本文の取得に失敗しました: \(error)"
            }
        }
    }

    private func fetchBodyRecord(messageId: Int64) async throws -> MessageBodyRecord? {
        try await environment.database.dbWriter.read { db in
            try MessageBodyRecord.fetchOne(db, key: messageId)
        }
    }

    private func fetchBodyOverNetwork(message: MessageRecord) async throws {
        guard let account = environment.accounts.first(where: { $0.id == accountId }) else {
            throw MailTransportError.notConnected
        }
        guard let password = try environment.credentialStore.password(forAccountId: account.id) else {
            throw MailTransportError.authenticationFailed(underlyingDescription: "資格情報が見つかりません")
        }
        guard let mailbox = try await environment.database.dbWriter.read({ db in
            try MailboxRecord.fetchOne(db, key: message.mailboxId)
        }) else {
            throw MailTransportError.mailboxNotFound(path: "")
        }
        try await environment.syncCoordinator.fetchBody(
            for: message,
            mailboxPath: mailbox.path,
            account: account,
            auth: .password(username: account.imapUsername, password: password)
        )
    }

    /// Reflects `\Seen` in the local database immediately, then enqueues
    /// the absolute flag state for `OpQueueProcessor` to mirror to the
    /// server (M3) and makes a best-effort replay attempt right away —
    /// harmless if offline, the op just waits for the next successful
    /// connection (foreground IDLE reconnect, pull-to-refresh, ...).
    private func markAsReadIfNeeded() {
        guard let message, !message.flags.contains(.seen) else { return }
        let messageId = messageId
        let accountId = accountId
        let mailboxId = message.mailboxId
        Task {
            do {
                try await environment.database.dbWriter.write { db in
                    guard var record = try MessageRecord.fetchOne(db, key: messageId) else { return }
                    guard !record.flags.contains(.seen) else { return }
                    record.flags.insert(.seen)
                    record.updatedAt = Date()
                    try record.update(db)
                    guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return }
                    try OpQueue.enqueueSetFlags(
                        accountId: accountId, mailboxId: mailboxId, uidValidity: mailbox.uidValidity,
                        uids: [UInt32(record.uid)], flags: record.flags, db: db
                    )
                    if let threadId = record.threadId {
                        try ThreadAssigner.recomputeAggregates(threadId: threadId, db: db)
                    }
                }
                guard let account = environment.accounts.first(where: { $0.id == accountId }) else { return }
                guard let password = try? environment.credentialStore.password(forAccountId: account.id) else { return }
                let auth = MailAuth.password(username: account.imapUsername, password: password)
                _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth)
            } catch {
                // Best-effort: the local flag update simply doesn't happen
                // if this fails.
            }
        }
    }

    // MARK: - Plain-text link detection

    /// Builds a `Text` with any `http(s)://` links in `text` rendered as
    /// tappable links (plan: "SwiftUI Text（等幅でなく通常書体、リンク検出）").
    private func linkifiedText(_ text: String) -> Text {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Text(attributed)
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let attributedRange = Range(stringRange, in: attributed)
            else { continue }
            attributed[attributedRange].link = url
            attributed[attributedRange].underlineStyle = .single
        }
        return Text(attributed)
    }
}
