import SwiftUI
import OtegamiStore

/// Task #76 (Spark 参考画像): 添付ファイルを「アイコン + ファイル名 (2行
/// 省略) + サイズ」のカードとして表示する — `MessageView.attachmentSection`
/// の `ForEach` の中身をここに切り出したもの (CLAUDE.md の「行を描画する
/// `ForEach`/`List` の中身は独立した `View` 型に切り出す」というCI型
/// チェックタイムアウト対策のルール参照)。
///
/// タップ時の挙動 (ダウンロード済みならQuickLook、未取得ならスピナー付き
/// 取得→QuickLook、失敗ならエラー表示) は `MessageView.openAttachment(_:)`
/// がそのまま担う — このViewは見た目と、状態を受け取って出し分けるだけの
/// 薄いラッパー。エラー時の「再試行」はカード全体をもう一度タップすれば
/// 同じ`openAttachment(_:)`が再実行される (`fetchingAttachmentIds`に
/// 入っていない・`localPath`がまだ`nil`という条件は変わらないため) ので、
/// 専用の再試行ボタンは持たず、エラー行に表示する`arrow.clockwise`アイコン
/// は「もう一度タップすれば再試行できる」ことを示すだけの装飾。
struct AttachmentCardRow: View {
    let attachment: AttachmentRecord
    let isDownloading: Bool
    let errorMessage: String?
    let onTap: () -> Void

    private var attachmentId: Int64 { attachment.id ?? 0 }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: OtegamiSpacing.sm) {
                iconChip
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayFilename)
                        .font(OtegamiFont.subheadline())
                        .foregroundStyle(OtegamiColor.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.destructive)
                            .lineLimit(2)
                            .accessibilityIdentifier("messageDetail.attachment.\(attachmentId).error")
                    } else {
                        Text(Self.formattedSize(attachment.size))
                            .font(OtegamiFont.caption())
                            .foregroundStyle(OtegamiColor.inkSecondary)
                    }
                }
                Spacer(minLength: OtegamiSpacing.sm)
                trailingControl
            }
            .padding(OtegamiSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Liquid Glass Phase 2: `QuoteHistorySectionView`と同じ判断 —
        // 本文中のコンテンツ層カードなので Glass ではなくシステム階層
        // 素材 (`.quaternary`) へ。
        .otegamiCardBackground(.quaternary)
        .accessibilityIdentifier("messageDetail.attachment.\(attachmentId)")
    }

    private var iconChip: some View {
        let kind = AttachmentKind(mimeType: attachment.mimeType, mimeSubtype: attachment.mimeSubtype)
        return Image(systemName: kind.symbolName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(kind.tintColor)
            .clipShape(RoundedRectangle(cornerRadius: OtegamiRadius.card, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isDownloading {
            ProgressView()
                .accessibilityIdentifier("messageDetail.attachment.\(attachmentId).loading")
        } else if errorMessage != nil {
            // 装飾のみ (このViewのdoc comment参照) — タップ判定はカード
            // 全体を覆う外側の`Button`が担う。
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OtegamiColor.destructive)
                .accessibilityHidden(true)
        } else if let localPath = attachment.localPath {
            // 保存 (plan: "iOS: ShareLink / fileExporter、macOS: 保存
            // パネル") — `ShareLink` works on both platforms (a share sheet
            // on iOS, `NSSharingServicePicker` on macOS), so one
            // cross-platform control covers both rather than diverging per
            // platform here.
            ShareLink(item: URL(fileURLWithPath: localPath)) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(OtegamiColor.inkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("messageDetail.attachment.\(attachmentId).shareButton")
        }
    }

    private var displayFilename: String {
        attachment.filename?.isEmpty == false ? attachment.filename! : String(localized: "添付ファイル")
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// ファイル種別ごとのアイコン/色分け (Task #76: 「ファイル種別アイコン
/// (PDF=赤系ドキュメントアイコン、画像、アーカイブ等で色/シンボル分け)」)。
/// 新しい色をその場で追加せず、既存の`OtegamiColor`トークンだけを再利用する
/// (CLAUDE.md/`docs/design-system.md`の「新しい色をその場で追加しない」
/// 方針) — PDFは`destructive`(赤系、参考画像通り)、画像は`accent`
/// (水色系)、それ以外 (動画・音声・アーカイブ・汎用) は`inkSecondary`
/// (グレー) の3色に分ける。
enum AttachmentKind {
    case pdf
    case image
    case video
    case audio
    case archive
    case generic

    init(mimeType: String, mimeSubtype: String) {
        let type = mimeType.lowercased()
        let subtype = mimeSubtype.lowercased()
        switch type {
        case "image":
            self = .image
        case "video":
            self = .video
        case "audio":
            self = .audio
        case "application" where subtype == "pdf":
            self = .pdf
        case "application" where Self.archiveSubtypes.contains(subtype):
            self = .archive
        default:
            self = .generic
        }
    }

    /// A conservative, non-exhaustive list of common archive MIME
    /// subtypes — good enough to distinguish "an archive" from "some other
    /// generic file" for icon purposes; not meant to be a complete
    /// registry of every archive format that exists.
    private static let archiveSubtypes: Set<String> = [
        "zip", "x-zip-compressed", "x-tar", "gzip", "x-gzip",
        "x-7z-compressed", "x-rar-compressed", "x-bzip2",
    ]

    var symbolName: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .generic: "doc.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .pdf: OtegamiColor.destructive
        case .image: OtegamiColor.accent
        case .video, .audio, .archive, .generic: OtegamiColor.inkSecondary
        }
    }
}
