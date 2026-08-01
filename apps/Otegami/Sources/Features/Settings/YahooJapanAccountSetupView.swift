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
/// **Yahoo!メール側の「メールソフトでの利用設定 (IMAP/POP アクセス)」が
/// 既定で無効**になっており、有効化しない限りどんなパスワードでも
/// 接続が拒否される — アプリ用パスワードが必須な国際版 Yahoo とは
/// ブロッカーの種類が異なる。ガイダンス文言はこの設定を有効にする具体的
/// な手順を案内する (プラン: 「メールソフトでの利用設定 (IMAP アクセス)
/// を有効にする」)。設定ページの正確な深い階層 URL は変更されやすいため、
/// Yahoo!メールのトップページのみリンクする (壊れたディープリンクを
/// 貼るより安全) — 手順はリンク先ではなくこの画面のテキストに書く。
///
/// **実機フィードバック (Task #116 後日談)**: 実際に接続を試みたユーザー
/// から「メールサーバにアクセスできない」報告があった。ホスト/ポート/
/// セキュリティ設定 (`MailProviderPresets.yahooJapan`: IMAP
/// `imap.mail.yahoo.co.jp:993`・SMTP `smtp.mail.yahoo.co.jp:465`、いずれも
/// 暗黙 TLS — Yahoo! JAPAN 公式が案内する「SMTP_AUTH」= SSL 上の
/// AUTH PLAIN/LOGIN と整合していることを確認済み、`ConnectionSecurityRecord
/// .tls` → `MailConnectionSecurity.tls` は STARTTLS ではなく最初から暗黙
/// TLS で接続する) 自体に問題は無かった。切り分けの結果、原因は主に
/// ユーザー側の2点だと判明:
/// 1. 「メールソフトでの利用設定」が未有効化のまま — 上記の通り既定で
///    オフ。
/// 2. **ログイン ID が実アドレスと異なる場合がある** — Yahoo! JAPAN の
///    IMAP/POP ログインは環境によって「Yahoo! JAPAN ID (`@yahoo.co.jp`
///    より前の部分のみ)」を要求することがあり、フルアドレスでは認証に
///    失敗する。この2点に対応するため、ガイダンス文言を手順込みに拡充し、
///    「ログインID」をメールアドレスとは別の編集可能フィールドにした
///    (既定値はメールアドレスと同じだが、認証に失敗する場合はここを
///    Yahoo! JAPAN ID (前半部分のみ) に変更できる)。
struct YahooJapanAccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var email = ""
    /// メールアドレスとは独立して編集可能 — 上記の doc comment の実機
    /// フィードバック参照。`email`が変わるたびに「まだ手入力されていな
    /// ければ」追従させる (`AccountSetupView.accountSection`の
    /// `imapUsername`/`smtpUsername`自動反映と同じパターン)。
    @State private var loginId = ""
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
                    Text("Yahoo!メールの「メールソフトでの利用設定 (IMAP/POP アクセス)」を有効にしておく必要があります。無効のままだと、正しいパスワードでも「メールサーバにアクセスできない」等のエラーで接続できません。")
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                    Text("手順: Yahoo!メールにログイン → 画面右上の歯車アイコン (設定) → 「メールの基本設定」→ 下の方にある「IMAP/POPアクセス」を「有効にする」に変更して保存。")
                        .font(.footnote)
                        .foregroundStyle(OtegamiColor.inkSecondary)
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
                            .onChange(of: email) { _, newValue in
                                if loginId.isEmpty { loginId = newValue }
                            }
                    }
                    LabeledContent("ログインID") {
                        TextField("", text: $loginId)
                            .multilineTextAlignment(.trailing)
                            .textFieldAutocapitalizationNone()
                            .accessibilityIdentifier("yahooJapanAccountSetup.loginId")
                    }
                    LabeledContent("パスワード") {
                        SecureField("", text: $password)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("yahooJapanAccountSetup.password")
                    }
                }

                Section {
                    Text("通常はメールアドレスと同じログインIDで接続できます。接続テストが失敗する場合は、ログインIDを「@yahoo.co.jp より前の Yahoo! JAPAN ID」だけに変更して再度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(OtegamiColor.inkSecondary)
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
        !email.isEmpty && !resolvedLoginId.isEmpty && !password.isEmpty
    }

    /// Falls back to `email` when the user hasn't touched「ログインID」at
    /// all (shouldn't normally happen — the `onChange(of: email)` above
    /// keeps it filled in — but covers the edge case where `email` changes
    /// after `loginId` was already auto-filled once, then cleared by hand).
    private var resolvedLoginId: String {
        loginId.isEmpty ? email : loginId
    }

    private func testConnection() async {
        isTesting = true
        testResultMessage = nil
        defer { isTesting = false }

        let result = await testIMAPConnection(
            host: Self.preset.imap.host,
            port: Self.preset.imap.port,
            security: Self.preset.imap.security.connectionSecurityRecord,
            username: resolvedLoginId,
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
            imapUsername: resolvedLoginId,
            smtpHost: Self.preset.smtp.host,
            smtpPort: Self.preset.smtp.port,
            smtpSecurity: Self.preset.smtp.security.connectionSecurityRecord,
            smtpUsername: resolvedLoginId,
            labelColorKey: environment.leastUsedAccountLabelColorKey(),
            sortOrder: environment.nextAccountSortOrder()
        )

        do {
            try environment.credentialStore.setPassword(password, forAccountId: account.id)
            try await environment.database.dbWriter.write { db in
                try account.insert(db)
            }
            dismiss()

            let auth = MailAuth.password(username: resolvedLoginId, password: password)
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
