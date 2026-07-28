import Foundation
import OtegamiStore

/// 1j "フィルタチップ（全部・添付・未読）" — applied client-side, after
/// `SearchQuery.threadSummaries` already returned its (FTS/LIKE-matched)
/// results. Deliberately not a `SearchQuery` parameter: every one of these
/// is a cheap in-memory predicate over fields the query already fetched
/// (`hasAttachments`, `unreadCount`), so re-querying GRDB for each chip tap
/// would be strictly more work for the same result, and re-filtering
/// client-side keeps the debounced-search round trip
/// (`SearchScreenView.performSearch`) the one and only place that talks to
/// the database.
///
/// **検索画面再構成 (Task #86)**: 「英語」チップ (`detectedLanguage == "en"`
/// によるフィルタ) はユーザー要望で廃止した — 添付/未読ほど頻繁に使う軸では
/// なく、翻訳機能側の言語判定 (`MessageView`の「英語で返信」等) と役割が
/// 紛らわしいという判断。`case english`自体を削除したので、過去に保存され
/// ていた可能性のある値も含め、現在の`allCases`に無い`rawValue`は
/// `persisted(rawValue:)`が安全側の`.all`にフォールバックする
/// (`SavedSearchRecord.filter`のドキュメントコメント参照)。
enum SearchFilterOption: String, CaseIterable, Identifiable {
    case all
    case attachments
    case unread

    var id: String { rawValue }

    var title: String {
        // `AccountFilterChip(title:)`が`Text(title)`(verbatim)で描画するため
        // `String(localized:)`で明示的にローカライズする。
        switch self {
        case .all: String(localized: "全部")
        case .attachments: String(localized: "添付")
        case .unread: String(localized: "未読")
        }
    }

    func matches(_ summary: ThreadSummary) -> Bool {
        switch self {
        case .all:
            true
        case .attachments:
            summary.latestMessage?.hasAttachments == true
        case .unread:
            summary.thread.unreadCount > 0
        }
    }

    /// `SavedSearchRecord.filter`から復元するときの入口 — 現在の`allCases`
    /// に無い`rawValue`(廃止済みの`"english"`を含む)は`.all`にフォールバック
    /// する。「保存済み検索」は`rawValue`をそのまま`String`として永続化して
    /// いる (`OtegamiStore`側はこの enum 自体を知らない) ため、この enum の
    /// case を将来また増減させても既存の保存データを読めなくして壊すことは
    /// ない、という後方互換の入口を1箇所に用意した。
    static func persisted(rawValue: String) -> SearchFilterOption {
        SearchFilterOption(rawValue: rawValue) ?? .all
    }
}
