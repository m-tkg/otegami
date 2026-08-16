import SwiftUI
import OtegamiCore
import OtegamiStore

/// 「メール詳細画面のヘッダで『宛先: 田中 他2名』の行をタップすると、その場
/// で展開して差出人・宛先・Cc・Bcc のフルメールアドレスが見られるように
/// する」要望のインライン展開本体 (ユーザー確認済み: シートではなく
/// インライン展開)。`MessageHeaderCompactView`の`toSummaryText`行がこの
/// Viewの表示/非表示をトグルする。
///
/// フッターツールバーの「情報」(`MessageHeaderInfoView`) が既に From/To/
/// Cc/Bcc のフルアドレスを持っているが、あちらは Message-ID・Content-Type・
/// メールボックスパス等も含む「メール全体の情報」シートで、`List`+
/// `NavigationStack`という別画面前提のレイアウト。こちらは「今読んでいる
/// 本文の直前に差し込む、宛先だけに絞った軽量表示」という別用途なので、
/// 共有せず独立した薄い View にした。
///
/// `MessageHeaderCompactView.body`を膨らませないよう独立ファイルに切り出す
/// のは、このディレクトリの`QuoteHistorySectionView`/`AttachmentCardRow`が
/// 既に従っている`docs/ci.md`のSwiftUI型チェックタイムアウト対策と同じ
/// 理由。
struct MessageAddressDetailView: View {
    let message: MessageRecord

    var body: some View {
        VStack(alignment: .leading, spacing: OtegamiSpacing.sm) {
            addressGroup(label: "差出人", addresses: message.fromAddresses)
            addressGroup(label: "宛先", addresses: message.toAddresses)
            // Cc/Bcc は空なら行ごと出さない (要望の明示的な指定)。
            if !message.ccAddresses.isEmpty {
                addressGroup(label: "Cc", addresses: message.ccAddresses)
            }
            if !message.bccAddresses.isEmpty {
                addressGroup(label: "Bcc", addresses: message.bccAddresses)
            }
        }
        .padding(OtegamiSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Liquid Glass Phase 2: `QuoteHistorySectionView`/`AttachmentCardRow`
        // と同じ判断 — 本文の一部 (コンテンツ層) のカードなので Glass では
        // なくシステム階層素材 (`.quaternary`) を使う。
        .otegamiCardBackground(.quaternary)
        .accessibilityIdentifier("messageDetail.addressDetail")
    }

    /// 1フィールド分 (差出人/宛先/Cc/Bcc) — ラベル (キャプション) の下に
    /// アドレスを1行ずつ並べる。`label`を`LocalizedStringKey`で受けるのは
    /// `docs/localization.md`の「`String`型のcomputed property/switch文の
    /// 分岐値を経由する場合は`String(localized:)`か`LocalizedStringKey`
    /// ラップが要る」を避けるため — 呼び出し側は文字列リテラルしか渡さず、
    /// この値を識別子の組み立てなど表示以外の用途に使わないので、パラメータ
    /// の型自体を`LocalizedStringKey`にする方法 (同ドキュメントの方法2) が
    /// そのまま使える。
    @ViewBuilder
    private func addressGroup(label: LocalizedStringKey, addresses: [EmailAddress]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(OtegamiFont.caption())
                .foregroundStyle(OtegamiColor.inkSecondary)
            if addresses.isEmpty {
                // 固定文言 (依存関係なし) なので、CLAUDE.md の
                // 「ラベルはリテラルなので通常の`Text`」通り、動的値では
                // なくリテラルとしてそのまま書く — 既存の「なし」カタログ
                // キー (`docs/localization.md`運用ルール) をそのまま使う。
                Text("なし")
                    .font(OtegamiFont.subheadline())
                    .foregroundStyle(OtegamiColor.inkTertiary)
            } else {
                // `EmailAddress.description`は"Name <address>"(表示名あり)
                // または"address"(表示名なし)を返す — 表示名とアドレスの
                // 両方を1行で読めるようにする、という要望をこれで満たす。
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    // 差出人/宛先のアドレスは受信データそのもの (動的・
                    // 未信頼な文字列) — `Text(verbatim:)`でMarkdown解釈を
                    // 止める。`AccountFilterChip.swift`の教訓コメント
                    // (`LocalizedStringKey`経由だとアドレスが`mailto:`
                    // リンク化する実バグ前例) と同じ理由。
                    Text(verbatim: address.description)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.ink)
                        .textSelection(.enabled)
                        // アドレスは長いことがあるため、切り詰めず折り返す。
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#Preview {
    MessageAddressDetailView(
        message: MessageRecord(
            mailboxId: 1,
            uid: 1,
            fromAddresses: [EmailAddress(name: "田中太郎", address: "tanaka@example.com")],
            toAddresses: [
                EmailAddress(name: "山田花子", address: "yamada@example.com"),
                EmailAddress(address: "suzuki@example.com"),
            ],
            ccAddresses: [EmailAddress(name: "佐藤次郎", address: "sato@example.com")],
            internalDate: Date()
        )
    )
    .padding()
}
