import SwiftUI

/// The first screen of "アカウントを追加" (M6, plan: "種別選択: Gmail / iCloud /
/// その他 (IMAP)") — replaces M1–M5's direct jump into `AccountSetupView`.
/// Presented as the *only* sheet in the add-account flow: `SidebarView`/
/// `AccountsSettingsView` bind a single `AccountEntryRoute?` to one
/// `.sheet(item:)`, and this view's three buttons just change that route to
/// swap the sheet's *content* (`GmailAccountSetupView`/`ICloudAccountSetupView`/
/// `AccountSetupView`) rather than presenting a nested sheet on top of this
/// one — see `AccountEntryRoute`'s doc comment for why that matters: it's
/// what lets each destination form's own `@Environment(\.dismiss)` (used
/// completely unchanged from M1–M5) close the *entire* add-account flow on
/// save, not just pop back to this picker.
struct AccountTypeSelectionView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var onSelectGmail: () -> Void
    var onSelectICloud: () -> Void
    var onSelectYahoo: () -> Void
    var onSelectYahooJapan: () -> Void
    var onSelectOutlook: () -> Void
    var onSelectOffice365: () -> Void
    var onSelectExchange: () -> Void
    var onSelectOther: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    gmailButton
                    icloudButton
                    yahooButton
                    yahooJapanButton
                    outlookButton
                    office365Button
                    exchangeButton
                    otherButton
                } header: {
                    Text("アカウントの種類")
                } footer: {
                    Text("Gmail・iCloud・Yahoo・Yahoo! JAPAN・Outlook・Office365・Exchange はホスト設定が自動で入力されます。それ以外のプロバイダは「その他」から手動で設定してください。")
                }
            }
            .navigationTitle("アカウントを追加")
            .scrollContentBackground(.hidden)
            .background(OtegamiColor.background)
            .tint(OtegamiColor.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("accountTypeSelection.cancelButton")
                }
            }
        }
        .accessibilityIdentifier("accountTypeSelection.sheet")
        #if os(macOS)
        // M10 fix: unlike iOS, macOS doesn't size a `.sheet` from its
        // `NavigationStack { List { ... } }` content's intrinsic size — a
        // freshly-presented sheet built this way (confirmed by launching
        // the real macOS app, not just `make mac` build-checking it, which
        // is all M6–M9 ever did per docs/verify.md) renders as basically
        // just its title bar and toolbar, with the `List` collapsed to
        // near-zero height. An explicit minimum frame is the fix every
        // sheet in this app built the same way needs (see
        // `AccountSetupView`/`GmailAccountSetupView`/`ICloudAccountSetupView`/
        // `AccountsSettingsView`/`OutboxView`/`DraftsView`/
        // `FailedOperationsView`, all patched alongside this one).
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    // Task #116: split into per-button computed properties (docs/ci.md's
    // "SwiftUI ビューは小さく保つこと") — this `Section` grew from 3 buttons
    // to 6 (7 once 第2段 adds Outlook/Office365), and a flat `Button { ... }
    // .modifier() .modifier()` chain repeated inline for each one risks the
    // same CI type-check timeout `AccountSetupView`'s own split already
    // guards against.
    private var gmailButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onSelectGmail()
            } label: {
                Label("Gmail", systemImage: "envelope.badge")
            }
            .accessibilityIdentifier("accountTypeSelection.gmailButton")
            .disabled(!environment.isGmailOAuthConfigured)

            if !environment.isGmailOAuthConfigured {
                Text("この配布ビルドには Google OAuth Client ID が設定されていません。docs/oauth-setup.md を参照して各自 Client ID を発行し、Config/Local.xcconfig に設定してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("accountTypeSelection.gmailDisabledHint")
            }
        }
    }

    private var icloudButton: some View {
        Button {
            onSelectICloud()
        } label: {
            Label("iCloud", systemImage: "icloud")
        }
        .accessibilityIdentifier("accountTypeSelection.icloudButton")
    }

    private var yahooButton: some View {
        Button {
            onSelectYahoo()
        } label: {
            Label("Yahoo", systemImage: "envelope.badge")
        }
        .accessibilityIdentifier("accountTypeSelection.yahooButton")
    }

    private var yahooJapanButton: some View {
        Button {
            onSelectYahooJapan()
        } label: {
            Label("Yahoo! JAPAN", systemImage: "envelope.badge")
        }
        .accessibilityIdentifier("accountTypeSelection.yahooJapanButton")
    }

    // Task #116 第2段: Outlook/Office365 mirror `gmailButton`'s
    // disabled+hint shape (both are OAuth-only, so both need the same
    // "Client ID not configured" affordance) — see `AppEnvironment
    // .isMicrosoftOAuthConfigured`.
    private var outlookButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onSelectOutlook()
            } label: {
                Label("Outlook", systemImage: "envelope.badge")
            }
            .accessibilityIdentifier("accountTypeSelection.outlookButton")
            .disabled(!environment.isMicrosoftOAuthConfigured)

            if !environment.isMicrosoftOAuthConfigured {
                Text("この配布ビルドには Microsoft OAuth Client ID が設定されていません。docs/oauth-setup.md を参照して各自 Client ID を発行し、Config/Local.xcconfig に設定してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("accountTypeSelection.outlookDisabledHint")
            }
        }
    }

    private var office365Button: some View {
        Button {
            onSelectOffice365()
        } label: {
            Label("Office365", systemImage: "envelope.badge")
        }
        .accessibilityIdentifier("accountTypeSelection.office365Button")
        .disabled(!environment.isMicrosoftOAuthConfigured)
    }

    private var exchangeButton: some View {
        Button {
            onSelectExchange()
        } label: {
            Label("Exchange", systemImage: "building.2")
        }
        .accessibilityIdentifier("accountTypeSelection.exchangeButton")
    }

    private var otherButton: some View {
        Button {
            onSelectOther()
        } label: {
            Label("その他 (IMAP)", systemImage: "server.rack")
        }
        .accessibilityIdentifier("accountTypeSelection.otherButton")
    }
}

