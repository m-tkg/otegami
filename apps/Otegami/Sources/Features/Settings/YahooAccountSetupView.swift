import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiStore
import OtegamiCore

/// Task #116「アカウント追加画面のプロバイダ拡充」: Yahoo Mail (yahoo.com)
/// の account-creation form. `ICloudAccountSetupView`と全く同じ構造 (メール
/// アドレス + アプリ用パスワード、ホスト/ポートは固定プリセットで
/// 編集不可) — Yahoo も iCloud と同じく通常のパスワードではなく
/// アプリ用パスワードでの IMAP/SMTP 接続を要求するため、フォームの形が
/// そのまま流用できる。プリセット値そのものは `OtegamiCore
/// .MailProviderPresets.yahoo` (Linux 互換のpure-logic層、ユニットテスト
/// 済み) から取る。
///
/// `kind: .generic`で保存する (`.gmail`/`.icloud`のような専用ケースを
/// 追加していない) — Yahoo アカウントには`OpQueueProcessor`の Gmail
/// 専用分岐のような特別扱いが一切不要で、保存後は「その他 (IMAP)」と
/// 全く同じパスワード認証アカウントとして振る舞う。`AccountEditView`
/// (触ってよいファイルだが、`AccountKind`の網羅的な`switch`が複数箇所に
/// あり、専用ケースを足すとその全てに手を入れる必要が生じる) の変更を
/// 最小限に抑えるための意図的な選択 — 編集画面では「その他 (IMAP)」
/// 扱いでホスト/ポートも自由に編集できるようになるが、実害はない
/// (Yahoo のプリセットは作成時に一度入力されるだけで、編集後もただの
/// IMAP/SMTP アカウントとして動くことに変わりはない)。
struct YahooAccountSetupView: View {
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

    private static let preset = MailProviderPresets.yahoo

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Yahoo のアカウント管理で発行した「アプリのパスワード」が必要です。Yahoo のパスワードそのものではログインできません。")
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                    Link("Yahoo のアカウント管理でアプリのパスワードを発行", destination: URL(string: "https://login.yahoo.com/myaccount/security")!)
                        .accessibilityIdentifier("yahooAccountSetup.appPasswordLink")
                }

                Section("アカウント") {
                    LabeledContent("表示名") {
                        TextField("省略時はメールアドレス", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("yahooAccountSetup.displayName")
                    }
                    LabeledContent("Yahoo メールアドレス") {
                        TextField("", text: $email)
                            .multilineTextAlignment(.trailing)
                            .textFieldAutocapitalizationNone()
                            .otegamiEmailKeyboard()
                            .accessibilityIdentifier("yahooAccountSetup.email")
                    }
                    LabeledContent("アプリのパスワード") {
                        SecureField("", text: $appPassword)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("yahooAccountSetup.appPassword")
                    }
                }

                Section("接続先 (自動設定)") {
                    LabeledContent("IMAP", value: "\(Self.preset.imap.host):\(Self.preset.imap.port) (TLS)")
                        .accessibilityIdentifier("yahooAccountSetup.imapPreset")
                    LabeledContent("SMTP", value: "\(Self.preset.smtp.host):\(Self.preset.smtp.port) (TLS)")
                        .accessibilityIdentifier("yahooAccountSetup.smtpPreset")
                }

                if let testResultMessage {
                    Section {
                        Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .accessibilityIdentifier("yahooAccountSetup.testResult")
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
                    .accessibilityIdentifier("yahooAccountSetup.testConnectionButton")
                    .disabled(isTesting || !isFormValid)

                    Button {
                        Task { await saveAccount() }
                    } label: {
                        HStack {
                            Text("保存して同期開始")
                            if isSaving { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("yahooAccountSetup.saveButton")
                    .disabled(!testSucceeded || isSaving)

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .foregroundStyle(OtegamiColor.destructive)
                    }
                }
            }
            .navigationTitle("Yahoo アカウントを追加")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("yahooAccountSetup.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("yahooAccountSetup.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{Form{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }

    private var isFormValid: Bool {
        !email.isEmpty && !appPassword.isEmpty
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
            password: appPassword
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
            try environment.credentialStore.setPassword(appPassword, forAccountId: account.id)
            try await environment.database.dbWriter.write { db in
                try account.insert(db)
            }
            dismiss()

            let auth = MailAuth.password(username: email, password: appPassword)
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
