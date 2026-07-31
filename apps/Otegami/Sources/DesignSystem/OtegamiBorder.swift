import CoreGraphics

/// Stroke widths and corner radii. Originally a flat, angular Modernist
/// base (`docs/design-system.md`: "フラット、角丸0、2px罫") with
/// every radius pinned to `0` — **overturned for cards specifically** in
/// the 実機フィードバック第2弾 batch (item C) at the user's explicit request:
/// "角丸解禁" (角を丸くする). See `OtegamiRadius.card`'s doc comment for the
/// scoping decision (cards round, most chrome doesn't) and
/// `docs/design-system.md`'s "実機フィードバック第2弾: C" section for the
/// full rationale.
public enum OtegamiStroke {
    /// Primary structural dividers (section breaks, the account-color
    /// rail) — 2pt solid, paired with `OtegamiColor.divider`.
    public static let primary: CGFloat = 2
    /// Row-level separators inside a list — 1pt dashed, paired with
    /// `OtegamiColor.dividerSubtle`.
    public static let secondary: CGFloat = 1
}

public enum OtegamiRadius {
    /// Flat — still the default for most chrome (buttons, chips, badges,
    /// section dividers): only cards (`OtegamiRadius.card`) round now. See
    /// this enum's doc comment.
    public static let none: CGFloat = 0
    /// 実機フィードバック第2弾 (C): the message-list row card
    /// (`ThreadRowView.otegamiCardBackground()`) — the *only* thing this
    /// design system rounds. 8pt: a small-but-clearly-rounded corner that
    /// reads as "a distinct card" at this app's row density (28–36pt
    /// avatars, `OtegamiSpacing.sm`/`.md` internal padding) without
    /// softening the row enough to fight the still-flat account-color
    /// rail's own hard-edged rectangle. Chips (`AccountFilterChip`),
    /// buttons, and badges (`ENBadge`/`HTMLBadge`) deliberately keep
    /// `OtegamiRadius.none` — rounding *only* the card keeps one clear
    /// visual language ("this is a distinct, tappable item") rather than
    /// rounding everything and losing that signal; revisit if a future
    /// pass wants a more uniformly-rounded look.
    public static let card: CGFloat = 8
}

// MARK: - 検索画面再構成 (Task #86): カプセル/円という2つ目の意図的な例外
//
// 上の`OtegamiRadius`のドキュメントコメントは「カードだけ角丸、他はフラット」
// と明言しているが、`SearchTopBar`(検索画面のトップバー: 角丸フィールド+
// 丸い閉じるボタン) はSparkのハンドオフ画像がこの2要素を完全な角丸で明示
// していたため、`OtegamiRadius`に値を1つ足すのではなく、SwiftUIの
// `Capsule()`/`Circle()`シェイプを直接そのビュー (`SearchTopBar.swift`) の
// 中だけで使う、という閉じたスコープの例外にした。`OtegamiRadius.card`の
// ような「数値トークン」ではなく標準シェイプそのものを使うのは、固定
// ポイント数の半端な近似ではなく「常に完全な角丸/真円になる」ことが目的
// そのものだったため。他のチップ/ボタン/バッジがこの例外を理由に角丸化
// することは意図していない — 詳細は`docs/design-system.md`の検索画面
// 再構成の節、`SearchTopBar`のドキュメントコメント参照。