/// Drives the single `.sheet(item:)` `SidebarView`/`AccountsSettingsView`
/// each own for the whole add-account flow (picker → the chosen form). A
/// plain `Identifiable` enum rather than three separate `@State private var
/// showingX: Bool`s specifically so changing *which* case is bound doesn't
/// dismiss-then-represent a new sheet — see `AccountTypeSelectionView`'s
/// doc comment.
enum AccountEntryRoute: String, Identifiable {
    case typeSelection
    case gmail
    case icloud
    case yahoo
    case yahooJapan
    case outlook
    case office365
    case exchange
    case other

    var id: String { rawValue }
}

/// Shared by `SidebarView` and `AccountsSettingsView` — both own an
/// identical `@State private var accountEntryRoute: AccountEntryRoute?`
/// feeding a `.sheet(item:)` (matching the pre-existing, pre-M6 duplication
/// pattern where both already independently owned a `showingAccountSetup`
/// `Bool`), so this one `@ViewBuilder` function is what keeps the
/// route→view mapping itself defined in exactly one place.
@ViewBuilder
func accountEntryDestination(for route: AccountEntryRoute, binding: Binding<AccountEntryRoute?>) -> some View {
    switch route {
    case .typeSelection:
        AccountTypeSelectionView(
            onSelectGmail: { binding.wrappedValue = .gmail },
            onSelectICloud: { binding.wrappedValue = .icloud },
            onSelectYahoo: { binding.wrappedValue = .yahoo },
            onSelectYahooJapan: { binding.wrappedValue = .yahooJapan },
            onSelectOutlook: { binding.wrappedValue = .outlook },
            onSelectOffice365: { binding.wrappedValue = .office365 },
            onSelectExchange: { binding.wrappedValue = .exchange },
            onSelectOther: { binding.wrappedValue = .other }
        )
    case .gmail:
        GmailAccountSetupView()
    case .icloud:
        ICloudAccountSetupView()
    case .yahoo:
        YahooAccountSetupView()
    case .yahooJapan:
        YahooJapanAccountSetupView()
    case .outlook:
        MicrosoftAccountSetupView(provider: .outlookCom)
    case .office365:
        MicrosoftAccountSetupView(provider: .office365)
    case .exchange:
        AccountSetupView(preset: .exchange)
    case .other:
        AccountSetupView()
    }
}
