import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiStore

/// iCloud's account-creation form (M6, plan step "iCloud: メールアドレス +
/// App 用パスワード入力フォーム ... imap.mail.me.com:993 / smtp.mail.me.com:587
/// プリセット、kind=icloud"). Host/port/security are fixed (shown as static
/// info, not editable fields — unlike `AccountSetupView`'s "その他" form,
/// there's nothing provider-specific to type beyond the address and an
/// app-specific password), matching Gmail's form being "nothing to type but
/// the OAuth button" in spirit: only what's actually per-account varies.
///
/// **Username = full email address** (plan: "ユーザー名はメールアドレスの @ 前 or
/// フル — 実 iCloud で要確認事項として PENDING に記載し、実装はフルアドレスで").
/// iCloud's IMAP/SMTP historically accept the full `user@icloud.com` (and
/// reportedly also the bare `user` short-name) as the login — full address
/// was chosen since it's unambiguous and is what Apple's own account-setup
/// documentation shows; this still needs confirmation against a real
/// account. If a real account turns out to need the bare
/// short-name instead, the fix is confined to `imapUsername`/`smtpUsername`
/// below — everything else in this form is provider-agnostic.
struct ICloudAccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""
    @State private var appPassword = ""

    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testResultMessage: String?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    // Not `private`: `AccountEditView` (account edit UI) reuses these same
    // presets for an existing `.icloud`-kind account, whose IMAP/SMTP
    // fields aren't user-editable — see that view's doc comment.
    static let imapHost = "imap.mail.me.com"
    static let imapPort = 993
    static let smtpHost = "smtp.mail.me.com"
    static let smtpPort = 587

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("appleid.apple.com で発行した「App 用パスワード」が必要です。iCloud のパスワードそのものではログインできません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("appleid.apple.com で App 用パスワードを発行", destination: URL(string: "https://appleid.apple.com/account/manage")!)
                        .accessibilityIdentifier("icloudAccountSetup.appPasswordLink")
                }

                // H (実機フィードバック第3弾) — persistent labels instead of
                // placeholder-only fields (`AccountEditView`'s identical
                // fix's doc comment).
                Section("アカウント") {
                    LabeledContent("表示名") {
                        TextField("省略時はメールアドレス", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("icloudAccountSetup.displayName")
                    }
                    LabeledContent("iCloud メールアドレス") {
                        TextField("", text: $email)
                            .multilineTextAlignment(.trailing)
                            .textFieldAutocapitalizationNone()
                            .otegamiEmailKeyboard()
                            .accessibilityIdentifier("icloudAccountSetup.email")
                    }
                    LabeledContent("App 用パスワード") {
                        SecureField("", text: $appPassword)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("icloudAccountSetup.appPassword")
                    }
                }

                Section("接続先 (自動設定)") {
                    LabeledContent("IMAP", value: "\(Self.imapHost):\(Self.imapPort) (TLS)")
                        .accessibilityIdentifier("icloudAccountSetup.imapPreset")
                    LabeledContent("SMTP", value: "\(Self.smtpHost):\(Self.smtpPort) (STARTTLS)")
                        .accessibilityIdentifier("icloudAccountSetup.smtpPreset")
                }

                if let testResultMessage {
                    Section {
                        Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .accessibilityIdentifier("icloudAccountSetup.testResult")
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
                    .accessibilityIdentifier("icloudAccountSetup.testConnectionButton")
                    .disabled(isTesting || !isFormValid)

                    Button {
                        Task { await saveAccount() }
                    } label: {
                        HStack {
                            Text("保存して同期開始")
                            if isSaving { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("icloudAccountSetup.saveButton")
                    .disabled(!testSucceeded || isSaving)

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .foregroundStyle(OtegamiColor.destructive)
                    }
                }
            }
            .navigationTitle("iCloud アカウントを追加")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("icloudAccountSetup.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("icloudAccountSetup.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{Form{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    private var isFormValid: Bool {
        !email.isEmpty && !appPassword.isEmpty
    }

    /// **Not exercised by `scripts/verify-ios-m6.sh`**: unlike the "その他"
    /// form's connection test (which points at the dev mailstack's Dovecot,
    /// always reachable from CI), this always dials the real
    /// `imap.mail.me.com` — there's no throwaway iCloud account to test
    /// against yet. The verify script only asserts the
    /// form itself renders with the right preset values; a human with a
    /// real iCloud App 用パスワード is expected to exercise this button
    /// once, manually.
    private func testConnection() async {
        isTesting = true
        testResultMessage = nil
        defer { isTesting = false }

        let result = await testIMAPConnection(host: Self.imapHost, port: Self.imapPort, security: .tls, username: email, password: appPassword)
        testSucceeded = result.succeeded
        testResultMessage = result.message
    }

    private func saveAccount() async {
        guard testSucceeded else { return }
        isSaving = true
        defer { isSaving = false }

        let account = AccountRecord(
            displayName: displayName.isEmpty ? email : displayName,
            email: email,
            authType: .password,
            kind: .icloud,
            imapHost: Self.imapHost,
            imapPort: Self.imapPort,
            imapSecurity: .tls,
            imapUsername: email,
            smtpHost: Self.smtpHost,
            smtpPort: Self.smtpPort,
            smtpSecurity: .startTLS,
            smtpUsername: email,
            // Task #72「自動割当の改善」: see `AppEnvironment
            // .leastUsedAccountLabelColorKey()`'s doc comment.
            labelColorKey: environment.leastUsedAccountLabelColorKey(),
            sortOrder: environment.nextAccountSortOrder()
        )

        do {
            // Keychain-before-DB-row, same ordering rationale as
            // `AccountSetupView.saveAccount`.
            try environment.credentialStore.setPassword(appPassword, forAccountId: account.id)
            try await environment.database.dbWriter.write { db in
                try account.insert(db)
            }
            dismiss()

            let auth = MailAuth.password(username: email, password: appPassword)
            Task {
                _ = try? await environment.syncCoordinator.syncAccount(account, auth: auth)
            }
            // M9: see AccountSetupView.saveAccount's identical call.
            Task { await environment.registerWatchIfNeeded(for: account) }
            // M11: see AccountSetupView.saveAccount's identical call.
            Task { await environment.pushAccountToCloud(account) }
        } catch {
            testSucceeded = false
            saveErrorMessage = "保存に失敗しました: \(error)"
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

    /// See `AccountSetupView`'s identical helper's doc comment.
    @ViewBuilder
    func otegamiEmailKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress)
        #else
        self
        #endif
    }
}
