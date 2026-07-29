import SwiftUI

/// I「設定画面の再構成」→「メール一覧」: プレビュー行数・一覧のプロフィール
/// 画像表示・D8 スワイプ設定 (iOS only)・翻訳の「一覧に要約を出す」
/// (名前が示すとおり一覧側の表示設定のため、このカテゴリに置いた —
/// `docs/design-system.md`のとおり現状 UI 未実装の設定項目)。
///
/// 実機フィードバック第3弾 (I): 旧「その他」カテゴリからピン留めの
/// フラグ連動設定・スレッド表示設定をここへ移設した — どちらも「一覧の
/// 並び順/まとめ方」に関わる設定で、このカテゴリの既存項目 (プレビュー・
/// スワイプ) と同じ「一覧をどう見せるか」の範疇にある。
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
    @AppStorage(PinSettingsStore.syncWithFlaggedKey) private var pinSyncWithFlagged = false

    #if os(iOS)
    @AppStorage(SwipeActionSettingsStore.leadingShortActionKey) private var leadingShortRaw = SwipeActionSettingsStore.defaultLeadingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.leadingLongActionKey) private var leadingLongRaw = SwipeActionSettingsStore.defaultLeadingLong.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingShortActionKey) private var trailingShortRaw = SwipeActionSettingsStore.defaultTrailingShort.rawValue
    @AppStorage(SwipeActionSettingsStore.trailingLongActionKey) private var trailingLongRaw = SwipeActionSettingsStore.defaultTrailingLong.rawValue
    #endif

    var body: some View {
        List {
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

            // 実機フィードバック第3弾 (I): 旧「その他」から移設。
            Section {
                Toggle("スレッド表示", isOn: $isThreadingEnabled)
                    .accessibilityIdentifier("settings.list.threadingToggle")
            } footer: {
                Text("ONで一覧を会話単位にまとめます。OFFにすると一覧がメール単位になります。")
            }

            Section {
                Toggle("サーバーのフラグと連動", isOn: $pinSyncWithFlagged)
                    .accessibilityIdentifier("settings.pinSyncWithFlaggedToggle")
            } header: {
                Text("ピン留め")
            } footer: {
                Text("既定ではピン留めはこの端末・このアプリだけのローカルな印です。ONにすると、ピン留め/解除のたびに IMAP の \\Flagged フラグも更新し、他のメールクライアントでのフラグ操作も読み取ってピン留めに反映します。")
            }
        }
        .navigationTitle("メール一覧")
        .scrollContentBackground(.hidden)
        .background(OtegamiColor.background)
        .tint(OtegamiColor.accent)
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
