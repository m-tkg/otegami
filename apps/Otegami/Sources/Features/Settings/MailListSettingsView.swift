import SwiftUI

/// I「設定画面の再構成」→「メール一覧」: プレビュー行数・一覧のプロフィール
/// 画像表示・D8 スワイプ設定 (iOS only)・翻訳の「一覧に要約を出す」
/// (名前が示すとおり一覧側の表示設定のため、このカテゴリに置いた —
/// `docs/design-system.md`のとおり現状 UI 未実装の設定項目)。
///
/// 実機フィードバック第3弾 (I): 旧「その他」カテゴリからピン留めの
/// フラグ連動設定・スレッド表示設定をここへ移設した — どちらも「一覧の
/// 並び順/まとめ方」に関わる設定で、このカテゴリの既存項目 (プレビュー・
/// スワイプ) と同じ「一覧をどう見せるか」の範疇にある。ピン留めのフラグ
/// 連動設定は Task #212 でトグルごと削除済み (常時 on の内部固定挙動へ
/// 変更したため) — このカテゴリにはもう無い。
struct MailListSettingsView: View {
    @AppStorage(ListDisplaySettingsStore.previewLineCountKey) private var previewLineCountRaw = ListDisplaySettingsStore.defaultPreviewLineCount.rawValue
    @AppStorage(ListDisplaySettingsStore.showAvatarKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatar
    // アバター強化バッチ フェーズ1: `AvatarSourceSettingsStore`のドキュメント
    // コメント参照。
    @AppStorage(AvatarSourceSettingsStore.showContactPhotoKey) private var showContactPhoto = AvatarSourceSettingsStore.defaultShowContactPhoto
    // アバター強化バッチ「Google プロフィール写真」: 連絡先の写真の次、
    // Gravatar の前の優先順位。
    @AppStorage(AvatarSourceSettingsStore.showGoogleProfilePhotoKey) private var showGoogleProfilePhoto = AvatarSourceSettingsStore.defaultShowGoogleProfilePhoto
    // アバター強化バッチ フェーズ2: 同上。
    @AppStorage(AvatarSourceSettingsStore.showGravatarKey) private var showGravatar = AvatarSourceSettingsStore.defaultShowGravatar
    // アバター強化バッチ フェーズ3: 同上。
    @AppStorage(AvatarSourceSettingsStore.showCompanyLogoKey) private var showCompanyLogo = AvatarSourceSettingsStore.defaultShowCompanyLogo
    // 「一覧に要約を出す」トグルは実機フィードバック (2026-07-29) で削除
    // (UI 未実装の設定項目だった)。保存キーは他所で参照していないため
    // ここでの宣言ごと撤去。
    // 実機フィードバック第3弾 (I) で旧「その他」から移設。
    @AppStorage(ListDisplaySettingsStore.threadingKey) private var isThreadingEnabled = ListDisplaySettingsStore.defaultThreading
    // 「サーバーのフラグと連動」トグルは Task #212 (実機フィードバック
    // 「サーバのフラグと連動は設定から消して、内部的には連動 on として
    // 動いてほしい」) で削除 — ピン留めと IMAP `\Flagged` の連動は常時 on
    // の内部固定挙動になったため、ここで選べる設定ではなくなった。保存
    // キー (`pinning.syncWithFlagged`) は他所で参照していないため
    // `PinSettingsStore`/`PinSettingsKeys`ごと撤去した。
    // Task #190: 「アカウントでグループ化」表示 (`AccountDigestView`) の
    // スワイプ/コンテキストメニュー一括操作の確認ダイアログ ON/OFF —
    // 下の`swipeSection`(D8 スワイプ割り当て) のすぐ下に置く、この設定と
    // 同じ「一括操作の挙動」を扱うため。
    @AppStorage(ListDisplaySettingsStore.confirmBulkActionKey) private var confirmBulkAction = ListDisplaySettingsStore.defaultConfirmBulkAction
    // 実機フィードバック「アーカイブ時に既読にする」— スワイプ/一括操作/
    // push 通知アクションいずれのアーカイブ経路にも効くため、
    // `confirmBulkAction`と同じく`#if os(iOS)`では囲まない。
    @AppStorage(ArchiveActionSettingsStore.markAsReadOnArchiveKey) private var markAsReadOnArchive = ArchiveActionSettingsStore.defaultMarkAsReadOnArchive

    #if os(iOS)
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue
    #endif

    var body: some View {
        settingsContainer
            .navigationTitle("メール一覧")
    }

    /// Task #155 (macOS 設定画面フィードバック 2026-07-29): macOS は
    /// `Form` + `.formStyle(.grouped)` (System Settings と同じ標準スタイル)
    /// で表示する — `List`独自の`OtegamiColor`背景・アクセント塗りは
    /// macOS からは外し、AppKit 標準の見た目に任せる。`.toggleStyle(.switch)`
    /// で`Toggle`もチェックボックスでなく標準のスイッチにする。iOS は
    /// 元の`List`のまま (見た目変更なし)。
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
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
        #endif
    }

