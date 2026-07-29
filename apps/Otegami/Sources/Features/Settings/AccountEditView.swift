import SwiftUI
import GRDB
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
    /// 実機バグ修正: 「権限の診断」— `.task`で画面表示のたびに1回、
    /// Google に付与済みスコープを問い合わせる (`AppEnvironment
    /// .googleGrantedScope(for:)`のドキュメントコメント参照)。「再認証」
    /// ボタンは成功時にこの画面自体を`dismiss()`するので、この状態は
    /// 「もう一度この画面を開き直す」たびに新しい`.task`が走って更新
    /// される — 「再認証 → もう一度アカウント編集を開いて確認」という
    /// ユーザーの実機確認手順 (`docs/oauth-setup.md`) にちょうど対応する。
    @State private var scopeDiagnosis: GoogleScopeDiagnosisState = .checking

    /// D「アカウントのラベル色を変更可能に」— decoded from `account
    /// .labelColorKey` up front. 実機フィードバック (2026-07-29「自動、は
    /// いらない」) でピッカーの「自動」ピルを廃止したため、`nil` (未設定の
    /// レガシーアカウント) は FNV-1a のハッシュ割当が現に解決している色を
    /// 初期選択として見せる — 保存すればそれが明示色として固定される。
    @State private var labelColorKey: OtegamiAccountColor.PaletteColor?

    /// F「デフォルト署名（アカウントごと）」— every signature currently scoped
    /// to this account (`SignatureTemplateRecord.accountIds.contains
    /// (account.id)`), loaded once in `.task` below (this screen has no
    /// other reason to observe `signatureTemplate` live).
    @State private var availableSignatures: [SignatureTemplateRecord] = []
    @State private var defaultSignatureId: Int64?

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
        _labelColorKey = State(initialValue: account.labelColorKey.flatMap(OtegamiAccountColor.PaletteColor.init(rawValue:))
            ?? OtegamiAccountColor.resolvedPaletteColor(for: account.id))
        _defaultSignatureId = State(initialValue: account.defaultSignatureId)
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
                // H (実機フィードバック第3弾): a persistent label — the
                // previous plain `TextField("表示名", text:)` only showed
                // "表示名" as a placeholder, which (unlike this section's
                // other two `LabeledContent` rows right above) disappeared
                // the moment a value was typed, leaving no indication of
                // what the field held once filled in.
                LabeledContent("表示名") {
                    TextField("", text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("accountEdit.displayName")
                }
            }

            Section("ラベル色") {
                AccountLabelColorPicker(selection: $labelColorKey)
            }

            Section {
                NavigationLink("メールボックスの表示設定") {
                    MailboxVisibilityView(account: account)
                }
                .accessibilityIdentifier("accountEdit.mailboxVisibilityLink")
            } footer: {
                Text("Gmail の「すべてのメール」など、一覧に出したくないメールボックスを個別に隠せます。")
            }

            if !availableSignatures.isEmpty {
                Section {
                    Picker("デフォルト署名", selection: $defaultSignatureId) {
                        Text("なし").tag(Int64?.none)
                        ForEach(availableSignatures) { signature in
                            Text(signature.name).tag(Optional(signature.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("accountEdit.defaultSignaturePicker")
                } header: {
                    Text("署名")
                } footer: {
                    Text("新規メール作成時、このアカウントを差出人に選ぶと本文末尾に自動で挿入されます（返信・転送では自動挿入されません。作成画面の「署名」欄から手動で選べます）。")
                }
            }

            switch account.kind {
            case .gmail:
                gmailSections
            case .microsoft:
                microsoftSections
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
        #if os(macOS)
        // Task #155 (macOS 設定画面が崩れている): macOS の既定 `Form`
        // スタイル (`.automatic`) は、ラベル列の幅をこの画面のセクション
        // ごとに計算し、「新しいパスワード」のような長いラベルが「ホスト」
        // 「ポート」等の短いラベルより大きく育たず、ウィンドウ左端の外へ
        // ラベルがはみ出す (実機で確認・screenshot で再現済み)。
        // `.formStyle(.grouped)` (macOS の「システム設定」が使うスタイル)
        // はラベル列の幅をフォーム全体で揃えて計算するため、この崩れを
        // 解消する。iOSの`Form`は元から意図通りなのでmacOSのみに適用。
        .formStyle(.grouped)
        // 実機フィードバック (2026-07-29): macOS は System Settings 標準の
        // 見た目に揃える方針 — `OtegamiColor`の独自背景/アクセント塗りは
        // macOS には適用せず、AppKit 標準の外観に任せる (iOS は従来どおり)。
        .toggleStyle(.switch)
        #else
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
        .accessibilityIdentifier("accountEdit.screen")
        #if os(macOS)
        // Task #155 follow-up: `MacSettingsBackButton`'s doc comment —
        // this screen is what the 2026-07-29 実機報告 ("戻るボタンが
        // タイトルの真下・中央に浮いている") was filed against.
        .macSettingsBackButton()
        #endif
        .task { await loadAvailableSignatures() }
        .task { await refreshScopeDiagnosis() }
    }

    /// `.oauth2`以外 (`.generic`/`.icloud`)では常に`.unknown`のまま —
    /// `gmailSections`しか`scopeDiagnosis`を表示しないので実害は無いが、
    /// 無駄な `AppEnvironment.googleGrantedScope(for:)` 呼び出し
    /// (`.oauth2`チェックで`nil`を返すだけ) は避ける。
    private func refreshScopeDiagnosis() async {
        guard account.kind == .gmail else { return }
        scopeDiagnosis = .checking
        guard let scope = await environment.googleGrantedScope(for: account) else {
            scopeDiagnosis = .unknown
            return
        }
        scopeDiagnosis = GoogleScopeDiagnosisState.diagnose(scope: scope)
    }

    private func loadAvailableSignatures() async {
        let all = (try? await environment.database.dbWriter.read { db in
            try SignatureTemplateRecord.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
        availableSignatures = all.filter { $0.accountIds.contains(account.id) }
        if let defaultSignatureId, !availableSignatures.contains(where: { $0.id == defaultSignatureId }) {
            // The previously-chosen default no longer applies to this
            // account (e.g. someone unchecked it in `SignatureTemplateEditView`)
            // — fall back to "なし" rather than keeping a stale selection
            // the picker itself doesn't even list.
            self.defaultSignatureId = nil
        }
    }

    // MARK: - Per-kind sections

    @ViewBuilder
    private var genericSections: some View {
        Section("IMAP") {
            LabeledContent("ホスト") {
                TextField("", text: $imapHost)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountEdit.imapHost")
            }
            LabeledContent("ポート") {
                TextField("", text: $imapPortText)
                    .multilineTextAlignment(.trailing)
                    .otegamiNumberPadKeyboard()
                    .accessibilityIdentifier("accountEdit.imapPort")
            }
            Picker("接続方式", selection: $imapSecurity) {
                Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                Text("TLS").tag(ConnectionSecurityRecord.tls)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("accountEdit.imapSecurity")
            LabeledContent("新しいパスワード") {
                SecureField("変更する場合のみ入力", text: $newPassword)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("accountEdit.password")
            }
        }

        Section("SMTP (送信用。任意)") {
            LabeledContent("ホスト") {
                TextField("", text: $smtpHost)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountEdit.smtpHost")
            }
            LabeledContent("ポート") {
                TextField("", text: $smtpPortText)
                    .multilineTextAlignment(.trailing)
                    .otegamiNumberPadKeyboard()
                    .accessibilityIdentifier("accountEdit.smtpPort")
            }
            Picker("接続方式", selection: $smtpSecurity) {
                Text("なし (平文)").tag(ConnectionSecurityRecord.plain)
                Text("STARTTLS").tag(ConnectionSecurityRecord.startTLS)
                Text("TLS").tag(ConnectionSecurityRecord.tls)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("accountEdit.smtpSecurity")
            LabeledContent("ユーザー名") {
                TextField("", text: $smtpUsername)
                    .multilineTextAlignment(.trailing)
                    .textFieldAutocapitalizationNone()
                    .accessibilityIdentifier("accountEdit.smtpUsername")
            }

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
            LabeledContent("新しい App 用パスワード") {
                SecureField("変更する場合のみ入力", text: $newPassword)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("accountEdit.password")
            }
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
            // アバター強化バッチ「Google プロフィール写真」: 新スコープ
            // (`contacts.other.readonly`、後に `contacts.readonly` も追加)
            // 追加前に接続したアカウントは、下の「再認証」ボタンで同じ
            // OAuth フローを再実行する (現在の `GoogleOAuthEndpoints.scope`
            // には既に新スコープが含まれているので、再同意するだけで
            // 有効になる — アカウントの削除・再作成は不要)。
            // `needsReauth`の有無に関わらず常に出す (このヒントは「認証
            // 切れ」ではなく「新しい機能を有効にする」ための案内なので)。
            Text("再接続すると、差出人の Google プロフィール写真 (保存済み連絡先を含む) を表示できるようになります。")
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
            .disabled(isReauthenticating || !environment.isGmailOAuthConfigured)

            // 実機フィードバック: Client ID 未設定のビルド (例: secret 未登録の
            // GitHub Release ビルド) でボタンを押すと `AuthResolutionError
            // .oauthUnavailable` がそのまま出て何が悪いのか伝わらなかった —
            // `AccountTypeSelectionView`と同じく、押す前にボタンを無効化して
            // 理由を明示する。
            if !environment.isGmailOAuthConfigured {
                Text("このビルドには Google OAuth Client ID が設定されていないため、Google 認証は行えません。詳細は docs/oauth-setup.md を参照してください。")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("accountEdit.gmailOAuthUnconfiguredHint")
            }

            GoogleScopeDiagnosisRow(state: scopeDiagnosis)

            if let reauthErrorMessage {
                Label(reauthErrorMessage, systemImage: "xmark.octagon")
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("accountEdit.reauthError")
            }

            // Task #42「アバター診断」(最優先): 実機でまだ Google
            // プロフィール写真が出ない、という報告の原因をユーザー自身の
            // スクリーンショット1枚で確定させるための診断画面への導線。
            NavigationLink("アバター診断") {
                GoogleAvatarDiagnosticsView(account: account)
            }
            .accessibilityIdentifier("accountEdit.avatarDiagnosticsLink")
        }
    }

    /// Task #116 第2段: Outlook.com/Office 365 — mirrors `gmailSections`'
    /// shape (fixed connection preset + a「再認証」button), minus the
    /// Google-specific scope-diagnosis/avatar-diagnostics rows this
    /// provider has no equivalent of.
    @ViewBuilder
    private var microsoftSections: some View {
        Section("接続先 (固定)") {
            LabeledContent("IMAP", value: "\(account.imapHost):\(account.imapPort)")
            if let smtpHostValue = account.smtpHost, let smtpPortValue = account.smtpPort {
                LabeledContent("SMTP", value: "\(smtpHostValue):\(smtpPortValue)")
            }
        }

        Section("認証") {
            Text("Microsoft アカウントでの認証です。パスワードはこのアプリに保存されません。認証が切れた場合は「再認証」から再度サインインしてください。")
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
            .disabled(isReauthenticating || !environment.isMicrosoftOAuthConfigured)

            // gmailSections の同種ヒントと同じ理由 (Client ID 未設定ビルドで
            // `oauthUnavailable` をそのまま見せない)。
            if !environment.isMicrosoftOAuthConfigured {
                Text("このビルドには Microsoft OAuth Client ID が設定されていないため、Microsoft 認証は行えません。詳細は docs/oauth-setup.md を参照してください。")
                    .font(.caption)
                    .foregroundStyle(OtegamiColor.destructive)
                    .accessibilityIdentifier("accountEdit.microsoftOAuthUnconfiguredHint")
            }

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
        case .gmail, .microsoft:
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
        case .gmail, .microsoft:
            // No password-based "接続テスト" for an OAuth account — its
            // `gmailSections`/`microsoftSections` offer「再認証」instead.
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

    /// Shared by `gmailSections`'/`microsoftSections`'「再認証」buttons —
    /// branches on `account.kind` to call the matching provider's reauth
    /// flow. A single `AccountEditView` instance only ever shows one of
    /// those two sections (whichever matches `account.kind`), so sharing
    /// `isReauthenticating`/`reauthErrorMessage` between them is safe: only
    /// one branch's button can ever be the one that triggered this.
    private func reauthenticate() async {
        isReauthenticating = true
        reauthErrorMessage = nil
        defer { isReauthenticating = false }

        do {
            switch account.kind {
            case .gmail:
                try await environment.reauthenticateGmailAccount(account)
            case .microsoft:
                try await environment.reauthenticateMicrosoftAccount(account)
            case .generic, .icloud:
                return
            }
            dismiss()
        } catch AppEnvironment.AuthResolutionError.oauthUnavailable {
            // ボタンは `isGmailOAuthConfigured`/`isMicrosoftOAuthConfigured`
            // が `false` の間disabledなので通常はここに来ないが、値が変わる
            // 競合 (ほぼ起こらない) に備えて防御的に分岐しておく — 生の
            // `oauthUnavailable` という英語の enum 名をユーザーに見せない。
            switch account.kind {
            case .gmail:
                reauthErrorMessage = "このビルドには Google OAuth Client ID が設定されていないため、Google 認証は行えません。詳細は docs/oauth-setup.md を参照してください。"
            case .microsoft:
                reauthErrorMessage = "このビルドには Microsoft OAuth Client ID が設定されていないため、Microsoft 認証は行えません。詳細は docs/oauth-setup.md を参照してください。"
            case .generic, .icloud:
                reauthErrorMessage = "再認証に失敗しました。"
            }
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
                    newPassword: nil,
                    labelColorKey: .some(labelColorKey?.rawValue),
                    defaultSignatureId: .some(defaultSignatureId)
                )
            case .microsoft:
                // Same rationale as `.gmail` just above — nothing but
                // display name is editable for an OAuth account.
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
                    newPassword: nil,
                    labelColorKey: .some(labelColorKey?.rawValue),
                    defaultSignatureId: .some(defaultSignatureId)
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
                    newPassword: newPassword.isEmpty ? nil : newPassword,
                    labelColorKey: .some(labelColorKey?.rawValue),
                    defaultSignatureId: .some(defaultSignatureId)
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
                    newPassword: newPassword.isEmpty ? nil : newPassword,
                    labelColorKey: .some(labelColorKey?.rawValue),
                    defaultSignatureId: .some(defaultSignatureId)
                )
            }
            dismiss()
        } catch {
            saveErrorMessage = "保存に失敗しました: \(error)"
        }
    }

    private var kindLabel: String {
        switch account.kind {
        // 実機観察 (2026-07-29、macOS): システム言語を英語にすると画面の
        // タイトル等は英語になるのに、この値だけ日本語のまま混在していた
        // — 原因はこの`switch`が生の`String`リテラルを返しており、他の
        // 画面の`Text(String)`と違って`String(localized:)`を経由しない
        // ため String Catalog を一切引かなかったこと (`Localizable
        // .xcstrings`には既に"その他 (IMAP)" → "Other (IMAP)"のエントリが
        // 存在済み、単にこの呼び出しが使っていなかっただけ)。
        case .generic: String(localized: "その他 (IMAP)")
        case .gmail: "Gmail"
        case .microsoft: "Microsoft"
        case .icloud: "iCloud"
        }
    }
}

/// 実機バグ修正: `AccountEditView.scopeDiagnosis`が取りうる4状態。
/// トップレベル型にしてある — `AccountEditView`自身に対する
/// `-warn-long-expression-type-checking`の負荷を増やさないため
/// (`docs/ci.md`の「SwiftUI ビューの型チェックタイムアウト」節参照)。
enum GoogleScopeDiagnosisState: Equatable {
    /// まだ問い合わせ中、または `.gmail` 以外のアカウント種別 (この画面
    /// では表示自体がされないので実質観測されない)。
    case checking
    /// `contacts.other.readonly`・`contacts.readonly` の**両方**が
    /// 付与済み — other contacts (自動収集された連絡先) と保存済み連絡先
    /// の両方から Google プロフィール写真を解決できる状態
    /// (`GoogleProfilePhotoAvatarResolver`)。
    case full
    /// `contacts.other.readonly` のみ付与済み・`contacts.readonly` は
    /// 未許可 — このバッチで `contacts.readonly` を追加した時点の既存
    /// アカウントの典型的な状態。other contacts 由来の写真は解決できるが、
    /// 保存済み連絡先の写真には対応できていない。もう一度「再認証」する
    /// ことで解消する。
    case basic
    /// どちらのスコープも付与されていない — 「再認証したのに Google 側で
    /// 付与されていない」実機バグの症状そのもの。ユーザーへの案内は
    /// 「再認証してください」で足りる (再認証自体が機能していれば次で
    /// 解消するはず — 再認証してもなお解消しない場合は Google Cloud
    /// Console 側の OAuth 同意画面設定を疑う必要があるが、それはアプリの
    /// 外側の話なので `docs/oauth-setup.md` の手順に譲る)。
    case notGranted
    /// 問い合わせ自体が失敗した (ネットワークエラー・リフレッシュ
    /// トークン喪失等) — `.notGranted`と違い「許可されていない」とは
    /// 断定できないので、区別して表示する。
    case unknown

    /// `AccountEditView.refreshScopeDiagnosis`と`GoogleAvatarDiagnosticsView`
    /// (Task #42「アバター診断」) の両方が同じスコープ文字列判定ロジックを
    /// 必要とするため、ここに1本化した — 判定基準
    /// (`contacts.other.readonly`/`contacts.readonly`の有無) を2箇所に
    /// 書いて食い違わせるリスクを避ける。
    static func diagnose(scope: String) -> GoogleScopeDiagnosisState {
        let hasOtherContacts = scope.contains("contacts.other.readonly")
        let hasConnections = scope.contains("auth/contacts.readonly")
        switch (hasOtherContacts, hasConnections) {
        case (true, true): return .full
        case (true, false): return .basic
        case (false, _): return .notGranted
        }
    }
}

/// 実機バグ修正: 「アカウント編集」→ Gmail アカウントの「認証」節に出す
/// 診断行。ユーザーが実機で撮ったスクリーンショット1枚 (Google 側の
/// myaccount.google.com/connections) だけが頼りだった状態から、アプリ内
/// の1タップで「連絡先スコープが付与されているか」を確認できるようにする
/// のが狙い。
struct GoogleScopeDiagnosisRow: View {
    let state: GoogleScopeDiagnosisState

    var body: some View {
        switch state {
        case .checking:
            HStack {
                Text("権限を確認中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
            .accessibilityIdentifier("accountEdit.scopeDiagnosis.checking")
        case .full:
            Label("連絡先の写真: 許可済み (完全)", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("accountEdit.scopeDiagnosis.full")
        case .basic:
            Label("連絡先の写真: 許可済み (基本) — 保存済み連絡先には未対応。「再認証」をお試しください", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("accountEdit.scopeDiagnosis.basic")
        case .notGranted:
            Label("連絡先の写真: 未許可 — 「再認証」をお試しください", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(OtegamiColor.destructive)
                .accessibilityIdentifier("accountEdit.scopeDiagnosis.notGranted")
        case .unknown:
            Label("権限を確認できませんでした", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("accountEdit.scopeDiagnosis.unknown")
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
