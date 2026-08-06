import SwiftUI

/// Task #78 (ユーザー要望「アクセントブルーにするのは compose だけじゃ
/// なくて設定とか検索とか翻訳要約のフローティングも」): the circular
/// "floating action button" chrome every screen-level floating button in
/// this app uses — the unified inbox's speed-dial FAB and its expanded
/// children (`MailScreenView`, Task #131 で「…」1個 + 展開時の「新規作成」/
/// 「検索」2個に統合、旧`floatingComposeButton`/`floatingSearchButton`の
/// 独立配置はもう無い). ハンバーガーメニューの設定ボタンは Task #126 で
/// ヘッダ右上のツールバーアイテムへ移設し、このフローティングチロムはもう
/// 使っていない (`FolderListSheet`).
///
/// **History**: 実機フィードバック第4弾でまず`floatingComposeButton`
/// だけがSpark参考画像に合わせてアクセント塗り+白アイコンになった
/// (`docs/design-system.md`のTask #77節「新規作成フローティングボタンを
/// アクセント塗りに」参照) — その時点では「検索・要約・翻訳は控えめな
/// スタイルのまま、目立たせるのは主要アクションだけ」という階層を意図的に
/// 保つ判断だった。Task #78のユーザー要望でその判断を覆し、**全部のフロー
/// ティングボタンをcomposeと同じアクセント塗り+白アイコンに統一**した —
/// この型はその統一後の見た目を1箇所にまとめたもの。以前は
/// `OtegamiFloatingButtonTone`(要約/翻訳の状態遷移用)が`AISummaryBar
/// .swift`の中だけにあり、`floatingSearchButton`/`floatingSettingsButton`
/// は独自にスタイルをインライン複製していた
/// (`OtegamiFloatingButtonTone`の旧doc comment: 「3つの近い重複実装に
/// なるだけなので、このペアだけを昇格するのは見送る」) — 全ボタンが同じ
/// 見た目になった今、複製を維持する理由が無くなったため、design system
/// のコンポーネントとしてここへ昇格した。
///
/// Task #88 (「要約と翻訳のボタンをフローティングをやめてツールバーに
/// 入れて」): 要約/翻訳の2つはフローティング自体をやめてフッターツール
/// バーに移った (`MessageDetailFooterToolbar`の`summarizeButton`/
/// `translateButton` — 独自の色トーン`AIToolbarTone`を持つ、この型とは
/// 別物)。結果、検索/設定/作成の3つだけが残り、いずれも無状態のフロー
/// ティングボタンで単一の塗り (アクセント塗り+白アイコン) しか使わない
/// ため、Liquid Glass Phase 0 (`docs/design-system.md`「Liquid Glass 方針」
/// 参照) の一環で `OtegamiFloatingButtonTone`(`active`/`attention`/
/// `disabled`) を削除した — 状態を持つフローティングボタンが将来また
/// 増えたら、その時点で必要なトーンを設計し直す。
public extension View {
    func otegamiFloatingButtonChrome() -> some View {
        modifier(OtegamiFloatingButtonChromeModifier())
    }
}

private struct OtegamiFloatingButtonChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Task #85 (実機フィードバック「アイコンをもう少し大きく」):
            // `OtegamiFont.body()`(16pt, Archivo — Dynamic Type向けの
            // カスタム書体) から、`AttachmentCardRow.iconChip`と同じ
            // 「アイコン専用は素の`Font.system(size:weight:)`」に変更
            // — SF Symbolの見た目は元々書体に左右されないので、Archivo
            // 由来のDynamic Typeスケーリングを保つ意味がここには無い。
            // `frame`もアイコンの拡大に合わせて24→28に広げてある(circleの
            // 外径は`padding`が変わらない分だけ大きくなる)。
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: OtegamiSpacing.xl + OtegamiSpacing.xs, height: OtegamiSpacing.xl + OtegamiSpacing.xs)
            .padding(OtegamiSpacing.md + OtegamiSpacing.xs)
            // Task #85 (「青をもう少し濃く」): `.accent` → `.accentFloating`
            // (`OtegamiColor.accentFloating`のdoc comment参照)。
            .background(OtegamiColor.accentFloating, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}
