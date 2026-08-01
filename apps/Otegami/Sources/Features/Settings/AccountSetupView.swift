import SwiftUI
import MailTransport
import MailTransportMailCore
import OtegamiCore
import OtegamiStore
import SyncEngine

/// Task #116「アカウント追加画面のプロバイダ拡充」: which flavor of the
/// generic IMAP form `AccountSetupView` renders as. `.other` is the
/// original M1 behavior (fully blank, port defaults 993/587, TLS/STARTTLS)
/// — unchanged. `.exchange` is a thin preset on top of the exact same form
/// (plan: "汎用 IMAP フォームのプリセット... オンプレ Exchange の IMAP
/// 有効環境向けという注記") rather than a separate view type: the only
/// things that differ are the initial IMAP security value, an info banner,
/// and the navigation title — host stays blank either way (never knowable
/// ahead of time for an on-prem server), so there was nothing else to
/// duplicate into its own file.
enum GenericIMAPFormPreset {
    case other
    case exchange

    var navigationTitle: LocalizedStringKey {
        switch self {
        case .other: "アカウントを追加"
        case .exchange: "Exchange アカウントを追加"
        }
    }

    var infoBannerText: LocalizedStringKey? {
        switch self {
        case .other: nil
        case .exchange: "社内 (オンプレミス) の Exchange サーバーで IMAP アクセスが有効になっている環境向けです。ホスト名はシステム管理者に確認してください。Microsoft 365 / Outlook.com は「アカウントを追加」→「Outlook」または「Office365」からサインインしてください。"
        }
    }

    var initialImapPortText: String {
        MailProviderPresets.exchange.imap.port.description
    }

    var initialImapSecurity: ConnectionSecurityRecord {
        switch self {
        case .other: .tls
        case .exchange: MailProviderPresets.exchange.imap.security.connectionSecurityRecord
        }
    }

    var initialSmtpPortText: String {
        MailProviderPresets.exchange.smtp.port.description
    }

    var initialSmtpSecurity: ConnectionSecurityRecord {
        switch self {
        case .other: .startTLS
        case .exchange: MailProviderPresets.exchange.smtp.security.connectionSecurityRecord
        }
    }
}

