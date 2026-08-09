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
        let ops = try OpQueueRecord.filter(Column("accountId") == accountId).fetchAll(db)
        guard !ops.isEmpty else { return .none }
        // 1回だけ引く。アカウントのメールボックスは高々数十行で、
        // 別メールボックスを対象にした op の `uidValidity` を**その
        // メールボックス自身の値**と突き合わせるのに要る (引数の
        // メールボックスの値と比べても意味が無い)。
        let mailboxesById: [Int64: MailboxRecord] = try Dictionary(
            uniqueKeysWithValues: MailboxRecord
                .filter(Column("accountId") == accountId)
                .fetchAll(db)
                .compactMap { mailbox in mailbox.id.map { ($0, mailbox) } }
        )
        guard let mailbox = mailboxesById[mailboxId] else { return .none }

        let decoder = JSONDecoder()
        var relocated: Set<Int64> = []
        var flagChanged: Set<Int64> = []
        // 別メールボックスを対象にした `setFlags` op — 下でまとめて
        // 兄弟行を解決する (理由は`case .setFlags`のコメント)。
        var foreignFlagTargets: [Int64: Set<Int64>] = [:]
        for op in ops {
            switch OpQueueKind(rawValue: op.kind) {
            case .setFlags:
                // 実機報告 (2026-08-07)「メールの unpin が反映されない」の
                // **1番目の層**: フラグ (`\Flagged`/`\Seen`) はラベルでは
                // なく**メッセージ**に付くプロパティなので、ある行に未送信の
                // フラグ変更があるなら、同じ物理メッセージを指す**すべての
                // 行**についてサーバー報告のフラグが古い。
                // `MessagePinReadState.applyToDuplicateSiblings` が
                // 「op は代表行のぶんだけでよい」と判断している論理の裏返し
                // であって、同じ前提から出てくる。
                //
                // これを見ていなかったため、INBOX の行を unpin した直後に
                // All Mail 側の同期が走ると、サーバーがまだ返す `\Flagged`
                // で兄弟行が `true` に戻され、`ThreadRecord.isPinned` 経由で
                // ピンが復活していた (この関数が payload の `mailboxId`
                // 一致でしか見ていなかったので、All Mail の UID は誰にも
                // ブロックされなかった)。
                //
                // **移動系 (`archive`/`move`/`delete`/`junk`) は広げない** —
                // 所属はラベルごとの性質で、Gmail のアーカイブは INBOX
                // ラベルを外すだけ、All Mail 側の行は**残るのが正しい**。
                // ここまで広げると正しい行を消してしまう。
                guard let payload = try? decoder.decode(SetFlagsOpPayload.self, from: op.payload) else { continue }
                if payload.mailboxId == mailboxId {
                    guard payload.uidValidity == mailbox.uidValidity else { continue }
                    flagChanged.formUnion(payload.uids.map(Int64.init))
                } else {
                    guard let origin = mailboxesById[payload.mailboxId],
                          payload.uidValidity == origin.uidValidity else { continue }
                    foreignFlagTargets[payload.mailboxId, default: []].formUnion(payload.uids.map(Int64.init))
                }
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

        // 別メールボックス対象の `setFlags` op から、このメールボックス側の
        // 兄弟行の UID を引く。対象が無ければ (非 Gmail アカウントでは常に
        // そう — `setFlags` は必ず自メールボックス対象) ここは1クエリも
        // 走らないので、従来とコストが変わらない。
        //
        // 兄弟由来の UID を新しいフィールドに分けず `flagChanged` へ
        // マージするのは、`blocks(uid:)`/`EnvelopePersister.upsert`/
        // `MailboxSyncer.applyFlagsDiffAndReconcileUnknown` を無変更で
        // 済ませるため。兄弟解決は**ローカル行が存在してはじめて成立する**
        // ので、`flagChanged` と同じ「行は既にある、内容が古いだけ」という
        // 性質を持つ (`upsert` を丸ごとスキップしても行が作られないまま
        // 残る、という問題は起きない)。
        for (originMailboxId, uids) in foreignFlagTargets {
            flagChanged.formUnion(
                try ThreadQuery.duplicateSiblingUIDs(
                    ofUIDs: uids, in: originMailboxId, siblingMailboxId: mailboxId, db: db
                )
            )
        }
        return PendingOpTargets(relocated: relocated, flagChanged: flagChanged)
    }

    /// `op` がガードしているメールボックス — `forMailbox` がこの op を見て
    /// `relocated`/`flagChanged` に UID を入れることになる側の `mailboxId`
    /// (移動系は**移動元**、`setFlags`/`deleteDraft` は payload 自身の
    /// メールボックス、`send`/`saveDraft` は対象なし)。
    ///
    /// `OpQueueProcessor` が op を消したあと「このメールボックスのガードが
    /// 1つ外れた」ことを知るために使う。DB を読まないので、replay の削除
    /// トランザクションの中から安全に呼べる。
    ///
    /// `forMailbox` の各 `case` と定義が食い違うと、ガードが外れたのに
    /// 気づけない (あるいは無関係なメールボックスを触る) ので、
    /// `PendingOpTargetsTests` で両者の対応をテーブル駆動で固定してある。
    public static func targetMailboxIds(of op: OpQueueRecord) -> Set<Int64> {
        let decoder = JSONDecoder()
        switch OpQueueKind(rawValue: op.kind) {
        case .setFlags:
            guard let payload = try? decoder.decode(SetFlagsOpPayload.self, from: op.payload) else { return [] }
            return [payload.mailboxId]
        case .move:
            guard let payload = try? decoder.decode(MoveOpPayload.self, from: op.payload) else { return [] }
            return [payload.sourceMailboxId]
        case .delete:
            guard let payload = try? decoder.decode(DeleteOpPayload.self, from: op.payload) else { return [] }
            return [payload.sourceMailboxId]
        case .junk:
            guard let payload = try? decoder.decode(JunkOpPayload.self, from: op.payload) else { return [] }
            return [payload.sourceMailboxId]
        case .archive:
            guard let payload = try? decoder.decode(ArchiveOpPayload.self, from: op.payload) else { return [] }
            return [payload.sourceMailboxId]
        case .unarchive:
            guard let payload = try? decoder.decode(UnarchiveOpPayload.self, from: op.payload) else { return [] }
            return [payload.sourceMailboxId]
        case .deleteDraft:
            guard let payload = try? decoder.decode(DeleteDraftOpPayload.self, from: op.payload) else { return [] }
            return [payload.mailboxId]
        case .send, .saveDraft, nil:
            return []
        }
    }
}
