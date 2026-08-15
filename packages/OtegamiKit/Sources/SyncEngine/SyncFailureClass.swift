import MailTransport

/// Whether a `MailTransportError` means "this connection/credential is
/// broken" (worth aborting the *whole* `OpQueueProcessor.replay(account:
/// auth:)` batch over, rather than burning through every remaining op's
/// attempts budget on the same underlying cause) or "this particular op is
/// invalid" (an ordinary per-op `recordFailure`/backoff — unrelated ops in
/// the same batch still proceed).
///
/// Replaces `OpQueueProcessor`'s former private `isConnectionLevel(_:) ->
/// Bool` — same classification, reified as an enum ("FailureClass ベースの
/// 判定") rather than a bare `Bool`.
///
/// **Deliberately not** `AccountSyncer`'s own private `FailureClass`/
/// `classify(_:)`, even though the names rhyme: that type answers a
/// materially different question — "should this *sync* attempt retry, and
/// how" (`.authentication`/`.networkUnreachable`/`.other`/`.suspended`/
/// `.cancelled`) — and the two taxonomies genuinely disagree on the same
/// inputs. `AccountSyncer.classify` puts `MailTransportError.notConnected`/
/// `.cancelled` in `.other` ("retry normally"), while `classify(_:)` below
/// puts them in `.connectionLevel` ("stop replaying immediately"). Forcing
/// `OpQueueProcessor` onto `AccountSyncer`'s taxonomy would silently change
/// which of those two very different treatments a `.notConnected`/
/// `.cancelled` failure gets — exactly the kind of well-intentioned
/// "unification" this refactor was warned could reintroduce a fixed bug.
/// `AccountSyncer.swift` is also out of scope for this pass (a different
/// concurrent refactor owns it).
enum SyncFailureClass: Equatable {
    case connectionLevel
    case perOperation

    /// Exactly `OpQueueProcessor`'s former `isConnectionLevel(_:)` body,
    /// only relocated and reified — same four-case/five-case split.
    /// Deliberately narrow: only ever consulted for a `MailTransportError`
    /// that `replay(account:auth:)`'s own `catch let error as
    /// MailTransportError where ...` clause has already isolated —
    /// `CancellationError`/`DatabaseSuspensionSupport.isSuspensionError`
    /// conditions are handled by the two `catch` clauses immediately above
    /// that one in `replay(account:auth:)` and never reach this classifier
    /// at all. This function has no opinion on either — preserving that
    /// narrow scope was an explicit requirement of this refactor.
    static func classify(_ error: MailTransportError) -> SyncFailureClass {
        switch error {
        // `.tooManyConnections` が connection-level 側にいるのは、これが
        // 「この op が悪い」ではなく「このアプリが自分で接続を張りすぎた」
        // 失敗だから。per-operation に置くと `attempts` が積まれ、5 回で
        // 恒久失敗して**アーカイブや既読化が永久にサーバーへ届かなくなる**
        // — 実際には少し待てば通る操作なので、バッチを中断して次の replay
        // に回すのが正しい扱い。
        case .connectionFailed, .notConnected, .cancelled, .authenticationFailed, .tooManyConnections:
            .connectionLevel
        case .serverError, .malformedResponse, .mailboxNotFound, .notImplemented, .invalidAddress:
            .perOperation
        }
    }
}
