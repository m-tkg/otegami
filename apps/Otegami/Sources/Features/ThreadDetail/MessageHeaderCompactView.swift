import SwiftUI
import OtegamiStore

/// 画面構造改修バッチ (Task #33, 2): 「メールヘッダやタイトルのところも、Spark
/// を参考にして」— Spark 式の圧縮ヘッダ (差出人の表示名(太字) + 時刻、「宛先:
/// 名前」程度、約2行) に置き換えた `MessageView.header(for:)`。以前のヘッダは
/// 件名 (title2) + From/To のフルアドレス + フル日時 + HTMLバッジ/切替ボタンで
/// 縦に厚く、「メール本文のエリアが狭い」という要望の一因だった。
///
/// From/To のフルアドレスと秒単位の日時は削ったまま — 詳細が要る場合は
/// フッターツールバーの「情報」(`MessageHeaderInfoView`) が既に全項目を
/// 持っている。
///
/// **Task #185 (実機フィードバック「メールのタイトルが表示されていない」):
/// 件名を`subjectText`としてこのヘッダの先頭 (差出人行の上) に復活させた。**
/// 上のTask #33時点の doc comment はかつて「件名はここに出さない —
/// この画面に到達する前の一覧画面 (`MessageListRow`) で既に見えている情報の
/// 重複を避けるため」としていたが、実際に使ってみると「一覧で見た件名を
/// もう覚えていない・一覧から直接ではなく通知/検索/スレッド内リンクなど
/// 別経路でこの画面に来た」場面で、詳細画面のどこにも件名が出ないのは
/// 単純に読みにくいという実利用フィードバックがあり、この判断を撤回した。
/// ナビゲーションタイトルには依然出さない (`ThreadDetailView.navigationTitleText`
/// のdoc comment参照 — スレッド全体を指すタイトルと個々のメッセージの件名は
/// 別物なのに加え、複数メッセージのアコーディオンでは展開中の1通の件名だけを
/// 出すとナビゲーションバーが展開切り替えのたびにちらつく) — 件名は常に
/// このヘッダ側、つまり「今展開されている、まさにその1通」に対して表示する。
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
    /// Task #151 (「アーカイブ済みの可視化」): `MessageView`'s own
    /// per-message check (`ThreadQuery.isMessageArchived(messageId:db:)`,
    /// loaded alongside `mailboxPath` — see `MessageView.load()`) rather
    /// than a thread-level aggregate, since this header always renders one
    /// specific message, and a thread can (rarely) mix archived and
    /// not-yet-archived messages across mailboxes.
    var isArchived: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.xs) {
            subjectView
            senderRow
        }
    }

    /// Task #185: the message's own subject — see this type's doc comment
    /// for why it's back after Task #33 removed it. Placed above the
    /// sender/time row (not indented under the avatar) so it reads as this
    /// row's title, spanning the header's full width. Pulled into its own
    /// `@ViewBuilder` property, not inlined into `body`, purely to keep
    /// `body` itself short (`docs/ci.md`'s SwiftUI-type-check-timeout
    /// discipline — the same reason this file already split out of
    /// `MessageView.swift`).
    @ViewBuilder
    private var subjectView: some View {
        // `Text(verbatim:)`, not `LocalizedStringKey` — the subject is
        // untrusted, user/sender-controlled dynamic text; routing it
        // through the Markdown-interpreting `LocalizedStringKey`
        // initializer is exactly the `AccountFilterChip.swift`-documented
        // trap (a bare-looking address or `[...]`/`_..._` sequence in a
        // real subject line could otherwise get linkified/styled).
        Text(verbatim: subjectText)
            .font(OtegamiFont.title())
            .foregroundStyle(OtegamiColor.ink)
            // Long-subject handling: wrap up to 2 lines, then truncate with
            // a trailing ellipsis — a full subject usually fits in one
            // line, but real newsletter/notification subjects can run
            // long. 2 lines (not 1) keeps most real-world subjects fully
            // readable without the compact header this batch is built
            // around ballooning into the old, tall pre-Task-#33 header for
            // a merely-long-but-not-pathological subject; a 3rd+ line still
            // truncates rather than eating more of the limited body area
            // above the fold.
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("messageDetail.subject")
    }

    /// The pre-existing Spark 式 sender/time/"宛先" row — unchanged content,
    /// pulled into its own property (alongside `subjectView` above) so
    /// `body` stays a two-line `VStack`.
    @ViewBuilder
    private var senderRow: some View {
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
                    // Task #151: controlled, subdued — a small badge
                    // alongside `HTMLBadge` rather than a banner, per the
                    // task's own "控えめな「アーカイブ済み」表示" spec.
                    if isArchived {
                        ArchivedBadge()
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

    /// Fallback for a missing/empty subject — matches `ThreadRowView
    /// .subjectText`'s existing "(件名なし)" convention so this screen never
    /// disagrees with what the list already showed for the same message.
    private var subjectText: String {
        message.subject?.isEmpty == false ? message.subject! : String(localized: "(件名なし)")
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
