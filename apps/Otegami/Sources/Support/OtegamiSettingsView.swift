import SwiftUI

#if os(macOS)
/// M10 (plan: "Settings ウィンドウ (macOS 標準 Settings scene) にアカウント/プッシュ
/// 設定を整理"). Backs `OtegamiApp`'s `Settings { }` scene (⌘,/App menu →
/// Settings…) — the platform-conventional place a macOS user expects an
/// app's preferences, distinct from (and in addition to, not replacing) the
/// gear-icon sheet `SidebarView` already opens on both platforms.
///
/// Task #155 (2026-07-29, 実機報告「v1.1.0-beta の設定画面が使い物に
/// ならないくらい崩れている」): 直近の「設定画面の5カテゴリ化」(iOS向け、
/// `AccountsListContent`のカテゴリ一覧 +`NavigationLink`push) をmacOSの
/// この`Settings`シーンにもそのまま持ち込んだところ (「設定」/「情報」の
/// 2タブの`TabView`、「設定」タブの中身が`AccountsListContent`のカテゴリ
/// 一覧からさらにpush)、実機 (CGEvent/AXから合成した本物のクリック・
/// `@Environment(\.dismiss)`の両方) で検証して次の**致命的な**不具合を
/// 確認した:
///
/// - `TabView`にホストされた`NavigationStack`で`NavigationLink`を1段
///   pushすると、自動生成される戻るボタンをクリックしても、明示的に
///   `dismiss()`を呼ぶボタンを追加しても、まったくpopが起きない —
///   ユーザーは一度カテゴリを開くと二度と戻れず、ウィンドウを閉じる
///   (Settingsシーンごと終了する) しかなくなる。カテゴリが「アカウント
///   一覧」1つだけだった頃はこの経路をほぼ使わなかったため気づかれて
///   いなかったが、5カテゴリ化で全カテゴリが影響を受けるようになった。
///
/// 対策として一度「カテゴリ行はシートで開く」形に直したが、ユーザー
/// 指示で「iOSのカテゴリ一覧+pushの構造をmacOSに持ち込むのをやめ、
/// mac らしいサイドバー構成に作り直す」方針に転換した。`NavigationSplitView`
/// (左にカテゴリのサイドバー、右にdetail) はそもそも`NavigationStack`を
/// `TabView`にネストしないので、上の不具合が起きる構造自体が無くなる。
/// detail側のさらに奥の遷移 (アカウント編集・ツールバーカスタマイズ等)
/// は detail 側の独立した`NavigationStack`のpushなので、上の不具合の
/// 対象にならない (`AccountsSettingsView`のシート — ハンバーガーメニュー
/// 経由 — と同じ「`TabView`の外にある`NavigationStack`」という形であり、
/// そちらは実機で問題なく動くことを確認済み)。
///
/// 「情報」(`AboutView`) タブは廃止した — サイドバー構成に自然に収まる
/// 場所が無く、「このアプリについて」的な情報はメニューバーの
/// 「Otegami」→「Otegamiについて」で代替可能なため。この画面 (設定
/// サイドバー) からは今も参照しない — Task #182 (macOS アプリ内アップ
/// デート) で「Otegamiについて」の中身自体は標準の`NSApplication`About
/// panel から`AboutView`(バージョン情報+アップデート確認/インストール
/// UI) に差し替わったが、それは`OtegamiCommands`/`OtegamiApp`の
/// `WindowGroup(id: "about")`が担う話であり、この設定画面の構成には
/// 影響しない。
struct OtegamiSettingsView: View {
    var body: some View {
        MacSettingsSplitView()
            // サイドバー+detailの2カラムが窮屈にならない最小サイズ。
            // 以前の`TabView`版が持っていた`480x420`より広め — detailに
            // 表示する`AccountSettingsCategoryView`等のリストは元々iOS の
            // 画面幅を想定した行レイアウトで、480ptだと窮屈だった
            // (Task #155で実機スクリーンショットにより確認)。
            .frame(minWidth: 720, minHeight: 480)
    }
}

/// macOS 設定画面のカテゴリ — サイドバーの各行とdetailの対応表。
/// 一覧・並び順は iOS の`AccountsListContent`(実機フィードバック第4弾:
/// アカウント→メール一覧→メールビューア→メール作成) と揃えている。
private enum MacSettingsCategory: String, CaseIterable, Identifiable {
    case accounts
    case mailList
    case mailViewer
    case mailCompose

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .accounts: "アカウントの設定"
        case .mailList: "メール一覧"
        case .mailViewer: "メールビューア"
        case .mailCompose: "メール作成"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .mailList: "list.bullet"
        case .mailViewer: "envelope.open"
        case .mailCompose: "square.and.pencil"
        }
    }
}

/// 左にカテゴリのサイドバー、右に選択カテゴリの設定 — mac の「システム
/// 設定」に近い見た目・操作感。`OtegamiSettingsView`の doc comment が
/// 説明する通り、detail側の`NavigationStack`はこの`NavigationSplitView`
/// にネストされるだけで`TabView`の中には入らないため、押し込み
/// (`NavigationLink`のpush) も戻る操作も通常どおり動く。
private struct MacSettingsSplitView: View {
    @State private var selection: MacSettingsCategory? = .accounts

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(MacSettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                        .accessibilityIdentifier("settings.category.\(category.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            // `.id(selection)`: サイドバーでカテゴリを切り替えるたびに
            // detailの`NavigationStack`を作り直し、前のカテゴリで奥まで
            // pushしていた状態 (例: アカウント編集) を持ち越さない —
            // 「システム設定」でカテゴリを切り替えると常にそのカテゴリの
            // 先頭画面に戻る、という標準的な挙動に揃えている。
            NavigationStack {
                detailView(for: selection ?? .accounts)
            }
            .id(selection)
        }
        .accessibilityIdentifier("settings.macOS.splitView")
    }

    @ViewBuilder
    private func detailView(for category: MacSettingsCategory) -> some View {
        switch category {
        case .accounts: AccountSettingsCategoryView()
        case .mailList: MailListSettingsView()
        case .mailViewer: MailViewerSettingsView()
        case .mailCompose: MailComposeSettingsView()
        }
    }
}
#endif
