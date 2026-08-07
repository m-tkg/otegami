import SwiftUI

/// 検索画面再構成 (Task #86, Sparkハンドオフ): 検索画面の最上段 — 角丸
/// (カプセル型) の検索フィールド (先頭に「現在のクエリを保存」の星、
/// システムの`.searchable`ではなくこのアプリ自身の`TextField`) + 右側の
/// 丸い閉じるボタン。前バッチまでの`.searchable`+`.toolbar`の「閉じる」
/// ボタンをこの1行に統合した。
///
/// **`OtegamiRadius`からの意図的な例外**: `OtegamiRadius`のドキュメント
/// コメントは「カードだけ角丸、他はフラット」と明言しているが、Sparkの
/// 参考画像がこの画面のフィールド自体を完全な角丸 (カプセル) で明示して
/// いたため、この画面のトップバー2要素 (フィールド本体・閉じるボタン)
/// だけに閉じたスコープで`Capsule()`/`Circle()`を使う。他のチップ/ボタン/
/// バッジには波及させない — 詳細は`docs/design-system.md`の検索画面
/// 再構成の節を参照。
struct SearchTopBar: View {
    @Binding var searchText: String
    let isSaved: Bool
    let isSaveEnabled: Bool
    let onToggleSaved: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            fieldContent
            closeButton
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.top, OtegamiSpacing.sm)
    }

    private var fieldContent: some View {
        HStack(spacing: OtegamiSpacing.sm) {
            saveButton
            TextField("検索", text: $searchText)
                .textFieldStyle(.plain)
                .font(OtegamiFont.body())
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .accessibilityIdentifier("search.textField")
        }
        .padding(.horizontal, OtegamiSpacing.md)
        .padding(.vertical, OtegamiSpacing.sm)
        // Liquid Glass Phase 4 (`docs/design-system.md`「Liquid Glass 方針」):
        // 独自の不透明`surface`塗りカプセルから、`AccountFilterChip`/
        // `MessageDetailFooterToolbar`と同じ系統のシステム標準 Glass
        // カプセルへ。テキスト色も独自`ink`トークンをやめ、Glass 上の
        // 標準ラベル色 (`.primary`) に委ねる。macOS は対象外
        // (`otegamiGlassChrome`自体が macOS では no-op — CLAUDE.md
        // 「macOS は現状維持」)。
        .otegamiGlassChrome(shape: Capsule())
    }

    /// 現在のクエリ+フィルタ+アカウント絞りを保存/解除するトグル。クエリが
    /// 空 (`isSaveEnabled == false`) の間は「何を保存するか」が無いので
    /// 無効化する — 見た目はSparkの参考画像どおり (空欄時は塗りつぶし無し)。
    private var saveButton: some View {
        Button(action: onToggleSaved) {
            Image(systemName: isSaved ? "star.fill" : "star")
                .foregroundStyle(isSaved ? OtegamiColor.accent : OtegamiColor.inkTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!isSaveEnabled)
        .otegamiMinimumTappable()
        .accessibilityIdentifier("search.saveButton")
        .accessibilityLabel(isSaved ? "この検索の保存を解除" : "この検索を保存")
    }

    private var closeButton: some View {
        // Liquid Glass Phase 4: 独自の`surface`塗り円 → システム標準の
        // 丸い Glass ボタン (`.buttonStyle(.glass)`)。アイコン専用ボタンは
        // `otegamiGlassChrome`でラップせず標準ボタンスタイルを直接使う
        // (`OtegamiGlass.swift`のdoc comment「Buttons」節参照)。
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(OtegamiFont.subheadline())
                .frame(width: OtegamiSpacing.xl, height: OtegamiSpacing.xl)
        }
        #if os(iOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.plain)
        .background(OtegamiColor.surface, in: Circle())
        #endif
        .otegamiMinimumTappable()
        .accessibilityIdentifier("search.closeButton")
        .accessibilityLabel("閉じる")
    }
}
