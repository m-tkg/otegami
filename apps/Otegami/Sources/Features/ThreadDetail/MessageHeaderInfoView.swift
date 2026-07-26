import SwiftUI
import OtegamiCore
import OtegamiStore

/// 新画面構成 (3): メール本文画面フッターツールバーの「情報」— "メールヘッダの
/// 詳細を表示（Message-ID、Received チェーン、Content-Type、実際の生ヘッダ
/// 等。生ヘッダは保存していなければ envelope にある情報 + 取得可能なら生
/// ヘッダ）"。
///
/// **スコープ上の判断**: このアプリは受信メールの生ヘッダ (RFC822 の `HEADER`
/// パート全体) を一度も保存していない (`MessageBodyRecord` は本文のみ) —
/// `MailTransport`/`MailCoreIMAPSession` にも生ヘッダだけを取得する API が
/// 無く、新設するには IMAP `FETCH BODY[HEADER]` の新しい往復を transport 層
/// から通す必要がある (このバッチの他の作業に対して不釣り合いなコスト、と
/// 判断)。**Received チェーンも生ヘッダの一部であり、同じ理由で表示できない**
/// — 代わりに、ローカル DB に既にある envelope 由来の情報 (Message-ID、
/// In-Reply-To、References、From/To/Cc/Bcc/Reply-To、件名、日時、サイズ、
/// 保存されているメールボックスのパス) と、本文から判定した Content-Type を
/// 表示する。生ヘッダ取得は次フェーズの課題として `docs/design-system.md`
/// に記録した。
struct MessageHeaderInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let message: MessageRecord
    let references: [String]
    let mailboxPath: String?
    let contentType: String

    var body: some View {
        NavigationStack {
            List {
                Section("識別子") {
                    infoRow("Message-ID", message.messageId)
                    infoRow("In-Reply-To", message.inReplyTo)
                    if !references.isEmpty {
                        infoRow("References", references.joined(separator: "\n"))
                    }
                }
                Section("ヘッダ") {
                    infoRow("件名", message.subject)
                    infoRow("From", addressListText(message.fromAddresses))
                    infoRow("To", addressListText(message.toAddresses))
                    if !message.ccAddresses.isEmpty {
                        infoRow("Cc", addressListText(message.ccAddresses))
                    }
                    if !message.bccAddresses.isEmpty {
                        infoRow("Bcc", addressListText(message.bccAddresses))
                    }
                    if !message.replyToAddresses.isEmpty {
                        infoRow("Reply-To", addressListText(message.replyToAddresses))
                    }
                    infoRow("Date", (message.date ?? message.internalDate).formatted(.dateTime.year().month().day().hour().minute().second()))
                    infoRow("Content-Type", contentType)
                }
                Section("その他") {
                    infoRow("メールボックス", mailboxPath)
                    infoRow("UID", "\(message.uid)")
                    infoRow("サイズ", ByteCountFormatter.string(fromByteCount: Int64(message.size), countStyle: .file))
                }
                Section {
                    Text("生ヘッダ (Received チェーンを含む RFC822 ヘッダ全体) はこのアプリでは保存していないため表示できません。上記はローカルに保存されている envelope 情報です。")
                        .font(OtegamiFont.caption())
                        .foregroundStyle(OtegamiColor.inkSecondary)
                        .accessibilityIdentifier("messageInfo.rawHeaderUnavailableNote")
                }
            }
            .navigationTitle("メールの情報")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("messageInfo.closeButton")
                }
            }
        }
        .tint(OtegamiColor.accent)
        .accessibilityIdentifier("messageInfo.navigationStack")
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // `label`は英字のフィールド名 ("Message-ID"等) と日本語の
                // ラベル ("件名"等) が混在する — `label`自体は
                // `.accessibilityIdentifier`の組み立てにも使うので`String`の
                // ままにし、表示だけ`LocalizedStringKey(label)`でラップして
                // `Localizable.xcstrings`を引かせる (該当エントリがない
                // 英字ラベルはそのままキー自体が表示されるだけで安全)。
                Text(LocalizedStringKey(label))
                    .font(OtegamiFont.caption())
                    .foregroundStyle(OtegamiColor.inkSecondary)
                Text(value)
                    .font(OtegamiFont.body())
                    .foregroundStyle(OtegamiColor.ink)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("messageInfo.row.\(label)")
        }
    }

    private func addressListText(_ addresses: [EmailAddress]) -> String {
        addresses.map(\.description).joined(separator: ", ")
    }
}