    @ViewBuilder
    private var sections: some View {
        Section {
            // 実機フィードバック (2026-07-29): アイコン系 5 トグル
            // (プロフィールアイコン/連絡先の写真/Google プロフィール
            // 写真/Gravatar/企業ロゴ) を 1 トグルに集約し、外部通信の
            // 注意書き footer も削除した。ON でこの 1 トグルが全ソース
            // (連絡先→Google→Gravatar→企業ロゴ→イニシャル) をまとめて
            // 有効化する — 個別ソースの保存キー
            // (`AvatarSourceSettingsStore`) は解決チェーン側がそのまま
            // 読むため残っており、この画面から書き分ける UI を無くした
            // だけ。
            Toggle("送信者のプロフィールアイコンを表示", isOn: $showAvatar)
                .accessibilityIdentifier("settings.list.showAvatarToggle")
                .onChange(of: showAvatar) { _, isOn in
                    // 1 トグル化に伴い、個別ソースも一括で追随させる
                    // (OFF→ON で「前に一部だけ切っていた」状態が残ると
                    // 1 トグルの見た目と実挙動がずれるため)。
                    showContactPhoto = isOn
                    showGoogleProfilePhoto = isOn
                    showGravatar = isOn
                    showCompanyLogo = isOn
                }
            Picker("本文プレビューの行数", selection: $previewLineCountRaw) {
                ForEach(PreviewLineCount.allCases) { count in
                    Text(count.title).tag(count.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.list.previewLineCountPicker")
        } header: {
            Text("表示")
        }

        // Task #52, 3: ハンバーガーメニューのカテゴリセクション (受信
        // トレイ/アーカイブ/送信済み等) の並び替え — 一覧そのものではなく
        // 一覧に辿り着くまでのフォルダメニューの設定だが、「一覧の並び方/
        // まとめ方」というこのカテゴリの既存項目 (下のスレッド表示等) と
        // 同じ性質と判断してここに置いた。
        Section {
            NavigationLink {
                FolderCategoryOrderSettingsView()
            } label: {
                Label("カテゴリの並び替え", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("settings.list.categoryOrderLink")
        } footer: {
            Text("フォルダメニューに並ぶ「受信トレイ」「アーカイブ」などカテゴリの表示順を変更できます。")
        }

        #if os(iOS)
        swipeSection
        #endif

        // 実機フィードバック「アーカイブ時に既読にする」: スワイプ・
        // 一括操作 (アカウントでグループ化表示/macOS ⌘E)・push 通知の
        // アクションボタン、アーカイブを実行する経路すべてに効く
        // (`MessageRemoval.commit(_:...:markSeenOnArchive:)`のドキュメント
        // コメント参照)。`swipeSection`のすぐ下、`confirmBulkAction`と
        // 同じ「アーカイブ・一括操作の挙動」を扱うセクション群に置いた。
        Section {
            Toggle("アーカイブ時に既読にする", isOn: $markAsReadOnArchive)
                .accessibilityIdentifier("settings.list.markAsReadOnArchiveToggle")
        } footer: {
            Text("オンにすると、アーカイブしたメールの未読状態を既読に変えます。")
        }

        // Task #190 (実機フィードバック「グループのスワイプで出てくる
        // 確認画面は設定でオフにできるようにして」): 「アカウントで
        // グループ化」表示 (`AccountDigestView`) の一括操作 (iOSはスワイプ、
        // macOSはコンテキストメニュー — どちらも同じ確認アラートを経由する)
        // の確認をスキップするかどうか。iOS専用の`swipeSection`のすぐ下に
        // 置いたが、この設定自体はmacOSのコンテキストメニュー一括操作にも
        // 効くため`#if os(iOS)`では囲まない。
        Section {
            Toggle("一括操作の前に確認する", isOn: $confirmBulkAction)
                .accessibilityIdentifier("settings.list.confirmBulkActionToggle")
        } footer: {
            Text("「アカウントでグループ化」表示でアカウント行をスワイプ（またはコンテキストメニュー）から一括操作するとき、実行前に確認ダイアログを出します。OFFにしても実行後5秒は取り消せます。")
        }

        // 実機フィードバック第3弾 (I): 旧「その他」から移設。
        Section {
            Toggle("スレッド表示", isOn: $isThreadingEnabled)
                .accessibilityIdentifier("settings.list.threadingToggle")
        } footer: {
            Text("ONで一覧を会話単位にまとめます。OFFにすると一覧がメール単位になります。")
        }
    }

    #if os(iOS)
    // D8「スワイプの割り当て」— iOS only (macOS has no swipe gesture; every
    // action is always reachable there via the row's context menu instead —
    // `MessageListRow.contextMenuContent`).
    private var swipeSection: some View {
        Section {
            Picker("右・短いスワイプ", selection: $leadingShortRaw) {
                ForEach(SwipeAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.swipe.leadingShortPicker")
            Picker("右・長いスワイプ", selection: $leadingLongRaw) {
                ForEach(SwipeAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.swipe.leadingLongPicker")
            Picker("左・短いスワイプ", selection: $trailingShortRaw) {
                ForEach(SwipeAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.swipe.trailingShortPicker")
            Picker("左・長いスワイプ", selection: $trailingLongRaw) {
                ForEach(SwipeAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.swipe.trailingLongPicker")
        } header: {
            Text("スワイプ")
        } footer: {
            Text("短いスワイプで表示される操作は、そのままスワイプし切ると即座に実行されます（削除・迷惑メールを除く — 誤操作防止のため、必ずタップでの確定操作です）。長いスワイプの操作は、ボタンが表示されてからのタップでのみ実行されます。")
        }
    }
    #endif
}
