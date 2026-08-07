import SwiftUI
import GRDB
import OtegamiStore

/// メールボックス単位の非表示。`AccountEditView`の「メールボックス」セクション
/// から遷移する新規画面 (指示どおり「`AccountEditView`から辿れる新規画面が
/// 安全」)。主用途は Gmail の `[Gmail]/すべてのメール`のような大量フォルダを
/// ハンバーガー/サイドバーのツリーから隠すこと — `MailboxRecord.isHidden`の
/// ドキュメントコメント参照。
///
/// - 非表示にすると: ツリーから消える (`MailboxQuery.request(accountId:
///   includeHidden: false)`)、統合受信トレイの集計から外れる
///   (`ThreadQuery.unifiedInboxRequest`等)、**同期も止まる**
///   (`AccountSyncer.performIncrementalSync`の`.all`スコープが除外)。
/// - 判断: 同期を止める理由は電池・通信の節約 — 特に Gmail の「すべての
///   メール」は INBOX の全メッセージを重複して含む巨大フォルダで、同期し
///   続ける実利が薄い。一方、**移動先ピッカーからは除外しない** (このアプリ
///   に汎用の移動先ピッカー自体がまだ無く、次フェーズの課題 — `docs/
///   design-system.md`「次フェーズへの申し送り」参照。実装される際は
///   `MailboxQuery.request(accountId:)`の既定`includeHidden: true`を使う
///   想定) — 「表示したくない」と「操作対象として選べなくしたい」は別の
///   要求で、後者まで一緒に潰すと「非表示にしたメールボックスへは二度と
///   メールを移動できない」という意図しない制約になってしまうため。
struct MailboxVisibilityView: View {
    @Environment(AppEnvironment.self) private var environment

    let account: AccountRecord

    @State private var mailboxes: [MailboxRecord] = []

    var body: some View {
        settingsContainer
            .navigationTitle("メールボックスの表示設定")
            .accessibilityIdentifier("mailboxVisibility.screen")
            .task { await observeMailboxes() }
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
        .toggleStyle(.switch)
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
            ForEach(mailboxes) { mailbox in
                MailboxVisibilityRow(
                    mailbox: mailbox,
                    onToggle: { isVisible in toggleVisibility(mailbox: mailbox, isVisible: isVisible) }
                )
            }
        } footer: {
            Text("非表示にしたメールボックスは、ハンバーガーメニュー/サイドバーの一覧と統合受信トレイの集計に出なくなり、同期も止まります（電池・通信の節約のためです）。メールの移動先としては引き続き選べます。")
        }
    }

    private func observeMailboxes() async {
        let observation = MailboxQuery.observation(accountId: account.id, includeHidden: true)
        do {
            for try await mailboxes in observation.values(in: environment.database.dbWriter) {
                self.mailboxes = mailboxes
            }
        } catch {
            // A failing observation just leaves the last-known list on screen.
        }
    }

    private func toggleVisibility(mailbox: MailboxRecord, isVisible: Bool) {
        guard let mailboxId = mailbox.id else { return }
        Task {
            try? await environment.database.dbWriter.write { db in
                try MailboxQuery.setHidden(mailboxId: mailboxId, hidden: !isVisible, db: db)
            }
        }
    }
}

/// `MailboxVisibilityView`の`ForEach`本体を切り出した1行 — `docs/ci.md`が
/// 警告する「`List`/`ForEach`の中身は独立した`View`型に切り出す」方針
/// (`CLAUDE.md`)。
private struct MailboxVisibilityRow: View {
    let mailbox: MailboxRecord
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(mailbox.displayPath, isOn: Binding(
            get: { !mailbox.isHidden },
            set: onToggle
        ))
        .accessibilityIdentifier("mailboxVisibility.toggle.\(mailbox.id.map(String.init) ?? mailbox.path)")
    }
}
