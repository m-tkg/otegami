import SwiftUI

/// Task #197 (実機フィードバック「更新ボタンと検索欄をメールビュー側から
/// 一覧側へ移して欲しい」): macOS 専用、`MessageListView`の`List`の**真上**
/// に置く検索欄+スコープ切替+更新ボタンの行。
///
/// 以前は`MessageListView`の`List`に`.searchable`/`.toolbar`を付ける
/// ("システムの理屈では一覧の付属物") 実装だったが、`NavigationSplitView`
/// 3ペイン構成ではその手のウィンドウ共通ツールバー項目がウィンドウ右端
/// (＝実質メールビュー側の真上) に描画され、「検索欄・更新ボタンがメール
/// ビューにある」ように実機で見えてしまっていた (詳細は
/// `docs/design-system.md`のTask #197節)。この型を`MessageListView.body`
/// 側の`VStack`で直接`List`の上に積むことで、ペイン幅に関わらず必ず
/// 一覧の真上に描画されることを保証する。
///
/// **`OtegamiRadius`からの意図的な例外**: 検索フィールド本体だけ`Capsule()`
/// を使う — iOS の`SearchTopBar`(Task #86) が同じ理由で同じ例外を取って
/// いる既存の先例に倣った (`SearchTopBar`のdoc comment参照)。他のボタン/
/// バッジには波及させない。
struct MacListSearchBar: View {
    @Binding var searchText: String
    @Binding var searchScope: SearchScopeOption
    let availableScopes: [SearchScopeOption]
    var isFieldFocused: FocusState<Bool>.Binding
    /// Task #196 (実機フィードバック「mac 版にも iOS 版と同じように一覧に
    /// 未読のみ表示のボタンをつけてほしい」) — `MessageListView`の
    /// `@AppStorage(ListDisplaySettingsStore.unreadOnlyKey)`をそのまま
    /// 束ねる。永続化/絞り込みロジック自体は元々プラットフォーム非依存
    /// だった (`MessageListView.persistedUnreadOnly`/`observeThreads()`)
    /// ので、ここは見た目のボタンを足すだけ。
    @Binding var isUnreadOnly: Bool
    let isSyncing: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            fieldContent
            if availableScopes.count > 1 {
                scopePicker
            }
            Spacer(minLength: OtegamiSpacing.sm)
            unreadOnlyToggleButton
            refreshButton
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
    }

    private var fieldContent: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(OtegamiColor.inkTertiary)
            TextField("検索", text: $searchText)
                .textFieldStyle(.plain)
                .font(OtegamiFont.body())
                .foregroundStyle(OtegamiColor.ink)
                .focused(isFieldFocused)
                .accessibilityIdentifier("messageList.search.field")
            // システムの`.searchable`が出していた「クリア (x)」ボタン相当
            // — 自前`TextField`にはビルトインの相当品が無いため追加した
            // (`SearchTopBar`は検索画面自体を閉じる別の閉じるボタンを
            // 持つため、こちらの「クリア」とは役割が異なる)。
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OtegamiColor.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("messageList.search.clearButton")
                .accessibilityLabel("検索文字列をクリア")
            }
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.xs)
        .background(OtegamiColor.surface, in: Capsule())
    }

    /// `.searchScopes`が出していたスコープ切替 (すべて/このメールボックス)
    /// のプレーン置き換え — 選択肢が2個以下なので`.segmented`で十分
    /// コンパクト。`.mailbox`選択でないとき (`availableScopes.count == 1`)
    /// は`body`側で丸ごと描画しない。
    private var scopePicker: some View {
        Picker("検索範囲", selection: $searchScope) {
            ForEach(availableScopes) { scope in
                Text(scope.title)
                    .tag(scope)
                    .accessibilityIdentifier("messageList.search.scope.\(scope.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Task #196: iOS の`MailScreenView.unreadOnlyToggleButton`と同じ
    /// 見た目 (アイコン塗り分け+ONのときだけ丸背景) をそのまま踏襲した
    /// macOS 版 — 新しい色トークンは追加していない
    /// (`OtegamiColor.accentText`/`paleBaseStrong`は既存)。
    private var unreadOnlyToggleButton: some View {
        Button {
            isUnreadOnly.toggle()
        } label: {
            Image(systemName: isUnreadOnly ? "envelope.badge.fill" : "envelope.badge")
                .foregroundStyle(isUnreadOnly ? OtegamiColor.accentText : OtegamiColor.inkSecondary)
                .padding(OtegamiSpacing.xs)
                .background(isUnreadOnly ? OtegamiColor.paleBaseStrong : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messageList.unreadOnlyToggle")
        .accessibilityLabel("未読のみ表示")
        .accessibilityAddTraits(isUnreadOnly ? .isSelected : [])
        .help("未読のみ表示")
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("messageList.refreshButton")
        .accessibilityLabel("再同期")
        .disabled(isSyncing)
        .help("再同期")
    }
}
