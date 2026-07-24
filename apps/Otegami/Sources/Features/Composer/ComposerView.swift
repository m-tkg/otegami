import SwiftUI
import GRDB
import MailTransport
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Compose/reply UI (M5, plan: "作成・返信"). iOS presents this as a sheet;
/// macOS opens it in its own window (`WindowGroup(id: "composer")` in
/// `OtegamiApp`) — both share this same view, driven by the same
/// `ComposerLaunchPayload`.
///
/// To/Cc are plain comma-separated text fields (plan: "トークン化はlater") —
/// `parseAddresses(_:)` below turns `"Name <addr>, addr2"` back into
/// `[EmailAddress]` at send time; reply prefill goes the other direction via
/// `EmailAddress.description`.
struct ComposerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let payload: ComposerLaunchPayload

    @State private var selectedAccountId: String?
    @State private var toText = ""
    @State private var ccText = ""
    @State private var subject = ""
    @State private var bodyText = ""

    // Resolved once, from the original message, when `payload.kind` is
    // `.reply` — carried straight into the enqueued `OutboxMessageRecord`
    // at send time without re-deriving them.
    @State private var inReplyToMessageId: String?
    @State private var references: [String] = []

    @State private var isSending = false
    @State private var isLoadingReplyContext = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("差出人") {
                    Picker("From", selection: $selectedAccountId) {
                        ForEach(environment.accounts) { account in
                            Text("\(account.displayName) <\(account.email)>")
                                .tag(Optional(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("composer.fromPicker")
                }

                Section("宛先") {
                    TextField("To (カンマ区切り)", text: $toText)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("composer.to")
                    TextField("Cc (カンマ区切り)", text: $ccText)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("composer.cc")
                }

                Section("件名") {
                    TextField("件名", text: $subject)
                        .accessibilityIdentifier("composer.subject")
                }

                Section("本文") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 240)
                        .accessibilityIdentifier("composer.body")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("composer.errorMessage")
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("composer.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("送信")
                        }
                    }
                    .accessibilityIdentifier("composer.sendButton")
                    .disabled(isSending || isLoadingReplyContext || !isFormValid)
                }
            }
        }
        .accessibilityIdentifier("composer.sheet")
        .task { await prepare() }
    }

    private var navigationTitle: String {
        switch payload.kind {
        case .new: "新規作成"
        case .reply(_, let replyAll): replyAll ? "全員に返信" : "返信"
        }
    }

    private var isFormValid: Bool {
        selectedAccountId != nil && !toText.trimmingCharacters(in: .whitespaces).isEmpty && !subject.isEmpty
    }

    // MARK: - Setup

    private func prepare() async {
        if selectedAccountId == nil {
            selectedAccountId = environment.accounts.first?.id
        }
        guard case .reply(let originalMessageId, let replyAll) = payload.kind else { return }
        isLoadingReplyContext = true
        defer { isLoadingReplyContext = false }
        await prefillReply(toOriginalMessageId: originalMessageId, replyAll: replyAll)
    }

    private func prefillReply(toOriginalMessageId originalMessageId: Int64, replyAll: Bool) async {
        struct ReplyContext {
            var message: MessageRecord
            var accountId: String
            var referenceValues: [String]
            var bodyRecord: MessageBodyRecord?
        }

        let context: ReplyContext? = try? await environment.database.dbWriter.read { db -> ReplyContext? in
            guard let message = try MessageRecord.fetchOne(db, key: originalMessageId) else { return nil }
            guard let mailbox = try MailboxRecord.fetchOne(db, key: message.mailboxId) else { return nil }
            let referenceValues = try MessageReferenceRecord
                .filter(Column("messageId") == originalMessageId)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.referenceValue)
            let bodyRecord = try MessageBodyRecord.fetchOne(db, key: originalMessageId)
            return ReplyContext(message: message, accountId: mailbox.accountId, referenceValues: referenceValues, bodyRecord: bodyRecord)
        }
        guard let context else { return }

        selectedAccountId = context.accountId
        subject = "Re: " + SubjectNormalizer.normalize(context.message.subject ?? "")
        inReplyToMessageId = context.message.messageId

        var chain = context.referenceValues
        if let ownMessageId = context.message.messageId, chain.last != ownMessageId {
            chain.append(ownMessageId)
        }
        references = chain

        let ownAddress = environment.accounts.first { $0.id == context.accountId }?.email.lowercased()
        if replyAll {
            var to = context.message.fromAddresses
            to.append(contentsOf: context.message.toAddresses.filter { $0.address.lowercased() != ownAddress })
            toText = to.map(\.description).joined(separator: ", ")
            ccText = context.message.ccAddresses
                .filter { $0.address.lowercased() != ownAddress }
                .map(\.description)
                .joined(separator: ", ")
        } else {
            toText = context.message.fromAddresses.map(\.description).joined(separator: ", ")
        }

        bodyText = "\n\n" + quotedBody(from: context.bodyRecord)
    }

    /// Plain-text quoting (plan: "本文に`> `引用"). Falls back to
    /// `HTMLTextExtractor` for an HTML-only original body — the same
    /// dependency-free extractor `SyncEngine.BodyFetcher` already uses for
    /// its own plain-text derivation, so a reply never needs a WKWebView
    /// just to quote text.
    private func quotedBody(from bodyRecord: MessageBodyRecord?) -> String {
        let source: String
        if let plainText = bodyRecord?.plainText, !plainText.isEmpty {
            source = plainText
        } else if let html = bodyRecord?.html, !html.isEmpty {
            source = HTMLTextExtractor.plainText(fromHTML: html)
        } else {
            return ""
        }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    // MARK: - Send

    private func send() async {
        guard let accountId = selectedAccountId,
              let account = environment.accounts.first(where: { $0.id == accountId })
        else { return }

        let toAddresses = Self.parseAddresses(toText)
        guard !toAddresses.isEmpty else {
            errorMessage = "宛先を入力してください。"
            return
        }
        let ccAddresses = Self.parseAddresses(ccText)

        isSending = true
        defer { isSending = false }

        do {
            try await environment.database.dbWriter.write { db in
                var outbox = OutboxMessageRecord(
                    accountId: accountId,
                    toAddresses: toAddresses,
                    ccAddresses: ccAddresses,
                    subject: subject,
                    plainTextBody: bodyText,
                    inReplyToMessageId: inReplyToMessageId,
                    references: references
                )
                try outbox.insert(db)
                guard let outboxId = outbox.id else { return }
                try OpQueue.enqueueSend(accountId: accountId, outboxMessageId: outboxId, db: db)
            }
            dismiss()

            // Best-effort immediate replay, same pattern as
            // MessageView.markAsReadIfNeeded/MessageListView's swipe
            // actions — harmless if offline, the op just waits for the
            // next successful connection.
            if let auth = try? await environment.auth(for: account) {
                Task { _ = try? await environment.syncCoordinator.replayOpQueue(for: account, auth: auth) }
            }
        } catch {
            errorMessage = "送信の準備に失敗しました: \(error)"
        }
    }

    /// Parses a comma-separated address list, accepting either a bare
    /// address (`"a@example.com"`) or a `"Name <a@example.com>"` form —
    /// matches what `EmailAddress.description` (used to prefill a reply's
    /// To/Cc fields) produces, so round-tripping through this field doesn't
    /// lose the display name.
    static func parseAddresses(_ text: String) -> [EmailAddress] {
        text.split(separator: ",").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
                let name = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespaces)
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { return nil }
                return EmailAddress(name: name.isEmpty ? nil : name, address: address)
            }
            return EmailAddress(address: trimmed)
        }
    }
}

private extension View {
    @ViewBuilder
    func textFieldAutocapitalizationNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
