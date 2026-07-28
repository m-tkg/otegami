import SwiftUI

/// Task #78 (ユーザー要望「アクセントブルーにするのは compose だけじゃ
/// なくて設定とか検索とか翻訳要約のフローティングも」): the circular
/// "floating action button" chrome every screen-level floating button in
/// this app uses — the unified inbox's compose/search buttons
/// (`MailScreenView`), the hamburger menu's settings button
/// (`FolderListSheet`), and the message-detail screen's summarize/translate
/// buttons (`AISummaryFloatingButton`/`TranslationFloatingButton`).
///
/// **History**: 実機フィードバック第4弾でまず`floatingComposeButton`
/// だけがSpark参考画像に合わせてアクセント塗り+白アイコンになった
/// (`docs/design-system.md`のTask #77節「新規作成フローティングボタンを
/// アクセント塗りに」参照) — その時点では「検索・要約・翻訳は控えめな
/// スタイルのまま、目立たせるのは主要アクションだけ」という階層を意図的に
/// 保つ判断だった。今回のユーザー要望でその判断を覆し、**全部のフロー
/// ティングボタンをcomposeと同じアクセント塗り+白アイコンに統一**した —
/// この型はその統一後の見た目を1箇所にまとめたもの。以前は
/// `OtegamiFloatingButtonTone`(要約/翻訳の状態遷移用)が`AISummaryBar
/// .swift`の中だけにあり、`floatingSearchButton`/`floatingSettingsButton`
/// は独自にスタイルをインライン複製していた
/// (`OtegamiFloatingButtonTone`の旧doc comment: 「3つの近い重複実装に
/// なるだけなので、このペアだけを昇格するのは見送る」) — 全ボタンが同じ
/// 見た目になった今、複製を維持する理由が無くなったため、design system
/// のコンポーネントとしてここへ昇格した。
public enum OtegamiFloatingButtonTone {
    /// Idle/default — 塗りつぶしのアクセント色+白アイコン。無状態の
    /// フローティングボタン (検索・設定・作成) はこのトーンだけを使う。
    case neutral
    /// A result is ready and tapping reveals/toggles it (summarized, or
    /// translated-and-currently-showing) — `neutral`と同じアクセント系の
    /// 塗りだが、`accentText`(通常の`accent`よりコントラストの強い
    /// ステップ、既存トークン) を使うことで「オン」状態だとまだ見分けが
    /// つくようにしている — 例えば`TranslationFloatingButton`の「原文へ
    /// 戻す」トグル状態はこの色の違いだけで示す (アイコン自体は変えない)。
    case active
    /// The last attempt failed — tapping retries. 塗りつぶしの
    /// `OtegamiColor.destructive`(赤) — `active`(青系)と紛れず、
    /// ひと目で「失敗」と分かる。
    case attention
    /// This device/configuration can't do this at all right now — dimmed
    /// (アクセント系の塗りにしない、押せないことが分かるよう控えめな
    /// 面のまま), and the button is also disabled (`.disabled(true)` at
    /// the call site); VoiceOver still explains why via
    /// `accessibilityLabel` rather than the button silently vanishing.
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
            .font(OtegamiFont.body())
            .foregroundStyle(iconColor)
            .frame(width: OtegamiSpacing.xl, height: OtegamiSpacing.xl)
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
        case .neutral: OtegamiColor.accent
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
