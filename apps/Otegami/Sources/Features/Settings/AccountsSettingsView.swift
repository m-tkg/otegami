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
///   ここを一切経由しない — 下の Task #155 の追記参照)。
///
/// Task #189 (2026-07-31): 上の4カテゴリの先頭に**「一般」**
/// (`GeneralSettingsView`、新設) を追加した。iCloud 同期トグルは
/// 「アカウントの設定」からここへ再移設し、移設元には残していない —
/// Task #186 で同期対象がアカウントの接続設定から設定全般 (表示・翻訳・
/// 通知・署名・テンプレート等) へ広がり、「アカウントの設定」に属する
/// 項目とは言えなくなったため。並び順を先頭にしたのは、既存4カテゴリの
/// 順序が「アカウント→メール一覧→メールビューア→メール作成」という
/// アプリの利用フロー順である一方、iCloud 同期はそのどの段階にも属さず
/// アプリ全体に横断的に効く設定だから — フロー順の外側 (先頭) に置く方が
/// 両立し、Apple 標準の「設定」アプリが「一般」を機能固有カテゴリより
/// 手前に置く並びとも一致する。
///
/// Task #212 (実機フィードバック「push 通知の設定はアカウント設定
/// じゃなくて一般に移した方がいいと思う」): 「アカウントの設定」に
/// あったプッシュ通知への入口も「一般」へ再移設した (`GeneralSettingsView`
/// の doc comment に詳細)。これで「アカウントの設定」に追加されていた
/// iCloud 同期・プッシュ通知の2項目は両方とも「一般」へ移り終えている。
///
/// `AccountsListContent`という型名は維持している (`AccountsSettingsView`
/// の既存の配線を変更せずに済むため) が、中身は「アカウント一覧」では
/// なく「カテゴリ一覧」に変わった — M10 時点のこの型の doc comment
/// (nested `NavigationStack`が macOS `TabView`と衝突する話) はそのまま
/// 有効: このルートも各カテゴリも独自の`NavigationStack`を持たず、
/// 埋め込まれた側 (`AccountsSettingsView`) の`NavigationStack`にそのまま
/// `NavigationLink`で積み上がる。
///
/// Task #155 (2026-07-29, 実機報告「macOS の設定画面が崩れている」):
/// macOS はこの型 (`AccountsListContent`) をもう使わない —
/// `OtegamiSettingsView`が独自の`NavigationSplitView`(サイドバー+detail)
/// に作り直されたため。理由は同ファイルの doc comment 参照: 旧
/// `TabView`(「設定」/「情報」の2タブ、「設定」タブの中はこの
/// `AccountsListContent`のカテゴリ一覧からpush) に、実機検証で
/// 「`TabView`にホストされた`NavigationStack`はpushしたら戻るボタンも
/// `dismiss()`も一切効かない」という致命的な不具合が見つかった。
/// このコメント自身とこの型は iOS 専用 (`AccountsSettingsView`の
/// シート・`SettingsSheetView`) として引き続き使われている。
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

    /// Task #189: same tap-free idea, for `scripts/verify-screen.sh`
    /// screenshots of the new `GeneralSettingsView` without a real tap on
    /// this row.
    @State private var uitestShowGeneralSettingsDirectly = false

    var body: some View {
        List {
            // 実機フィードバック第4弾 (2026-07-29): 表示順を「アカウント →
            // メール一覧 → メールビューア → メール作成」に変更し、
            // 「このアプリについて」行は削除 (AboutView 自体は macOS の
            // 「情報」タブが引き続き使う)。
            // Task #189 (2026-07-31): 先頭に「一般」を追加 — このファイル
            // 冒頭の doc comment の Task #189 追記参照 (フロー順の外側に
            // 置くのが自然という判断)。
            Section {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    Label("一般", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings.category.general")

                NavigationLink {
                    AccountSettingsCategoryView()
                } label: {
                    Label("アカウントの設定", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("settings.category.accounts")

                NavigationLink {
                    MailListSettingsView()
                } label: {
                    Label("メール一覧", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("settings.category.mailList")

                NavigationLink {
                    MailViewerSettingsView()
                } label: {
                    Label("メールビューア", systemImage: "envelope.open")
                }
                .accessibilityIdentifier("settings.category.mailViewer")

                NavigationLink {
                    MailComposeSettingsView()
                } label: {
                    Label("メール作成", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("settings.category.mailCompose")
            }
        }
        .navigationDestination(isPresented: $uitestShowAccountSettingsDirectly) {
            AccountSettingsCategoryView()
        }
        .navigationDestination(isPresented: $uitestShowMailViewerSettingsDirectly) {
            MailViewerSettingsView()
        }
        .navigationDestination(isPresented: $uitestShowGeneralSettingsDirectly) {
            GeneralSettingsView()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenAccountSettingsDirectly") {
                uitestShowAccountSettingsDirectly = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenMailViewerSettingsDirectly") {
                uitestShowMailViewerSettingsDirectly = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uitestsOpenGeneralSettingsDirectly") {
                uitestShowGeneralSettingsDirectly = true
            }
        }
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
    }
}
