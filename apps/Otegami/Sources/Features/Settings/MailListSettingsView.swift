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
    @AppStorage(TranslationSettingsStore.showListSummaryKey) private var showListSummary = false
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
                Toggle("送信者のプロフィールアイコンを表示", isOn: $showAvatar)
                    .accessibilityIdentifier("settings.list.showAvatarToggle")
                // アバター強化バッチ フェーズ1「連絡先の写真」— `showAvatar`
                // がそもそも OFF ならこのトグル自体意味を持たないが、
                // `showAvatar` OFF でもこの値は変更・保持できるようにあえて
                // 出しっぱなしにしている (再度 ON にしたときに前の選択が
                // 残っている方が自然)。
                Toggle("連絡先の写真を表示", isOn: $showContactPhoto)
                    .accessibilityIdentifier("settings.list.showContactPhotoToggle")
                // アバター強化バッチ「Google プロフィール写真」。連絡先の
                // 写真が見つからなかった場合の次点。Gmail アカウントが無い
                // ユーザーには効果が無いが、トグル自体は常に出す (Gravatar/
                // 企業ロゴのトグルも差出人ドメインを問わず常に出しているのと
                // 同じ扱い)。
                Toggle("Google プロフィール写真を表示", isOn: $showGoogleProfilePhoto)
                    .accessibilityIdentifier("settings.list.showGoogleProfilePhotoToggle")
                // アバター強化バッチ フェーズ2「Gravatar」。連絡先の写真・
                // Google プロフィール写真のどちらも見つからなかった場合の
                // 次点として使われる。
                Toggle("Gravatar の画像を表示", isOn: $showGravatar)
                    .accessibilityIdentifier("settings.list.showGravatarToggle")
                // アバター強化バッチ フェーズ3「企業ロゴ (favicon)」。連絡先の
                // 写真・Gravatar のどちらも見つからなかった場合の次点。
                Toggle("企業ロゴを表示", isOn: $showCompanyLogo)
                    .accessibilityIdentifier("settings.list.showCompanyLogoToggle")
                Picker("本文プレビューの行数", selection: $previewLineCountRaw) {
                    ForEach(PreviewLineCount.allCases) { count in
                        Text(count.title).tag(count.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.list.previewLineCountPicker")
                Toggle("一覧に要約を出す", isOn: $showListSummary)
                    .accessibilityIdentifier("settings.listSummaryToggle")
            } header: {
                Text("表示")
            } footer: {
                // アバター強化バッチ: フェーズ2 (Gravatar)・フェーズ3 (企業
                // ロゴ) はどちらも外部通信を伴うため、それぞれ独立した段落
                // で明記している。
                VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
                    Text("プロフィールアイコンは、差出人のイニシャル+アカウント色を基本に、連絡先に一致する写真があればそれを優先して表示します（連絡先の照合はこの端末上だけで行われ、外部には送信されません）。")
                    Text("連絡先に写真が無い場合、Gmail アカウントが接続されていれば Google のプロフィール写真を表示することがあります。差出人のメールアドレスが Google に送信されます。設定でオフにできます。")
                    Text("それでも見つからない場合、Gravatar (gravatar.com) に登録された画像を表示することがあります。差出人アドレスのハッシュが gravatar.com に送信されます。設定でオフにできます。")
                    Text("それでも見つからない場合、差出人の会社ドメインの favicon を企業ロゴとして表示することがあります（フリーメール (Gmail 等) のアドレスは対象外です）。ドメイン名が接続先サーバーに送信されます。設定でオフにできます。")
                }
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
                Toggle("サーバーのフラグ (\\Flagged) と連動", isOn: $pinSyncWithFlagged)
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
