import SwiftUI
import MicrosoftOAuth

/// Task #116 第2段: which of the two Microsoft entry points on
/// `AccountTypeSelectionView` opened this form — Outlook.com (personal
/// Microsoft accounts) vs. Office365 (work/school accounts). Purely a
/// display distinction: both resolve to the exact same
/// `MicrosoftOAuthEndpoints` (the `common` tenant covers both account
/// types, `MicrosoftOAuthEndpoints.authorizationEndpoint`'s doc comment)
/// and the exact same `AppEnvironment.createMicrosoftAccount` call — there
/// is no server-side branch anywhere in this form based on which case is
/// passed in.
enum MicrosoftAccountProvider {
    case outlookCom
    case office365

    var navigationTitle: LocalizedStringKey {
        switch self {
        case .outlookCom: "Outlook アカウントを追加"
        case .office365: "Office365 アカウントを追加"
        }
    }

    var explanationText: LocalizedStringKey {
        switch self {
        case .outlookCom: "Microsoft のログイン画面が表示されます。個人の Outlook.com / Hotmail アカウントでサインインしてください。"
        case .office365: "Microsoft のログイン画面が表示されます。会社・学校の Microsoft 365 アカウントでサインインしてください。"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .outlookCom: "outlookAccountSetup"
        case .office365: "office365AccountSetup"
        }
    }
}

/// Outlook.com/Office 365's account-creation form (Task #116 第2段) —
/// mirrors `GmailAccountSetupView`'s shape almost exactly (OAuth-only,
/// nothing to type but an optional display name + the sign-in button)
/// since both are "run an interactive OAuth flow, save the account the
/// provider reports" forms. The differences from Gmail's version:
///
/// - Reads `environment.isMicrosoftOAuthConfigured` instead of
///   `isGmailOAuthConfigured` (`AccountTypeSelectionView` already disables
///   the Outlook/Office365 buttons the same way it disables Gmail's when
///   unconfigured, so this screen shouldn't normally be reachable in that
///   state either — same "shouldn't be reachable, handled anyway" posture
///   as `AppEnvironment.AuthResolutionError.oauthUnavailable`).
/// - `provider` only changes copy (title/explanation/accessibility
///   prefixes) — see `MicrosoftAccountProvider`'s doc comment.
///
/// **Not exercised by any verify script**: same reasoning as
/// `GmailAccountSetupView` — a real browser OAuth round trip needs a real
/// Azure AD app registration and test account, neither of which exists in
/// this repo (OSS Client ID problem, mirrors Gmail's — see
/// `docs/oauth-setup.md`'s Microsoft section).
struct MicrosoftAccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let provider: MicrosoftAccountProvider

    @State private var displayName = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(provider.explanationText)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                }

                Section("アカウント") {
                    LabeledContent("表示名") {
                        TextField("省略時はメールアドレス", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("\(provider.accessibilityPrefix).displayName")
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Microsoft でログイン")
                            if isSigningIn { Spacer(); ProgressView() }
                        }
                    }
                    .accessibilityIdentifier("\(provider.accessibilityPrefix).signInButton")
                    .disabled(isSigningIn || !environment.isMicrosoftOAuthConfigured)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon")
                            .foregroundStyle(OtegamiColor.destructive)
                            .accessibilityIdentifier("\(provider.accessibilityPrefix).errorMessage")
                    }
                }
            }
            .navigationTitle(provider.navigationTitle)
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("\(provider.accessibilityPrefix).cancelButton")
                }
            }
        }
        .accessibilityIdentifier("\(provider.accessibilityPrefix).sheet")
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
            let (email, tokens) = try await environment.requestMicrosoftAuthorization()
            try await environment.createMicrosoftAccount(email: email, displayName: displayName, tokens: tokens)
            dismiss()
        } catch MicrosoftOAuthError.userCancelled {
            // The user dismissed Microsoft's sign-in sheet — not an error
            // worth a banner, matches `GmailAccountSetupView`'s identical
            // handling.
        } catch {
            errorMessage = "サインインに失敗しました: \(error)"
        }
    }
}