/// Generic IMAP account setup form (plan: "汎用 IMAP 手入力フォーム") — the "その他
/// (IMAP)" option on `AccountTypeSelectionView` (M6; before M6 this was the
/// only account-creation flow, reached directly). Host/port/security/
/// username/password entered by hand; SMTP fields are collected but unused
/// until M5 — kept optional so leaving them blank doesn't block saving.
///
/// Task #116: also doubles as the Exchange entry point (`preset: .exchange`)
/// — see `GenericIMAPFormPreset`'s doc comment for why that's a preset on
/// this same form rather than a new file.
struct AccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let preset: GenericIMAPFormPreset

    @State private var displayName = ""
    @State private var email = ""

    @State private var imapHost = ""
    @State private var imapPortText: String
    @State private var imapSecurity: ConnectionSecurityRecord
    @State private var imapUsername = ""
    @State private var password = ""

    @State private var smtpHost = ""
    @State private var smtpPortText: String
    @State private var smtpSecurity: ConnectionSecurityRecord
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

    init(preset: GenericIMAPFormPreset = .other) {
        self.preset = preset
        _imapPortText = State(initialValue: preset.initialImapPortText)
        _imapSecurity = State(initialValue: preset.initialImapSecurity)
        _smtpPortText = State(initialValue: preset.initialSmtpPortText)
        _smtpSecurity = State(initialValue: preset.initialSmtpSecurity)
    }

    var body: some View {
        NavigationStack {
            Form {
                infoBannerSection
                accountSection
                imapSection
                smtpSection
                testResultSection
                actionsSection
            }
            .navigationTitle(preset.navigationTitle)
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
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

    // Task #116: `.exchange`だけが表示 (`.other`は`nil`) — オンプレ
    // Exchange 向けの注記。`@ViewBuilder`にしているのは、この`Section`
    // 自体を丸ごと出し分ける必要があるため (中身だけ`if`で分岐すると
    // 空の`Section`が残ってしまう)。
    @ViewBuilder
    private var infoBannerSection: some View {
        if let infoBannerText = preset.infoBannerText {
            Section {
                Text(infoBannerText)
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("accountSetup.infoBanner")
            }
        }
    }

    // H (実機フィードバック第3弾): each field now carries a persistent
    // `LabeledContent` label instead of relying on a `TextField` placeholder
    // alone (which disappears once a value is typed, leaving no indication
    // of what the field *is* once filled in). Split into per-`Section`
    // computed properties (docs/ci.md's "SwiftUI ビューは小さく保つこと") —
    // this `body` was already a multi-`Section` `Form` before H, and the
    // extra `LabeledContent` nesting per field pushed it well past the
    // "keep it small" threshold that file warns about.
    private var accountSection: some View {
        Section("アカウント") {
            LabeledContent("表示名") {
                TextField("", text: $displayName)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("accountSetup.displayName")
            }
            LabeledContent("メールアドレス") {
                TextField("", text: $email)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .otegamiEmailKeyboard()
                    .accessibilityIdentifier("accountSetup.email")
                    .onChange(of: email) { _, newValue in
                        // D「メールアドレス入力時、SMTP ユーザー名にも自動反映」
                        // — IMAP 側の既存の挙動 (「まだ手入力されていなければ」
                        // 上書き) にそろえた。どちらか一方だけ手入力済みでも
                        // もう片方はそのまま追従する。
                        if imapUsername.isEmpty { imapUsername = newValue }
                        if smtpUsername.isEmpty { smtpUsername = newValue }
                    }
            }
        }
    }

    private var imapSection: some View {
        Section("IMAP") {
            LabeledContent("ホスト") {
                TextField("", text: $imapHost)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountSetup.imapHost")
            }
            LabeledContent("ポート") {
                TextField("", text: $imapPortText)
                    .multilineTextAlignment(.trailing)
                    .otegamiNumberPadKeyboard()
                    .accessibilityIdentifier("accountSetup.imapPort")
            }
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
            LabeledContent("ユーザー名") {
                TextField("", text: $imapUsername)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountSetup.imapUsername")
            }
            LabeledContent("パスワード") {
                SecureField("", text: $password)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("accountSetup.password")
            }
        }
    }

    private var smtpSection: some View {
        Section("SMTP (送信用。任意 — 未設定の場合は送信できません)") {
            LabeledContent("ホスト") {
                TextField("", text: $smtpHost)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountSetup.smtpHost")
            }
            LabeledContent("ポート") {
                TextField("", text: $smtpPortText)
                    .multilineTextAlignment(.trailing)
                    .otegamiNumberPadKeyboard()
                    .accessibilityIdentifier("accountSetup.smtpPort")
            }
            Picker("接続方式", selection: $smtpSecurity) {
                Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                Text("TLS").tag(ConnectionSecurityRecord.tls)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("accountSetup.smtpSecurity")
            LabeledContent("ユーザー名") {
                TextField("", text: $smtpUsername)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountSetup.smtpUsername")
            }
            // UX fix: a filled-in username used to always trigger
            // AUTH, which a non-authenticating SMTP server (e.g. the
            // dev mailstack's Mailpit) would then reject outright —
            // "leave it blank" wasn't discoverable. Since
            // `MailCoreSMTPSession.connect` now falls back to no
            // auth on that specific rejection, this hint documents
            // the new behavior instead of instructing users to
            // clear the field.
            Text("空欄の場合は認証なしで接続します。サーバーが認証に対応していない場合は、ユーザー名を入力していても自動的に認証を省略します。")
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)

            Button {
                Task { await testSMTPConnectionTapped() }
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
    }

    @ViewBuilder
    private var testResultSection: some View {
        if let testResultMessage {
            Section {
                Label(testResultMessage, systemImage: testSucceeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(testSucceeded ? .green : .red)
                    .accessibilityIdentifier("accountSetup.testResult")
            }
        }
    }

    private var actionsSection: some View {
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

        let result = await testIMAPConnection(host: imapHost, port: imapPort, security: imapSecurity, username: imapUsername, password: password)
        testSucceeded = result.succeeded
        testResultMessage = result.message
    }

    /// M5: SMTP's own connection test (plan: "IMAP と別に"), separate from
    /// `testConnection()` above and not gating `saveAccount()` — SMTP stays
    /// optional to *save* an account (M1's original design), just required
    /// to actually send.
    private func testSMTPConnectionTapped() async {
        guard let smtpPort = Int(smtpPortText) else { return }
        isTestingSMTP = true
        smtpTestResultMessage = nil
        defer { isTestingSMTP = false }

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
        let result = await testSMTPConnection(host: smtpHost, port: smtpPort, security: smtpSecurity, username: smtpUsername, password: password)
        smtpTestSucceeded = result.succeeded
        smtpTestResultMessage = result.message
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
            smtpUsername: smtpUsername.isEmpty ? nil : smtpUsername,
            // Task #72「自動割当の改善」: see `AppEnvironment
            // .leastUsedAccountLabelColorKey()`'s doc comment.
            labelColorKey: environment.leastUsedAccountLabelColorKey(),
            sortOrder: environment.nextAccountSortOrder()
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

    /// 表示・操作改善バッチ: メールアドレス欄用のソフトウェアキーボード —
    /// `@`/`.`が押しやすいレイアウトになる。`.keyboardType`はiOS/tvOSのみ。
    @ViewBuilder
    func otegamiEmailKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress)
        #else
        self
        #endif
    }

    /// 表示・操作改善バッチ: ポート番号欄用の数字専用キーボード。
    @ViewBuilder
    func otegamiNumberPadKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
