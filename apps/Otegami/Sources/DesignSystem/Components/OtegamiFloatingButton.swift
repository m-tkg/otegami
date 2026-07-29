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
/// 別物)。結果、`neutral`以外の3ケース (`active`/`attention`/`disabled`)
/// は現時点でどの呼び出し元も使っていない — 検索/設定/作成の3つは元々
/// 無状態のフローティングボタンで`neutral`しか使わないため。この3ケース
/// はすぐには消さず残してある: 状態を持つフローティングボタンが将来また
/// 増えたときに再利用できる、汎用的な色トーンの語彙として設計してある型
/// のため (削除しても実害はないが、削除の判断は次にこの型を触るバッチに
/// 委ねる)。
public enum OtegamiFloatingButtonTone {
    /// Idle/default — 塗りつぶしのアクセント色+白アイコン。無状態の
    /// フローティングボタン (検索・設定・作成) はこのトーンだけを使う。
    case neutral
    /// A result is ready and tapping reveals/toggles it — `neutral`と同じ
    /// アクセント系の塗りだが、`accentText`(通常の`accent`よりコントラスト
    /// の強いステップ、既存トークン) を使うことで「オン」状態だとまだ
    /// 見分けがつくようにしている。Task #88時点でこのケースを使う呼び
    /// 出し元は無い (上のenum doc comment参照)。
    case active
    /// The last attempt failed — tapping retries. 塗りつぶしの
    /// `OtegamiColor.destructive`(赤) — `active`(青系)と紛れず、
    /// ひと目で「失敗」と分かる。Task #88時点でこのケースを使う呼び出し元
    /// は無い (上のenum doc comment参照)。
    case attention
    /// This device/configuration can't do this at all right now — dimmed
    /// (アクセント系の塗りにしない、押せないことが分かるよう控えめな
    /// 面のまま), and the button is also disabled (`.disabled(true)` at
    /// the call site); VoiceOver still explains why via
    /// `accessibilityLabel` rather than the button silently vanishing.
    /// Task #88時点でこのケースを使う呼び出し元は無い (上のenum doc
    /// comment参照)。
    case disabled
}

public extension View {
    /// `tone`省略時は`.neutral`(状態を持たないボタン向けのデフォルト)。
    func otegamiFloatingButtonChrome(tone: OtegamiFloatingButtonTone = .neutral) -> some View {
        modifier(OtegamiFloatingButtonChromeModifier(tone: tone))
    }
}

private struct OtegamiFloatingButtonChromeModifier: ViewModifier {
    let tone: OtegamiFloatingButtonTone

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
            .foregroundStyle(iconColor)
            .frame(width: OtegamiSpacing.xl + OtegamiSpacing.xs, height: OtegamiSpacing.xl + OtegamiSpacing.xs)
            .padding(OtegamiSpacing.md + OtegamiSpacing.xs)
            .background(backgroundColor, in: Circle())
            .overlay {
                // 塗りつぶしの円 (neutral/active/attention) には枠線は
                // 視覚的に不要 (`floatingComposeButton`が元々そうだった
                // 理由と同じ) — `disabled`だけ、押せないことが伝わるよう
                // 控えめな枠線を残す。
                if tone == .disabled {
                    Circle().stroke(OtegamiColor.dividerSubtle, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private var backgroundColor: Color {
        switch tone {
        // Task #85 (「青をもう少し濃く」): `.accent` → `.accentFloating`
        // (`OtegamiColor.accentFloating`のdoc comment参照)。`.active`は
        // 元々の`.accentText`のまま — `accentFloating`のライト値は
        // `accentText`とは別の、さらに一段深い値にしてあるので、
        // `.neutral`/`.active`の色分けはこの変更後も保たれる。
        case .neutral: OtegamiColor.accentFloating
        case .active: OtegamiColor.accentText
        case .attention: OtegamiColor.destructive
        case .disabled: OtegamiColor.surface
        }
    }

    /// アクセント塗り (`neutral`/`active`) と赤塗り (`attention`) は
    /// どちらも地の色が濃いので、進行中スピナー (`ProgressView`) を含めて
    /// アイコンは`.white`に統一 — 「白スピナーで視認性を保つ」というユー
    /// ザー要望はこの1箇所 (`iconOrProgress.otegamiFloatingButtonChrome
    /// (tone:)`がスピナーもアイコンも同じ`content`として包む) で自動的に
    /// 満たされる、呼び出し側で個別に対応する必要はない。
    private var iconColor: Color {
        switch tone {
        case .neutral, .active, .attention: .white
        case .disabled: OtegamiColor.inkTertiary
        }
    }
}
