import Foundation
import GRDB
import OtegamiStore

/// 「このメールボックスの、この UID には、まだサーバーへ送れていない
/// ローカル変更がある」— 同期パスがサーバー由来のエンベロープ/フラグで
/// ローカルを上書きしてよいかを判断するためのガード。
///
/// 実機報告 (2026-08-07)「受信箱のグループの画面で一括で Gmail を
/// アーカイブした後、Gmail に移動して再読み込みするとまだ復活してしまう」
/// の修正。それまでの同期は `opQueue` を一切見ていなかったため、次の
/// 順序で「アーカイブしたはずのメールが受信トレイに戻る」が成立していた:
///
/// 1. アーカイブすると `MessageRemoval.commit` が `opQueue` に op を積み、
///    ローカルの `message` 行を消す (Gmail は仮配置 (pending relocation) を
///    使わない — Gmail に `\Archive` 相当の実体フォルダが無いため、
///    `MessageRemoval.destinationMailbox` の doc comment 参照)。
/// 2. その op がまだ replay されていない (あるいは失敗して溜まっている)
///    間、サーバーの受信トレイにはそのメールがまだ居る。
/// 3. 次の同期の `MailboxSyncer.applyFlagsDiffAndReconcileUnknown` が、
///    サーバーにあってローカルに無い UID を「取りこぼし」とみなして
///    エンベロープを取り直し `EnvelopePersister.upsert` する → 復活。
///
/// 既読も同じ形で巻き戻っていた: `setFlags` op が未送信のうちは
/// サーバーの `\Seen` はまだ古いので、フラグ同期がそれをローカルへ
/// 書き戻すと既読が未読に戻る。
///
/// このガードの原則は offline-first の原則
/// (`docs/architecture.md`「何をもって『offline-first』とするか」) の
/// 素直な帰結: **未送信のローカル変更がある UID については、サーバー側の
/// 状態はまだ古いと分かっているので取り込まない。** op が replay されて
/// `opQueue` 行が消えれば、サーバー側も既に反映済みなので、そのまま
/// 通常の同期に戻る (このガードは自然に外れる)。
///
/// 恒久失敗した op が残り続けている間は、その UID は同期で復活しない
/// ままになる — これは「アーカイブしたつもり」というユーザーの意図と
/// 一致する側の挙動。取り消したい場合は設定→一般→「操作同期の診断」の
/// 「未送信の操作を破棄」で `opQueue` 行を消せば、次の同期でサーバーの
/// 状態が改めて取り込まれる。
public struct PendingOpTargets: Sendable, Equatable {
    /// このメールボックスから**出ていったことになっている** UID
    /// (`archive`/`delete`/`junk`/`unarchive`/`move` の移動元、
    /// `deleteDraft` の削除対象)。同期で行を作り直してはいけない。
    public var relocated: Set<Int64>
    /// このメールボックス内で**フラグを変えたことになっている** UID
    /// (`setFlags`)。サーバーの古いフラグで上書きしてはいけない。
    public var flagChanged: Set<Int64>

    /// 何もガードしない — `opQueue` を参照しない呼び出し (テスト、および
    /// 同期以外の経路) 用。
    public static let none = PendingOpTargets(relocated: [], flagChanged: [])

    public init(relocated: Set<Int64>, flagChanged: Set<Int64>) {
        self.relocated = relocated
        self.flagChanged = flagChanged
    }

    public var isEmpty: Bool { relocated.isEmpty && flagChanged.isEmpty }

    /// `uid` の行をサーバー由来の内容で作成/更新してよいか — `false` なら
    /// その UID は今回の同期では触らない。移動系とフラグ系を区別せず
    /// 1つの述語にしているのは、どちらの場合も「サーバーが持っている
    /// のは古い状態」であることに変わりがなく、行の一部だけ更新しても
    /// 意味のある中間状態にならないため。
    public func blocks(uid: Int64) -> Bool {
        relocated.contains(uid) || flagChanged.contains(uid)
    }

    /// `mailboxId` を対象にした未送信 op を集める。
    ///
    /// `uidValidity` が現在のメールボックスのものと一致する op だけを
    /// 見る — 一致しないものは replay 時に stale として破棄される運命
    /// (`OpQueueProcessor` の `.staleDiscarded`) なので、ガードしても
    /// サーバー状態の取り込みを無駄に遅らせるだけになる。
    ///
    /// 呼び出し側は**エンベロープごとではなく同期パスごとに1回**呼ぶこと
    /// (1回の `write` ブロックの外側で組み立てて、ループへ渡す) —
    /// `opQueue` が数千行溜まっている実機の状態でも、この decode が
    /// メッセージ件数ぶん繰り返されないようにするため。
    public static func forMailbox(mailboxId: Int64, accountId: String, db: Database) throws -> PendingOpTargets {
        guard let mailbox = try MailboxRecord.fetchOne(db, key: mailboxId) else { return .none }
        let ops = try OpQueueRecord.filter(Column("accountId") == accountId).fetchAll(db)
        guard !ops.isEmpty else { return .none }

        let decoder = JSONDecoder()
        var relocated: Set<Int64> = []
        var flagChanged: Set<Int64> = []
        for op in ops {
            switch OpQueueKind(rawValue: op.kind) {
            case .setFlags:
                guard let payload = try? decoder.decode(SetFlagsOpPayload.self, from: op.payload),
                      payload.mailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                flagChanged.formUnion(payload.uids.map(Int64.init))
            case .move:
                guard let payload = try? decoder.decode(MoveOpPayload.self, from: op.payload),
                      payload.sourceMailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.formUnion(payload.uids.map(Int64.init))
            case .delete:
                guard let payload = try? decoder.decode(DeleteOpPayload.self, from: op.payload),
                      payload.sourceMailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.formUnion(payload.uids.map(Int64.init))
            case .junk:
                guard let payload = try? decoder.decode(JunkOpPayload.self, from: op.payload),
                      payload.sourceMailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.formUnion(payload.uids.map(Int64.init))
            case .archive:
                guard let payload = try? decoder.decode(ArchiveOpPayload.self, from: op.payload),
                      payload.sourceMailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.formUnion(payload.uids.map(Int64.init))
            case .unarchive:
                guard let payload = try? decoder.decode(UnarchiveOpPayload.self, from: op.payload),
                      payload.sourceMailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.formUnion(payload.uids.map(Int64.init))
            case .deleteDraft:
                guard let payload = try? decoder.decode(DeleteDraftOpPayload.self, from: op.payload),
                      payload.mailboxId == mailboxId, payload.uidValidity == mailbox.uidValidity else { continue }
                relocated.insert(Int64(payload.uid))
            case .send, .saveDraft, nil:
                // 送信・下書き保存はどちらも「まだサーバーに存在しない
                // メールを作る」op で、既存の `(mailboxId, uid)` を対象に
                // していない — ガードするものが無い。
                continue
            }
        }
        return PendingOpTargets(relocated: relocated, flagChanged: flagChanged)
    }
}
