import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiStore
import OtegamiCore

/// Task #116「アカウント追加画面のプロバイダ拡充」: Yahoo!メール
/// (yahoo.co.jp) の account-creation form。国際版 Yahoo Mail
/// (`YahooAccountSetupView`) とは別サービスで、ホスト/ガイダンスが異なる
/// ため別ファイルにしている (`ICloudAccountSetupView`と同じ構造の使い
/// 回し) — 構造自体は`YahooAccountSetupView`と同一。
///
/// Yahoo!メールは通常のパスワードでも IMAP ログイン自体は可能だが、
/// **Yahoo!メール側の「メールソフトでの利用設定 (IMAP アクセス)」が
/// 既定で無効**になっており、有効化しない限りどんなパスワードでも
/// 接続が拒否される — アプリ用パスワードが必須な国際版 Yahoo とは
/// ブロッカーの種類が異なる。ガイダンス文言はこの設定を有効にすること
/// を案内する (プラン: 「メールソフトでの利用設定 (IMAP アクセス) を
/// 有効にする」)。設定ページの正確な深い階層 URL は変更されやすいため、
/// Yahoo!メールのトップページのみリンクする (壊れたディープリンクを
/// 貼るより安全)。
struct YahooJapanAccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""

    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testResultMessage: String?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    private static let preset = MailProviderPresets.yahooJapan

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Yahoo!メールの設定で「メールソフトでの利用設定 (IMAP アクセス)」を有効にしておく必要があります。無効のままだと、正しいパスワードでも接続できません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("Yahoo!メールを開く", destination: URL(string: "https://mail.yahoo.co.jp/")!)
                        .accessibilityIdentifier("yahooJapanAccountSetup.settingsLink")
                }

                Section("アカウント") {
                    LabeledContent("表示名") {
                        TextField("省略時はメールアドレス", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("yahooJapanAccountSetup.displayName")
                    }
                    LabeledContent("Yahoo!メールアドレス") {
                        TextField("", text: $email)
                            .multilineTextAlignment(.trailing)
                            .textFieldAutocapitalizationNone()
                            .otegamiEmailKeyboard()
                            .accessibilityIdentifier("yahooJapanAccountSetup.email")
                    }
                    LabeledContent("パスワード") {
                        SecureField("", text: $password)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("yahooJapanAccountSetup.password")
                    }
                }

                Section("接続先 (自動設定)") {
                    LabeledContent("IMAP", value: "\(Self.preset.imap.host):\(Self.preset.imap.port) (TLS)")
                        .accessibilityIdentifier("yahooJapanAccountSetup.imapPreset")
                    LabeledContent("SMTP", value: "\(Self.preset.smtp.host):\(Self.preset.smtp.port) (TLS)")
                        .accessibilityIdentifier("yahooJapanAccountSetup.smtpPreset")
                }

                if let testResultMessage {
                    Section {
                        Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .accessibilityIdentifier("yahooJapanAccountSetup.testResult")
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
                    .accessibilityIdentifier("yahooJapanAccountSetup.testConnectionButton")
                    .disabled(isTesting || !isFormValid)

                    Button {
                        Task { await saveAccount() }
                    } label: {
                        HStack {
                            Text("保存して同期開始")
                            if isSaving { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("yahooJapanAccountSetup.saveButton")
                    .disabled(!testSucceeded || isSaving)

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .foregroundStyle(OtegamiColor.destructive)
                    }
                }
            }
            .navigationTitle("Yahoo! JAPAN アカウントを追加")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("yahooJapanAccountSetup.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("yahooJapanAccountSetup.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{Form{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty
    }

    private func testConnection() async {
        isTesting = true
        testResultMessage = nil
        defer { isTesting = false }

        let result = await testIMAPConnection(
            host: Self.preset.imap.host,
            port: Self.preset.imap.port,
            security: Self.preset.imap.security.connectionSecurityRecord,
            username: email,
            password: password
        )
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
            kind: .generic,
            imapHost: Self.preset.imap.host,
            imapPort: Self.preset.imap.port,
            imapSecurity: Self.preset.imap.security.connectionSecurityRecord,
            imapUsername: email,
            smtpHost: Self.preset.smtp.host,
            smtpPort: Self.preset.smtp.port,
            smtpSecurity: Self.preset.smtp.security.connectionSecurityRecord,
            smtpUsername: email,
            labelColorKey: environment.leastUsedAccountLabelColorKey(),
            sortOrder: environment.nextAccountSortOrder()
        )

        do {
            try environment.credentialStore.setPassword(password, forAccountId: account.id)
            try await environment.database.dbWriter.write { db in
                try account.insert(db)
            }
            dismiss()

            let auth = MailAuth.password(username: email, password: password)
            Task {
                _ = try? await environment.syncCoordinator.syncAccount(account, auth: auth)
            }
            Task { await environment.registerWatchIfNeeded(for: account) }
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

    @ViewBuilder
    func otegamiEmailKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress)
        #else
        self
        #endif
    }
}
