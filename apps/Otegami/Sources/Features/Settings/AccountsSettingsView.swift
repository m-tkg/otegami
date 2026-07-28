import SwiftUI
import OtegamiStore

/// Settings → account list (M4 plan: "設定にアカウント一覧 + 追加/削除"). The sheet
/// macOS's `SidebarView` gear-icon button opens (iOS now opens
/// `SettingsSheetView` instead, from the hamburger menu — 新画面構成 (1));
/// wraps `AccountsListContent` in its own `NavigationStack` + "閉じる"
/// toolbar button (a sheet needs an explicit close affordance). See
/// `AccountsListContent`'s doc comment for why the actual list lives in its
/// own type now.
struct AccountsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountsListContent()
                .navigationTitle("設定")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // タスク#43: 文字ボタンをxmarkアイコンのみに変更 —
                        // ハンバーガーメニュー (`FolderListSheet`)/
                        // `SettingsSheetView`の閉じるボタンと同じ流儀。
                        // accessibility identifier は既存を維持
                        // (UITest 互換)。
                        Button { dismiss() } label: {
                            Label("閉じる", systemImage: "xmark")
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("settings.closeButton")
                    }
                }
        }
        .accessibilityIdentifier("settings.sheet")
        #if os(macOS)
        // M10 fix: see AccountTypeSelectionView's doc comment on why every
        // NavigationStack{List{...}}-shaped sheet in this app needs this.
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}

/// I「設定画面の再構成」: 設定のルート画面。以前はここに全設定 (アカウント
/// 一覧・スワイプ・翻訳・画像・etc.) がフラットな`List`として並んでいたが、
/// ユーザー指定のカテゴリ構造に沿ってサブ画面へ分割した — 各設定項目
/// の実体 (`@AppStorage`キー等) は移動していない。
///
/// 実機フィードバック第3弾 (I): 当初の5分類 (アカウントの設定/メール
/// ビューア/メール一覧/署名テンプレート/その他) を4分類に再編した —
/// 「その他」は雑多な置き場になっていた項目 (iCloud同期・プッシュ通知・
/// 画像・HTML表示・ピン留め連動・スレッド表示・テンプレート・送信
/// キャンセル) を性質の近い既存カテゴリへ再配置した結果、残るのは
/// 「このアプリについて」だけになったため廃止し、ルート直下の項目に格上げ
/// した。ルート直下の「署名テンプレート」は新設「メール作成」カテゴリへ
/// 統合した (`MailComposeSettingsView`の doc comment参照)。各項目の移設先
/// は以下のとおり:
///
/// - **アカウントの設定** (`AccountSettingsCategoryView`) ← iCloud同期・
///   プッシュ通知を追加。
/// - **メールビューア** (`MailViewerSettingsView`) ← 画像設定・HTML表示
///   設定を追加。
/// - **メール一覧** (`MailListSettingsView`) ← スレッド表示・ピン留めの
///   フラグ連動を追加。
/// - **メール作成** (`MailComposeSettingsView`、新設) ← テンプレート・
///   署名テンプレート・送信キャンセルの猶予。
/// - **このアプリについて** (`AboutView`) — ルート直下 (iOS のみ。macOS は
///   `OtegamiSettingsView`の独立した「情報」タブに既にあるため、ここに
///   重複させない)。
///
/// `AccountsListContent`という型名は維持している (`OtegamiSettingsView`
/// (macOS Settings シーン) がこの型を直接埋め込む既存の配線を変更せずに
/// 済むため) が、中身は「アカウント一覧」ではなく「カテゴリ一覧」に
/// 変わった — M10 時点のこの型の doc comment (nested `NavigationStack`が
/// macOS `TabView`と衝突する話) はそのまま有効: このルートも各カテゴリも
/// 独自の`NavigationStack`を持たず、埋め込まれた側の`NavigationStack`
/// (`AccountsSettingsView`の、または`OtegamiSettingsView`の"設定"タブの)
/// にそのまま`NavigationLink`で積み上がる。
struct AccountsListContent: View {
    /// Task #72: tap-free navigation for `scripts/verify-screen.sh`,
    /// mirroring `MailScreenView`'s `-uitestsOpenSettingsDirectly` hook
    /// (see its doc comment) — pushes straight to
    /// `AccountSettingsCategoryView` so a screenshot of the account list
    /// (the new per-row color dot) doesn't need a real tap on this row.
    /// A no-op (`false`, and the `.task` below never flips it) on every
    /// real launch.
    @State private var uitestShowAccountSettingsDirectly = false

    /// Task #100: same tap-free idea, for `scripts/verify-screen.sh`
    /// screenshots of `MailViewerSettingsView` (and, one screen further via
    /// its own `-uitestsOpenToolbarCustomizeDirectly` hook, the toolbar
    /// customize screen) without a real tap on this row.
    @State private var uitestShowMailViewerSettingsDirectly = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AccountSettingsCategoryView()
                } label: {
                    Label("アカウントの設定", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings.category.accounts")

                NavigationLink {
                    MailViewerSettingsView()
                } label: {
                    Label("メールビューア", systemImage: "envelope.open")
                }
                .accessibilityIdentifier("settings.category.mailViewer")

                NavigationLink {
                    MailListSettingsView()
                } label: {
                    Label("メール一覧", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("settings.category.mailList")

                NavigationLink {
                    MailComposeSettingsView()
                } label: {
                    Label("メール作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("settings.category.mailCompose")
            }

            #if os(iOS)
            // 実機フィードバック第3弾 (I): 「その他」廃止に伴いルート直下へ
            // 格上げ — macOS は `OtegamiSettingsView` の独立した「情報」
            // タブに既にあるので、ここでは重複させない。
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.aboutLink")
            }
            #endif
        }
        .navigationDestination(isPresented: $uitestShowAccountSettingsDirectly) {
            AccountSettingsCategoryView()
        }
        .navigationDestination(isPresented: $uitestShowMailViewerSettingsDirectly) {
            MailViewerSettingsView()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenAccountSettingsDirectly") {
                uitestShowAccountSettingsDirectly = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenMailViewerSettingsDirectly") {
                uitestShowMailViewerSettingsDirectly = true
            }
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
