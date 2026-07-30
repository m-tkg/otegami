import Foundation
import GRDB

/// A message's fetched body (plain text and/or HTML), populated lazily by
/// `SyncEngine`'s body fetch (M2). Schema exists from v1; unused until then.
public struct MessageBodyRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageBody"

    /// 2026-07-30 (実機フィードバック: 通知メールの翻訳失敗の真因が
    /// `MailCoreIMAPSession+Mapping.swift`の`html(from:)`だったと判明・
    /// 修正した後も、同じメールでまだ失敗した — 原因はこの修正が**新規
    /// フェッチにしか効かない**こと。既存の`messageBody`行には修正前の
    /// 壊れたhtmlがそのまま残っており、翻訳・HTML表示のどちらもそれを
    /// 読み続けていた。Task #134でも全く同じ制約 (「既存キャッシュは
    /// 移行しない方針」) を踏んでいる。
    ///
    /// 本文の生成ロジック (`MailCoreIMAPSession.bodyContent(from:)`) を
    /// 変えるたびに1ずつ上げる版数 — `currentRenderVersion`が「今のコード
    /// で書いたらこの値になる」を表す。保存済みの行がこれより古ければ
    /// 「本文キャッシュ未取得」と同等に扱い、そのメッセージを開いた
    /// タイミングで**遅延的に**再フェッチする (`MessageView.load()`の
    /// キャッシュ利用ガード参照) — 起動時に全件を一括再取得することは
    /// しない (数千件規模になりうるため)。
    ///
    /// マイグレーションでは新カラムに`DEFAULT 0`を与えるだけで済ませる
    /// (SQLite側が既存行全てへ自動適用する、手動バックフィルループ不要
    /// — `AppDatabase.swift`のv36マイグレーション参照)。`0`は
    /// `currentRenderVersion`より必ず古い値であり続けるよう、この定数を
    /// 上げるときは`0`を再利用しない。
    public static let currentRenderVersion = 1

    /// Shares its primary key with `MessageRecord.id` (one body per
    /// message).
    public var messageId: Int64
    public var plainText: String?
    public var html: String?
    public var fetchedAt: Date?
    public var renderVersion: Int

    public init(messageId: Int64, plainText: String? = nil, html: String? = nil, fetchedAt: Date? = nil, renderVersion: Int = MessageBodyRecord.currentRenderVersion) {
        self.messageId = messageId
        self.plainText = plainText
        self.html = html
        self.fetchedAt = fetchedAt
        self.renderVersion = renderVersion
    }
}
