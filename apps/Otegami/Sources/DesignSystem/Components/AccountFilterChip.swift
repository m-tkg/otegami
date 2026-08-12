import SwiftUI

/// The horizontal-scroll account/mailbox filter chip from 1a ("横スクロー
/// ルのチップ列（全部 / 仕事 / 個人 / ＋）"). A flat, square-cornered
/// toggle button — selected state reads via a filled pale-blue background
/// plus an accent-colored border, not via color alone (so it still reads
/// correctly for color-blind users and in the catalog's grayscale-ish
/// dark-mode swatches).
public struct AccountFilterChip: View {
    private let title: String
    private let isSelected: Bool
    /// Whether `title` should be looked up in the string catalog. Fixed
    /// labels ("全部"/"＋") want that; an account's display name must not
    /// take that path — see `label`'s doc comment for the real-device bug
    /// that forced this distinction.
    private let isTitleLocalizable: Bool
    private let action: () -> Void

    public init(title: String, isSelected: Bool, isTitleLocalizable: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.isTitleLocalizable = isTitleLocalizable
        self.action = action
    }

    public var body: some View {
        // 2026-08-07 (メイン UI の macOS ネイティブ化): macOS は Finder/
        // Mail の scope bar と同じ「選択中だけ控えめな角丸塗り、枠線なし」
        // — 44pt の最小タップ領域 (`otegamiMinimumTappable`) もタッチ前提の
        // 話なので macOS では適用しない。
        //
        // Liquid Glass Phase 1 (同日、docs/design-system.md「Liquid Glass
        // 方針」): iOS 側は「角丸0+枠線塗り」の独自チップ意匠をやめ、
        // システム標準の Liquid Glass カプセルへ委譲した。選択状態は
        // `.glassProminent` + `.tint(OtegamiColor.accent)`(塗り+文字色が
        // システムのコントラスト計算に任せられる)、非選択は素の`.glass`。
        // 2つの`ButtonStyle`は型が異なり三項演算子で切り替えられないため
        // (`ButtonStyle`用の型消去が標準に無い)、`if`分岐で`Button`自体を
        // 2通り用意している。
        #if os(macOS)
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #else
        Group {
            if isSelected {
                Button(action: action) { label }
                    .buttonStyle(.glassProminent)
                    .tint(OtegamiColor.accent)
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
            }
        }
        .otegamiMinimumTappable()
        // 実機報告 (2026-08-13)「チップをタップして反応はするが切り替わら
        // ない」: `AccountDigestRow` が同日に踏んだのと同じ、`Button` が
        // 押下中のわずかな指の移動でタップをキャンセルする問題。こちらは
        // 親が `ScrollView(.horizontal)` (`AccountFilterChipRow`) なので、
        // 横スクロールの認識器がタッチを奪うと `.glass` の押下ハイライト
        // だけ出て `action` は呼ばれずに終わる。
        //
        // `AccountDigestRow` と違って `Button` 自体は残す — Liquid Glass の
        // 押下フィードバックとカプセル意匠 (`.glass`/`.glassProminent`) が
        // `Button` の描画に乗っているため。`Button` が拾えたときは
        // `action` が、キャンセルされたときはこの `.onTapGesture` が拾う。
        // 両方発火しても、このチップの `action` (絞り込み対象の代入) は
        // 冪等なので実害は無い。
        .onTapGesture(perform: action)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #endif
    }

    private var label: some View {
        // 固定ラベル (「全部」「＋」) だけを `LocalizedStringKey` 経由で
        // 引く。**アカウント表示名を同じ経路に流してはいけない**:
        // `LocalizedStringKey` は文字列を Markdown として解釈するため、
        // 表示名がメールアドレスそのもの (アカウント追加時に表示名を
        // 空にした場合の既定) だと SwiftUI が自動リンク化し、チップを
        // タップすると `mailto:` が開いてメール作成画面に飛ぶ、という
        // 実機バグが発生した (該当チップだけリンク色で描画されるのが
        // 目印だった)。動的テキストは `Text(verbatim:)` で素通しする。
        #if os(macOS)
        Group {
            if isTitleLocalizable {
                Text(LocalizedStringKey(title))
            } else {
                Text(verbatim: title)
            }
        }
            .font(OtegamiFont.caption())
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, OtegamiSpacing.sm)
            .padding(.vertical, OtegamiSpacing.xs)
            // scope bar の選択表現: システム階層素材の控えめな角丸塗り
            // (独自色トークンではなくシステム素材 — `MacListSearchBar` と
            // 同じ判断)。
            .background(
                isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
        #else
        // Liquid Glass 化 (2026-08-07): 塗り・枠線・パディングは
        // `.buttonStyle(.glass)`/`.glassProminent`自身が描くので、ここは
        // テキストと最小限のフォント指定だけ持つ。
        Group {
            if isTitleLocalizable {
                Text(LocalizedStringKey(title))
            } else {
                Text(verbatim: title)
            }
        }
        .font(OtegamiFont.caption())
        #endif
    }
}
