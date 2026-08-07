import Foundation
import GRDB

/// `SyncEngine.OpQueueProcessor.replay`が`.staleDiscarded`
/// (対象メールボックスの`uidValidity`がenqueue時と変わっており、UID が
/// 無効化された — フォルダの再作成などが原因) と判定した`opQueue`行を、
/// 削除する前に記録しておくための表。
///
/// 実機報告「Gmail で既読化/アーカイブしてもサーバに反映されず、再読込で
/// サーバ状態に巻き戻る」の調査で分かった容疑の一つが、この
/// `.staleDiscarded`パスが未送信 op を**無言で**削除していたこと —
/// ユーザーからは「操作したのに何も起きなかった」としか見えず、原因の
/// 手がかりが一切残らなかった。`opQueue`テーブル自身に恒久失敗として
/// 残す (既存の`OpQueueProcessor.maxAttempts`到達パス) のではなくこの
/// 専用表に切り出したのは、stale な op は uidValidity が変わった時点で
/// 原理的に再送不可能 — `opQueue`に残し続けて「再試行」導線を見せても
/// 無意味なため。`OpQueueProcessor`は記録と同じトランザクションで
/// `opQueue`行を削除する (`OpQueueProcessor.recordStaleDiscardAndDelete`)。
///
/// `apps/Otegami/Sources/Features/Sidebar/FailedOperationsView.swift`
/// (「同期エラー」画面) が恒久失敗のopと並べてこの表の直近の行も表示し、
/// ユーザーが手動で消去できるようにする — 既存の「恒久失敗を見せて
/// ユーザーに気付かせる」導線をそのまま踏襲する。設定の「操作同期の診断」
/// 画面 (`OpQueueDiagnosticsView`) にも件数として出るため、二重に
/// 観測できる。
public struct OpQueueStaleDiscardRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "opQueueStaleDiscard"

    public var id: Int64?
    public var accountId: String
    /// `OpQueueKind.rawValue` — `OpQueueRecord.kind`と同じ生文字列カラム。
    public var kind: String
    public var discardedAt: Date
    /// ユーザー向けの理由文 (日本語、`OpQueueProcessor`が生成)。
    /// `OpQueueRecord.lastError`と同じ「UI にそのまま出す説明文」の役割。
    public var reason: String

    public init(id: Int64? = nil, accountId: String, kind: String, discardedAt: Date = Date(), reason: String) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.discardedAt = discardedAt
        self.reason = reason
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
