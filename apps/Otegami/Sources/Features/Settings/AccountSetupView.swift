import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiStore
import SyncEngine

/// Generic IMAP account setup form (plan: "汎用 IMAP 手入力フォーム") — the "その他
/// (IMAP)" option on `AccountTypeSelectionView` (M6; before M6 this was the
/// only account-creation flow, reached directly). Host/port/security/
/// username/password entered by hand; SMTP fields are collected but unused
/// until M5 — kept optional so leaving them blank doesn't block saving.
struct AccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""

    @State private var imapHost = ""
    @State private var imapPortText = "993"
    @State private var imapSecurity: ConnectionSecurityRecord = .tls
    @State private var imapUsername = ""
    @State private var password = ""

    @State private var smtpHost = ""
    @State private var smtpPortText = "587"
    @State private var smtpSecurity: ConnectionSecurityRecord = .startTLS
    @State private var smtpUsername = ""

    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testResultMessage: String?
    @State private var isSaving = false

    // M5: a separate connection test for SMTP (plan: "IMAP と別に") — IMAP
    // and SMTP are frequently different hosts/ports even for the same
    // account, so a single combined test button couldn't tell the user
    // which side actually failed.
    @State private var isTestingSMTP = false
    @State private var smtpTestSucceeded = false
    @State private var smtpTestResultMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("アカウント") {
                    TextField("表示名", text: $displayName)
                        .accessibilityIdentifier("accountSetup.displayName")
                    TextField("メールアドレス", text: $email)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("accountSetup.email")
                        .onChange(of: email) { _, newValue in
                            if imapUsername.isEmpty { imapUsername = newValue }
                        }
                }

                Section("IMAP") {
                    TextField("ホスト", text: $imapHost)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("accountSetup.imapHost")
                    TextField("ポート", text: $imapPortText)
                        .accessibilityIdentifier("accountSetup.imapPort")
                    Picker("接続方式", selection: $imapSecurity) {
                        Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                        Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                        Text("TLS").tag(ConnectionSecurityRecord.tls)
                    }
                    // `.menu` (rather than the Form default, which pushes a
                    // navigation-style picker screen) keeps the interaction
                    // deterministic for XCUITest: tap the row, tap the
                    // option label, done — no extra "back" navigation step.
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("accountSetup.imapSecurity")
                    TextField("ユーザー名", text: $imapUsername)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("accountSetup.imapUsername")
                    SecureField("パスワード", text: $password)
                        .accessibilityIdentifier("accountSetup.password")
                }

                Section("SMTP (送信用。任意 — 未設定の場合は送信できません)") {
                    TextField("ホスト", text: $smtpHost)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("accountSetup.smtpHost")
                    TextField("ポート", text: $smtpPortText)
                        .accessibilityIdentifier("accountSetup.smtpPort")
                    Picker("接続方式", selection: $smtpSecurity) {
                        Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                        Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                        Text("TLS").tag(ConnectionSecurityRecord.tls)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("accountSetup.smtpSecurity")
                    TextField("ユーザー名", text: $smtpUsername)
                        .textFieldAutocapitalizationNone()
                        .accessibilityIdentifier("accountSetup.smtpUsername")
                    // UX fix: a filled-in username used to always trigger
                    // AUTH, which a non-authenticating SMTP server (e.g. the
                    // dev mailstack's Mailpit) would then reject outright —
                    // "leave it blank" wasn't discoverable. Since
                    // `MailCoreSMTPSession.connect` now falls back to no
                    // auth on that specific rejection, this hint documents
                    // the new behavior instead of instructing users to
                    // clear the field.
                    Text("空欄の場合は認証なしで接続します。サーバーが認証に対応していない場合は、ユーザー名を入力していても自動的に認証を省略します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await testSMTPConnection() }
                    } label: {
                        HStack {
                            Text("SMTP接続テスト")
                            if isTestingSMTP { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("accountSetup.testSMTPConnectionButton")
                    .disabled(isTestingSMTP || smtpHost.isEmpty || Int(smtpPortText) == nil)

                    if let smtpTestResultMessage {
                        Label(smtpTestResultMessage, systemImage: smtpTestSucceeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(smtpTestSucceeded ? .green : .red)
                            .accessibilityIdentifier("accountSetup.smtpTestResult")
                    }
                }

                if let testResultMessage {
                    Section {
                        Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .accessibilityIdentifier("accountSetup.testResult")
                    }
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("接続テスト")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("accountSetup.testConnectionButton")
                    .disabled(isTesting || !isFormValid)

                    Button {
                        Task { await saveAccount() }
                    } label: {
                        HStack {
                            Text("保存して同期開始")
                            if isSaving { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("accountSetup.saveButton")
                    .disabled(!testSucceeded || isSaving)
                }
            }
            .navigationTitle("アカウントを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("accountSetup.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("accountSetup.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{Form{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var isFormValid: Bool {
        !displayName.isEmpty
            && !email.isEmpty
            && !imapHost.isEmpty
            && !imapUsername.isEmpty
            && !password.isEmpty
            && imapPort != nil
    }

    private var imapPort: Int? { Int(imapPortText) }

    private func testConnection() async {
        guard let imapPort else { return }
        isTesting = true
        testResultMessage = nil
        defer { isTesting = false }

        let config = IMAPConfig(host: imapHost, port: imapPort, security: imapSecurity.mailTransportSecurity)
        let session = MailCoreIMAPSession(config: config)
        do {
            try await session.connect(auth: .password(username: imapUsername, password: password))
            await session.disconnect()
            testSucceeded = true
            testResultMessage = "接続に成功しました。"
        } catch {
            testSucceeded = false
            testResultMessage = mailTransportUserFacingMessage(for: error, prefix: "接続に失敗しました")
        }
    }

    /// M5: SMTP's own connection test (plan: "IMAP と別に"), separate from
    /// `testConnection()` above and not gating `saveAccount()` — SMTP stays
    /// optional to *save* an account (M1's original design), just required
    /// to actually send.
    private func testSMTPConnection() async {
        guard let smtpPort = Int(smtpPortText) else { return }
        isTestingSMTP = true
        smtpTestResultMessage = nil
        defer { isTestingSMTP = false }

        let config = SMTPConfig(host: smtpHost, port: smtpPort, security: smtpSecurity.mailTransportSecurity)
        let session = MailCoreSMTPSession(config: config)
        // Uses the SMTP username field verbatim (not a fallback to the
        // IMAP username) — matches `OpQueueProcessor.smtpAuth`'s actual
        // send-time behavior (see its doc comment), so this test reflects
        // what sending will really do. An intentionally blank SMTP
        // username makes `MailCoreSMTPSession.connect` skip authentication
        // entirely, for relays that require none; a *non-blank* username
        // against a relay that turns out not to support AUTH at all now
        // also connects, via `connect(auth:)`'s automatic no-auth retry —
        // see its doc comment. Either way, this test still reflects
        // whatever sending will actually do.
        do {
            try await session.connect(auth: .password(username: smtpUsername, password: password))
            await session.disconnect()
            smtpTestSucceeded = true
            smtpTestResultMessage = "SMTP接続に成功しました。"
        } catch {
            smtpTestSucceeded = false
            smtpTestResultMessage = mailTransportUserFacingMessage(for: error, prefix: "SMTP接続に失敗しました")
        }
    }

    private func saveAccount() async {
        guard testSucceeded, let imapPort else { return }
        isSaving = true
        defer { isSaving = false }

        let account = AccountRecord(
            displayName: displayName,
            email: email,
            authType: .password,
            imapHost: imapHost,
            imapPort: imapPort,
            imapSecurity: imapSecurity,
            imapUsername: imapUsername,
            smtpHost: smtpHost.isEmpty ? nil : smtpHost,
            smtpPort: smtpHost.isEmpty ? nil : Int(smtpPortText),
            smtpSecurity: smtpHost.isEmpty ? nil : smtpSecurity,
            smtpUsername: smtpUsername.isEmpty ? nil : smtpUsername
        )

        do {
            // Keychain first: if saving the account row succeeded but the
            // password write failed, we'd have an account nothing could
            // ever authenticate. The reverse (orphaned Keychain entry if
            // the DB write then fails) is harmless — it's just dead
            // weight, cleaned up next time this account id is reused, if
            // ever.
            try environment.credentialStore.setPassword(password, forAccountId: account.id)
            try await environment.database.dbWriter.write { db in
                try account.insert(db)
            }
            dismiss()

            let auth = MailAuth.password(username: imapUsername, password: password)
            Task {
                _ = try? await environment.syncCoordinator.syncAccount(account, auth: auth)
            }
            // M9: if push is already enabled, this new account should get
            // watched too, not just accounts that existed at enable-time.
            Task { await environment.registerWatchIfNeeded(for: account) }
            // M11: push this account's metadata to iCloud so it appears on
            // this Apple ID's other devices too.
            Task { await environment.pushAccountToCloud(account) }
        } catch {
            testSucceeded = false
            testResultMessage = "保存に失敗しました: \(error)"
        }
    }
}

private extension View {
    /// `.textInputAutocapitalization(.never)` is iOS/tvOS/watchOS-only;
    /// macOS text fields have no autocapitalization to disable in the
    /// first place. Centralizing the `#if` here keeps the form body free
    /// of per-field platform conditionals.
    @ViewBuilder
    func textFieldAutocapitalizationNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
