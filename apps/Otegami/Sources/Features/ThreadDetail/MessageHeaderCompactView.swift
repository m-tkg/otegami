import SwiftUI
import OtegamiStore

/// 画面構造改修バッチ (Task #33, 2): 「メールヘッダやタイトルのところも、Spark
/// を参考にして」— Spark 式の圧縮ヘッダ (差出人の表示名(太字) + 時刻、「宛先:
/// 名前」程度、約2行) に置き換えた `MessageView.header(for:)`。以前のヘッダは
/// 件名 (title2) + From/To のフルアドレス + フル日時 + HTMLバッジ/切替ボタンで
/// 縦に厚く、「メール本文のエリアが狭い」という要望の一因だった。
///
/// 件名はここに出さない — ナビゲーションタイトルにも出さない既存のルール
/// (`ThreadDetailView`の doc comment) と同じ理由に加え、この画面を開く前に
/// 必ず経由する一覧画面 (`MessageListRow`) で既に見えている情報の重複を
/// 避けるため。From/To のフルアドレスと秒単位の
/// 日時も削った — 詳細が要る場合はフッターツールバーの「情報」
/// (`MessageHeaderInfoView`) が既に全項目を持っている。
///
/// `MessageView.swift`から独立した1ファイル/1構造体に分けているのは
/// `docs/ci.md`の「行/セクション相当のビューは独立した`View`型に切り出す」
/// という既存の規律に倣ったもの — 元々の`header(for:)`はそれ自体
/// `MessageView.body`の式を長くしていた一因でもあった。
struct MessageHeaderCompactView: View {
    let message: MessageRecord
    let accountId: String
    let accountLabelColorKey: String?
    let showAvatar: Bool
    let isHTMLMessage: Bool
    let isShowingHTML: Bool
    let onToggleHTMLText: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
            // B5 「本文にも送信者アイコンを出せるように」— see
            // `ListDisplaySettingsStore.showAvatarInDetailKey`'s doc
            // comment. `28`(旧`36`より小さい) — 圧縮ヘッダの行の高さに合わせた。
            if showAvatar {
                SenderAvatar(
                    displayName: message.fromAddresses.first?.name,
                    address: message.fromAddresses.first?.address ?? "",
                    accountId: accountId,
                    labelColorKey: accountLabelColorKey,
                    diameter: 28
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OtegamiSpacing.xs) {
                    Text(senderText)
                        .font(OtegamiFont.headline())
                        .bold()
                        .foregroundStyle(OtegamiColor.ink)
                        .lineLimit(1)
                        .accessibilityIdentifier("messageDetail.senderName")
                    // A9-1: a subdued flag that this message *is* HTML —
                    // independent of `isShowingHTML` (still shown even
                    // while the toggle has switched this message to its
                    // text rendering).
                    if isHTMLMessage {
                        HTMLBadge()
                    }
                    Spacer(minLength: OtegamiSpacing.sm)
                    OtegamiDateFormat.listRowText(for: message.date ?? message.internalDate)
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkTertiary)
                        .accessibilityIdentifier("messageDetail.time")
                }
                HStack(spacing: OtegamiSpacing.xs) {
                    Text(toSummaryText)
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("messageDetail.toSummary")
                    Spacer(minLength: OtegamiSpacing.sm)
                    // A9-2: only offered for messages that actually have an
                    // HTML body to switch away from/back to — see
                    // `MessageView.isShowingHTML`'s doc comment for what
                    // toggling flips. Icon-only now (was a text button) to
                    // stay inside this row's compact height.
                    if isHTMLMessage {
                        // Task #107 (実機フィードバック「ヘッダ右上のボタンが
                        // 文字サイズ変更ボタンに見える」): 旧アイコン
                        // (`textformat`/`chevron.left.slash.chevron.right`)
                        // をやめ、「今表示している形式」ではなく「タップで
                        // 切り替わる先」が伝わるアイコンペアに変更 —
                        // HTML表示中は`doc.plaintext`(テキストへの切替を
                        // 示唆)、テキスト表示中は`doc.richtext`(HTMLへ戻す
                        // ことを示唆)。`accessibilityLabel`はこのボタンの
                        // 意味 (押した後どちらの表示になるか) を維持。
                        Button(action: onToggleHTMLText) {
                            Image(systemName: isShowingHTML ? "doc.plaintext" : "doc.richtext")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .tint(OtegamiColor.accent)
                        .foregroundStyle(OtegamiColor.accent)
                        .accessibilityIdentifier("messageDetail.toggleHTMLTextButton")
                        .accessibilityLabel(isShowingHTML ? "テキストで表示" : "HTMLで表示")
                    }
                }
            }
        }
    }

    private var senderText: String {
        guard let from = message.fromAddresses.first else { return "(unknown)" }
        return from.name?.isEmpty == false ? from.name! : from.address
    }

    /// Spark 式「宛先: 名前」程度 — フルアドレスリストではなく先頭の宛先1名
    /// (表示名優先、無ければアドレス) + 他が居れば人数だけ添える。
    private var toSummaryText: String {
        guard let first = message.toAddresses.first else { return String(localized: "宛先: (なし)") }
        let name = first.name?.isEmpty == false ? first.name! : first.address
        let extra = message.toAddresses.count - 1
        if extra > 0 {
            return String(localized: "宛先: \(name) 他\(extra)名")
        }
        return String(localized: "宛先: \(name)")
    }
}
