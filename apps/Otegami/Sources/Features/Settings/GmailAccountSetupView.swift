import SwiftUI
import GoogleOAuth

/// Gmail's account-creation form (M6, plan step "Gmail: OAuth フロー →
/// 成功でメールアドレス取得 → imap.gmail.com:993 / smtp.gmail.com:587 プリセットで
/// account 保存"). Unlike `AccountSetupView`/`ICloudAccountSetupView` there's
/// almost nothing to type here — the whole flow is one button that runs
/// `ASWebAuthenticationSession` (via `AppEnvironment.requestGmailAuthorization()`)
/// and, on success, saves the account itself
/// (`AppEnvironment.createGmailAccount(email:displayName:tokens:)`) using the
/// address Google reports rather than anything typed in this form — the one
/// exception is the optional 表示名 field below, which has to be collected
/// *before* signing in (Google's response only reveals the email address,
/// never a display name), and falls back to that email if left blank, same
/// as `AccountSetupView`/`ICloudAccountSetupView`.
///
/// **Not exercised by `scripts/verify-ios-m6.sh`**: the plan is explicit
/// that a real browser OAuth round trip is out of automated-verification
/// scope (no throwaway Google test account exists — see `PENDING.md`), and
/// `AccountTypeSelectionView` disables the Gmail button entirely whenever
/// `GOOGLE_OAUTH_CLIENT_ID` is unset (the dev/CI default), so this view is
/// unreachable in that state and the automated suite never has to drive it.
struct GmailAccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Google のログイン画面が表示されます。otegami はメールの送受信に必要な権限のみをリクエストします。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("アカウント") {
                    // H (実機フィードバック第3弾) — persistent label instead
                    // of a placeholder-only field (`AccountEditView`'s
                    // identical fix's doc comment).
                    LabeledContent("表示名") {
                        TextField("省略時はメールアドレス", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("gmailAccountSetup.displayName")
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Google でログイン")
                            if isSigningIn { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("gmailAccountSetup.signInButton")
                    .disabled(isSigningIn || !environment.isGmailOAuthConfigured)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon")
                            .foregroundStyle(OtegamiColor.destructive)
                            .accessibilityIdentifier("gmailAccountSetup.errorMessage")
                    }
                }
            }
            .navigationTitle("Gmail アカウントを追加")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("gmailAccountSetup.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("gmailAccountSetup.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{...}-shaped sheet in this app needs this.
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            let (email, tokens) = try await environment.requestGmailAuthorization()
            try await environment.createGmailAccount(email: email, displayName: displayName, tokens: tokens)
            dismiss()
        } catch GoogleOAuthError.userCancelled {
            // The user dismissed Google's consent sheet — not an error
            // worth a banner, just leave the form as-is so they can retry.
        } catch {
            errorMessage = "サインインに失敗しました: \(error)"
        }
    }
}
