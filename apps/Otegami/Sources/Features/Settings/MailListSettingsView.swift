import SwiftUI

/// I「設定画面の再構成」→「メール一覧」: プレビュー行数・一覧のプロフィール
/// 画像表示・D8 スワイプ設定 (iOS only)・翻訳の「一覧に要約を出す」
/// (名前が示すとおり一覧側の表示設定のため、このカテゴリに置いた —
/// `docs/design-system.md`のとおり現状 UI 未実装の設定項目)。
struct MailListSettingsView: View {
    @AppStorage(ListDisplaySettingsStore.previewLineCountKey) private var previewLineCountRaw = ListDisplaySettingsStore.defaultPreviewLineCount.rawValue
    @AppStorage(ListDisplaySettingsStore.showAvatarKey) private var showAvatar = ListDisplaySettingsStore.defaultShowAvatar
    @AppStorage(TranslationSettingsStore.showListSummaryKey) private var showListSummary = false

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
                Text("プロフィールアイコンは差出人のイニシャルとアカウント色から生成され、外部サービスへの問い合わせは一切行いません。")
            }

            #if os(iOS)
            swipeSection
            #endif
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
