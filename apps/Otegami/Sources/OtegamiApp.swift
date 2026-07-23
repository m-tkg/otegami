import SwiftUI

@main
struct OtegamiApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

/// Three-pane scaffold: account/mailbox sidebar, the selected mailbox's
/// message list, and a still-placeholder detail pane (message body reading
/// lands in M2). Sidebar and message list are both backed by live GRDB
/// `ValueObservation`s via `AppEnvironment`/`AppDatabase`.
struct RootView: View {
    @State private var selection: MailboxSelection?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } content: {
            if let selection {
                MessageListView(selection: selection)
            } else {
                ContentUnavailableView(
                    "メールボックスを選択してください",
                    systemImage: "tray",
                    description: Text("左のサイドバーからアカウントを追加、またはメールボックスを選択してください。")
                )
                .navigationTitle("Inbox")
            }
        } detail: {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope.open"
            )
        }
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment())
}
