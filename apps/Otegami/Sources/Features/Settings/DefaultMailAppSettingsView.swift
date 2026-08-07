import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings → アカウントの設定 → 「デフォルトのメールアプリに設定」
/// (Task #48, docs/default-mail-app.md). What "default" actually requires
/// differs by platform, confirmed against Apple's own documentation:
///
/// - **iOS/iPadOS**: gated on the `com.apple.developer.mail-client`
///   entitlement (Apple-granted per-app, `platforms: [iOS, iPadOS,
///   visionOS]` per Apple's entitlement reference — no macOS listing at
///   all), which this app only carries when built with
///   `OTEGAMI_MAIL_CLIENT_ENTITLEMENT = YES` (Config/Shared.xcconfig).
///   `isMailClientEntitlementEnabled` reads the Info.plist flag
///   project.yml derives from that same xcconfig switch, so this view can
///   never show a shortcut into a picker this build isn't actually
///   eligible to appear in.
/// - **macOS**: no special entitlement involved at all — Launch Services
///   has offered "which app handles `mailto:`" (Mail's own Settings →
///   General → "Default Mail App Reader" popup, or System Settings →
///   Desktop & Dock → Default web browser's sibling row) to any app that
///   simply declares the `mailto` scheme in `CFBundleURLTypes`
///   (project.yml, applied to both destinations) for as long as that
///   preference pane has existed — there's no programmatic "open this
///   settings pane" API to call, so this just tells the user where to
///   look.
struct DefaultMailAppSettingsView: View {
    @Environment(\.openURL) private var openURL

    /// See this type's doc comment — `project.yml`'s
    /// `OtegamiMailClientEntitlementEnabled` Info.plist key mirrors
    /// `OTEGAMI_MAIL_CLIENT_ENTITLEMENT`, and (that key's own doc comment)
    /// is written as the literal string `"YES"`/`"NO"`, not a real
    /// Info.plist Boolean.
    private var isMailClientEntitlementEnabled: Bool {
        (Bundle.main.infoDictionary?["OtegamiMailClientEntitlementEnabled"] as? String) == "YES"
    }

    var body: some View {
        settingsContainer
            .navigationTitle("既定のメールアプリ")
    }

    /// Task #155: see `MailListSettingsView`'s identical doc comment on
    /// this same property.
    @ViewBuilder
    private var settingsContainer: some View {
        #if os(macOS)
        Form {
            sections
        }
        .formStyle(.grouped)
        #else
        List {
            sections
        }
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            Text("Otegami を既定のメールアプリに設定すると、他のアプリの「メールで送信」リンクや mailto: リンクを開いたときに Otegami が開くようになります。")
                .foregroundStyle(OtegamiColor.inkSecondary)
        }

        #if os(iOS)
        iOSSection
        #else
        macOSSection
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSSection: some View {
        if isMailClientEntitlementEnabled {
            Section {
                Button {
                    guard let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("設定 Appで既定のメールアプリを選ぶ", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.defaultMailApp.openSettingsButton")
            } footer: {
                Text("「設定」→「アプリ」→「既定のアプリ」→「メール」から Otegami を選んでください。")
            }
        } else {
            Section {
                Label("Apple の承認待ちです", systemImage: "clock")
                    .foregroundStyle(OtegamiColor.inkSecondary)
                    .accessibilityIdentifier("settings.defaultMailApp.pendingApprovalNotice")
            } footer: {
                Text("iOS で既定のメールアプリになるには、Apple から com.apple.developer.mail-client の権限を取得する必要があります。この機能は権限が承認され、このビルドで有効化された後に使えるようになります。")
            }
        }
    }
    #else
    private var macOSSection: some View {
        Section {
            Text("メニューバーの「メール」アプリ (Mail) を開き、「メール」→「設定」→「一般」の「デフォルトのメールアプリ」から Otegami を選べます。バージョンによっては「システム設定」→「デスクトップと Dock」の「メールアプリ」の項目からも変更できます。")
                .foregroundStyle(OtegamiColor.inkSecondary)
        }
        .accessibilityIdentifier("settings.defaultMailApp.macOSInstructions")
    }
    #endif
}

#Preview {
    NavigationStack {
        DefaultMailAppSettingsView()
    }
}
