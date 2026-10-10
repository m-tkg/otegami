import Foundation

/// `MessageListView.refresh()` が、既に別の `refresh()` が走っている最中に
/// 呼ばれたときの扱いを決める純粋関数。ビュー側に条件分岐を増やさない
/// (SwiftUI 型チェックタイムアウト対策) ことと、`make test` で回帰を
/// 押さえることが目的。
///
/// - ユーザー操作起点 (`surfaceErrors: true`: pull to refresh / ⌘R) は、
///   サイレントな自動パス (`surfaceErrors: false`) に相乗りしてはならない。
///   自動パスは対象アカウントが違いうる・`isAutoRetrying` ガードで no-op に
///   なりうる・失敗しても何も出ない、のいずれかで「画面に出ているものを
///   同期した」保証が無いため、cancel して自分のパスを必ず実行する。
/// - それ以外 (ユーザー操作同士、自動パスが来た場合) は従来どおり相乗り。
public enum RefreshReentryPolicy {
    public enum Decision: Equatable, Sendable {
        /// 走行中のパスの完了を待つだけで、自分では同期しない。
        case joinRunning
        /// 走行中のパスを cancel し、その完了後に自分のパスを実行する。
        case preemptRunning
    }

    public static func decide(incomingSurfacesErrors: Bool, runningSurfacesErrors: Bool) -> Decision {
        incomingSurfacesErrors && !runningSurfacesErrors ? .preemptRunning : .joinRunning
    }
}
