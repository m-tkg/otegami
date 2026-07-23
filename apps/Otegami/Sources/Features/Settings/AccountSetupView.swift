import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiStore
import SyncEngine

/// Generic IMAP account setup form (plan: "汎用 IMAP 手入力フォーム"). Gmail/
/// iCloud presets land in M6; M1 is host/port/security/username/password
/// only. SMTP fields are collected but unused until M5 — kept optional so
/// leaving them blank doesn't block saving.
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

                Section("SMTP (任意。M1では未使用)") {
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
            testResultMessage = "接続に失敗しました: \(error)"
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
