import Foundation
import OtegamiStore

/// Task #147 (実機報告「本文の後着で要約/翻訳ボタンが有効化されない」):
/// `MessageView.load()`は開いた時点の一回きりの取得で完結し、その後に
/// ローカルDBへ届いた本文 (バックグラウンドプリフェッチの書き込み、または
/// `load()`自身のネットワーク取得と競合していた別経路の完了) を二度と観測
/// しない — `bodyRecord`が`nil`のまま`syncAIFeaturesState()`が再実行されず、
/// 要約/翻訳ボタンがアプリ再起動まで有効化されなかった実機報告の原因
/// (Task #64が導入した「`bodyRecord != nil`ゲート」自体は正しいが、その値を
/// 更新する経路が`load()`一本しかなかったのが根本原因)。
///
/// 修正は`MessageView`が`messageBody`行への`ValueObservation`を追加で張り、
/// 展開中/表示中のこのメッセージだけを継続監視すること (`MessageView
/// .observeBodyRecordChanges()`) — この型はその観測が届けた値ごとに
/// 「実際に反映する価値のある変化かどうか」を判定する部分だけを、SwiftUIの
/// view lifecycle から切り離してテスト可能にしたもの。`MessageReadMarker`
/// (Task #96) / `MessageRemoval` と同じ「app target の private メソッドを
/// `SyncEngine`のプレーンな関数へ抜き出し、`AppDatabase.makeInMemory()`無しの
/// 純粋ロジックとしてテストする」方針。
public enum MessageBodyObservationGate {
    /// `true`なら`MessageView`は`incoming`を新しい`bodyRecord`として採用し、
    /// mark-as-read/`syncAIFeaturesState()`/自動翻訳キックオフの一連の
    /// post-body-load パイプラインを再実行すべき。
    ///
    /// - `incoming`が`nil`(本文行がまだ存在しない、または削除された)なら
    ///   常に`false` — `load()`自身がすでに「取得中」/エラー表示をしている
    ///   ところへ、この観測が余計に空へ巻き戻す理由が無い。
    /// - `incoming`が`current`と等しい (GRDBの`ValueObservation`は追跡
    ///   テーブルへの*どんな*書き込みでもクエリを再実行する — この行自身の
    ///   列が変わっていない再配信もありうる) なら`false` — 同じ内容の
    ///   パイプライン再実行は無駄なだけでなく、`kickoffTranslationIfNeeded`
    ///   が呼ばれるたびに`requestTranslation`自身の`translateTask == nil`
    ///   ガードに救われる程度には無害だが、それでも避けられる仕事は避ける。
    /// - それ以外 (`incoming`が非`nil`で`current`と異なる) は`true` —
    ///   初回取得 (`current == nil`) と、後から内容が変わった再取得の両方を
    ///   カバーする。
    public static func shouldApply(current: MessageBodyRecord?, incoming: MessageBodyRecord?) -> Bool {
        guard let incoming else { return false }
        return incoming != current
    }
}
