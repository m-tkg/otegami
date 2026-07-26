import SwiftUI
import MailTransport
import OtegamiStore

/// Account editing (`AccountsSettingsView`'s account rows now open this on
/// tap, instead of being add/delete-only — see `docs/roadmap.md`'s former
/// "アカウント編集 UI" entry). Reuses `AccountSetupView`'s connection-test
/// helpers (`testIMAPConnection`/`testSMTPConnection`,
/// `AccountConnectionTesting.swift`) rather than duplicating them, and
/// mirrors its field layout for the parts that *are* editable.
///
/// **Email and `kind` are never editable** (the plan's rationale: they're
/// what makes this account *this* account — changing either is "create a
/// different account", not "edit this one"), shown as fixed
/// `LabeledContent` rows instead of `TextField`s. What's editable beyond
/// that depends on `kind`:
///
/// - `.generic`: everything `AccountSetupView` collects except email/kind/
///   `imapUsername` (display name, IMAP host/port/security, SMTP host/
///   port/security/username) plus an optional new password.
/// - `.icloud`: IMAP/SMTP host/port/security are fixed presets (mirrors
///   `ICloudAccountSetupView` — nothing provider-specific to edit there),
///   so only display name and an optional new App-specific password.
/// - `.gmail`: no password field at all (OAuth) — just display name plus a
///   "再認証" button that re-runs the same interactive flow
///   `AccountsSettingsView`'s existing reauth banner uses
///   (`AppEnvironment.reauthenticateGmailAccount`). Server settings are
///   fixed presets, matching `GmailAccountSetupView` having nothing to
///   type either.
///
/// The password field is **never pre-filled** with the existing secret —
/// `SecureField`'s placeholder text documents "leave blank to keep the
/// current password" instead. Leaving it blank still lets "接続テスト"/
/// "保存" work correctly: `resolvedPassword` transparently falls back to
/// reading the existing Keychain entry when nothing new was typed, so
/// editing (say) just the IMAP host doesn't force the user to also
/// re-type a password they're not changing.
///
/// Saving does **not** require a successful "接続テスト" first (unlike
/// `AccountSetupView`'s stricter gating for a *brand-new*, unproven
/// account) — the verification flow this view needs to support explicitly
/// includes saving a *wrong* password and seeing the resulting sync
/// failure surface elsewhere (`AccountsListContent`'s sync-error banner,
/// `AccountRecord.lastSyncError`) rather than being blocked at save time.
struct AccountEditView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let account: AccountRecord

    @State private var displayName: String
    @State private var imapHost: String
    @State private var imapPortText: String
    @State private var imapSecurity: ConnectionSecurityRecord
    @State private var newPassword = ""

    @State private var smtpHost: String
    @State private var smtpPortText: String
    @State private var smtpSecurity: ConnectionSecurityRecord
    @State private var smtpUsername: String

    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testResultMessage: String?
    @State private var isTestingSMTP = false
    @State private var smtpTestSucceeded = false
    @State private var smtpTestResultMessage: String?

    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    @State private var isReauthenticating = false
    @State private var reauthErrorMessage: String?

    init(account: AccountRecord) {
        self.account = account
        _displayName = State(initialValue: account.displayName)
        _imapHost = State(initialValue: account.imapHost)
        _imapPortText = State(initialValue: String(account.imapPort))
        _imapSecurity = State(initialValue: account.imapSecurity)
        _smtpHost = State(initialValue: account.smtpHost ?? "")
        _smtpPortText = State(initialValue: account.smtpPort.map(String.init) ?? "587")
        _smtpSecurity = State(initialValue: account.smtpSecurity ?? .startTLS)
        _smtpUsername = State(initialValue: account.smtpUsername ?? "")
    }

    // A pushed `NavigationLink` destination (`AccountsSettingsView`), not a
    // `.sheet` — deliberately **no** `NavigationStack` wrapper here (unlike
    // `AccountSetupView`/`ICloudAccountSetupView`/`GmailAccountSetupView`,
    // all sheet roots): this view composes directly into the
    // `NavigationStack` `AccountsListContent`'s `List` already lives in
    // (the same one "プッシュ通知"/"このアプリについて" push onto), and
    // nesting a second `NavigationStack` inside that would be the exact
    // anti-pattern `AccountsListContent`'s own doc comment already warns
    // about (for the unrelated macOS `TabView` reason M10 found) — no
    // extra `#if os(macOS) .frame(...)` sizing hack needed either, since
    // that was specifically a `.sheet`-sizing fix (`AccountTypeSelectionView`'s
    // doc comment) that doesn't apply to a pushed destination.
    var body: some View {
        Form {
            Section("アカウント") {
                LabeledContent("メールアドレス", value: account.email)
                    .accessibilityIdentifier("accountEdit.email")
                LabeledContent("種類", value: kindLabel)
                    .accessibilityIdentifier("accountEdit.kind")
                TextField("表示名", text: $displayName)
                    .accessibilityIdentifier("accountEdit.displayName")
            }

            switch account.kind {
            case .gmail:
                gmailSections
            case .icloud:
                icloudSections
            case .generic:
                genericSections
            }

            if let saveErrorMessage {
                Section {
                    Text(saveErrorMessage)
                        .foregroundStyle(OtegamiColor.destructive)
                        .accessibilityIdentifier("accountEdit.saveError")
                }
            }

            Section {
                Button {
                    Task { await saveAccount() }
                } label: {
                    HStack {
                        Text("保存")
                        if isSaving { Spacer(); ProgressView() }
                    }
                }
                .accessibilityIdentifier("accountEdit.saveButton")
                .disabled(!isFormValid || isSaving)
            }
        }
        .navigationTitle("アカウントを編集")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("accountEdit.screen")
    }

    // MARK: - Per-kind sections

    @ViewBuilder
    private var genericSections: some View {
        Section("IMAP") {
            TextField("ホスト", text: $imapHost)
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("accountEdit.imapHost")
            TextField("ポート", text: $imapPortText)
                .otegamiNumberPadKeyboard()
                .accessibilityIdentifier("accountEdit.imapPort")
            Picker("接続方式", selection: $imapSecurity) {
                Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                Text("TLS").tag(ConnectionSecurityRecord.tls)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("accountEdit.imapSecurity")
            SecureField("新しいパスワード (変更する場合のみ入力)", text: $newPassword)
                .accessibilityIdentifier("accountEdit.password")
        }

        Section("SMTP (送信用。任意)") {
            TextField("ホスト", text: $smtpHost)
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("accountEdit.smtpHost")
            TextField("ポート", text: $smtpPortText)
                .otegamiNumberPadKeyboard()
                .accessibilityIdentifier("accountEdit.smtpPort")
            Picker("接続方式", selection: $smtpSecurity) {
                Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                Text("TLS").tag(ConnectionSecurityRecord.tls)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("accountEdit.smtpSecurity")
            TextField("ユーザー名", text: $smtpUsername)
                .textFieldAutocapitalizationNone()
                .accessibilityIdentifier("accountEdit.smtpUsername")

            Button {
                Task { await testSMTPConnectionTapped() }
            } label: {
                HStack {
                    Text("SMTP接続テスト")
                    if isTestingSMTP { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("accountEdit.testSMTPConnectionButton")
            .disabled(isTestingSMTP || smtpHost.isEmpty || Int(smtpPortText) == nil)

            if let smtpTestResultMessage {
                Label(smtpTestResultMessage, systemImage: smtpTestSucceeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(smtpTestSucceeded ? .green : .red)
                    .accessibilityIdentifier("accountEdit.smtpTestResult")
            }
        }

        if let testResultMessage {
            Section {
                Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(testSucceeded ? .green : .red)
                    .accessibilityIdentifier("accountEdit.testResult")
            }
        }

        Section {
            Button {
                Task { await testConnectionTapped() }
            } label: {
                HStack {
                    Text("接続テスト")
                    if isTesting { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("accountEdit.testConnectionButton")
            .disabled(isTesting || imapHost.isEmpty || Int(imapPortText) == nil)
        }
    }

    @ViewBuilder
    private var icloudSections: some View {
        Section("接続先 (自動設定・変更不可)") {
            LabeledContent("IMAP", value: "\(ICloudAccountSetupView.imapHost):\(ICloudAccountSetupView.imapPort) (TLS)")
                .accessibilityIdentifier("accountEdit.imapPreset")
            LabeledContent("SMTP", value: "\(ICloudAccountSetupView.smtpHost):\(ICloudAccountSetupView.smtpPort) (STARTTLS)")
                .accessibilityIdentifier("accountEdit.smtpPreset")
        }

        Section("App 用パスワード") {
            SecureField("新しい App 用パスワード (変更する場合のみ入力)", text: $newPassword)
                .accessibilityIdentifier("accountEdit.password")
            Link("appleid.apple.com で App 用パスワードを発行", destination: URL(string: "https://appleid.apple.com/account/manage")!)
                .accessibilityIdentifier("accountEdit.appPasswordLink")
        }

        if let testResultMessage {
            Section {
                Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(testSucceeded ? .green : .red)
                    .accessibilityIdentifier("accountEdit.testResult")
            }
        }

        Section {
            Button {
                Task { await testConnectionTapped() }
            } label: {
                HStack {
                    Text("接続テスト")
                    if isTesting { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("accountEdit.testConnectionButton")
            .disabled(isTesting)
        }
    }

    @ViewBuilder
    private var gmailSections: some View {
        Section("接続先 (固定)") {
            LabeledContent("IMAP", value: "\(account.imapHost):\(account.imapPort)")
            if let smtpHostValue = account.smtpHost, let smtpPortValue = account.smtpPort {
                LabeledContent("SMTP", value: "\(smtpHostValue):\(smtpPortValue)")
            }
        }

        Section("認証") {
            Text("Google アカウントでの認証です。パスワードはこのアプリに保存されません。認証が切れた場合は「再認証」から再度サインインしてください。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await reauthenticate() }
            } label: {
                HStack {
                    Text("再認証")
                    if isReauthenticating { Spacer(); ProgressView() }
                }
            }
            .accessibilityIdentifier("accountEdit.reauthButton")
            .disabled(isReauthenticating)

            if let reauthErrorMessage {
                Label(reauthErrorMessage, systemImage: "xmark.octagon")
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("accountEdit.reauthError")
            }
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        guard !displayName.isEmpty else { return false }
        switch account.kind {
        case .gmail:
            return true
        case .icloud:
            return true
        case .generic:
            return !imapHost.isEmpty && Int(imapPortText) != nil
        }
    }

    /// Falls back to the existing Keychain password when the user hasn't
    /// typed a new one — see this type's doc comment on why the field is
    /// never pre-filled but "接続テスト"/"保存" both still need *some*
    /// password to act on. `.gmail` accounts never call this (no
    /// `.password`-kind credential exists for them).
    private var resolvedPassword: String {
        if !newPassword.isEmpty { return newPassword }
        return (try? environment.credentialStore.password(forAccountId: account.id)) ?? ""
    }

    // MARK: - Actions

    private func testConnectionTapped() async {
        isTesting = true
        testResultMessage = nil
        defer { isTesting = false }

        let host: String
        let port: Int
        let security: ConnectionSecurityRecord
        switch account.kind {
        case .icloud:
            host = ICloudAccountSetupView.imapHost
            port = ICloudAccountSetupView.imapPort
            security = .tls
        case .generic:
            guard let parsedPort = Int(imapPortText) else { return }
            host = imapHost
            port = parsedPort
            security = imapSecurity
        case .gmail:
            return
        }

        let result = await testIMAPConnection(host: host, port: port, security: security, username: account.imapUsername, password: resolvedPassword)
        testSucceeded = result.succeeded
        testResultMessage = result.message
    }

    private func testSMTPConnectionTapped() async {
        guard let port = Int(smtpPortText) else { return }
        isTestingSMTP = true
        smtpTestResultMessage = nil
        defer { isTestingSMTP = false }

        let result = await testSMTPConnection(host: smtpHost, port: port, security: smtpSecurity, username: smtpUsername, password: resolvedPassword)
        smtpTestSucceeded = result.succeeded
        smtpTestResultMessage = result.message
    }

    private func reauthenticate() async {
        isReauthenticating = true
        reauthErrorMessage = nil
        defer { isReauthenticating = false }

        do {
            try await environment.reauthenticateGmailAccount(account)
            dismiss()
        } catch {
            reauthErrorMessage = "再認証に失敗しました: \(error)"
        }
    }

    private func saveAccount() async {
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        do {
            switch account.kind {
            case .gmail:
                // Nothing but display name is editable — everything else
                // (host/port/security/username) stays exactly what
                // `createGmailAccount` set, and there's no password to
                // (possibly) update.
                try await environment.updateAccount(
                    account,
                    displayName: displayName,
                    imapHost: account.imapHost,
                    imapPort: account.imapPort,
                    imapSecurity: account.imapSecurity,
                    smtpHost: account.smtpHost,
                    smtpPort: account.smtpPort,
                    smtpSecurity: account.smtpSecurity,
                    smtpUsername: account.smtpUsername,
                    newPassword: nil
                )
            case .icloud:
                try await environment.updateAccount(
                    account,
                    displayName: displayName,
                    imapHost: ICloudAccountSetupView.imapHost,
                    imapPort: ICloudAccountSetupView.imapPort,
                    imapSecurity: .tls,
                    smtpHost: ICloudAccountSetupView.smtpHost,
                    smtpPort: ICloudAccountSetupView.smtpPort,
                    smtpSecurity: .startTLS,
                    smtpUsername: account.smtpUsername,
                    newPassword: newPassword.isEmpty ? nil : newPassword
                )
            case .generic:
                guard let imapPort = Int(imapPortText) else {
                    saveErrorMessage = "IMAP ポート番号を確認してください。"
                    return
                }
                let trimmedSMTPHost = smtpHost.isEmpty ? nil : smtpHost
                try await environment.updateAccount(
                    account,
                    displayName: displayName,
                    imapHost: imapHost,
                    imapPort: imapPort,
                    imapSecurity: imapSecurity,
                    smtpHost: trimmedSMTPHost,
                    smtpPort: trimmedSMTPHost == nil ? nil : Int(smtpPortText),
                    smtpSecurity: trimmedSMTPHost == nil ? nil : smtpSecurity,
                    smtpUsername: smtpUsername.isEmpty ? nil : smtpUsername,
                    newPassword: newPassword.isEmpty ? nil : newPassword
                )
            }
            dismiss()
        } catch {
            saveErrorMessage = "保存に失敗しました: \(error)"
        }
    }

    private var kindLabel: String {
        switch account.kind {
        case .generic: "その他 (IMAP)"
        case .gmail: "Gmail"
        case .icloud: "iCloud"
        }
    }
}

private extension View {
    /// See `AccountSetupView`'s identical helper's doc comment.
    @ViewBuilder
    func textFieldAutocapitalizationNone() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }

    /// See `AccountSetupView`'s identical helper's doc comment.
    @ViewBuilder
    func otegamiNumberPadKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
