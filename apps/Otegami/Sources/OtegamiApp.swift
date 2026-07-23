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

/// Three-pane scaffold (sidebar / message list / detail). Content is all
/// placeholder until the sync engine and store land (M1+).
struct RootView: View {
    @State private var selectedMailbox: String? = "unifiedInbox"

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedMailbox) {
                Label("統合受信トレイ", systemImage: "tray.full")
                    .tag("unifiedInbox")
            }
            .navigationTitle("Otegami")
        } content: {
            List {
                // Message list is populated once SyncEngine/OtegamiStore
                // exist (M1+).
            }
            .navigationTitle("Inbox")
            .overlay {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "envelope",
                    description: Text("Add an account to get started.")
                )
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
