import Foundation

/// 実機フィードバック第3弾 (F): 表示・操作改善バッチで追加したアプリ内蔵の
/// 「表示言語」設定 (システムに従う/日本語/English の3択ピッカー + 反映には
/// 再起動が必要という案内) は**廃止した** — 言語切替は iOS 標準の「アプリ
/// ごとの言語」(設定 → otegami → 言語) に委ねる。理由: このアプリの
/// `Info.plist` はすでに `CFBundleLocalizations: [ja, en]` を宣言しており
/// (`docs/localization.md`)、OS 標準機能がまさにこの用途のために存在する —
/// 独自の `AppleLanguages` 直接書き換え (`UserDefaults` の内部キーを手動で
/// 上書きする、公式には非推奨のテクニック) を自前で維持する理由がなくなっ
/// た。OS 標準の「アプリごとの言語」は設定変更時に OS がプロセスを再起動する
/// ため、旧実装が抱えていた「ホーム画面に戻っただけでは反映されない」問題
/// 自体も構造的に解消される。
///
/// この型自体は削除せず、`effectiveLanguageCode` だけを残した —
/// `MessageView`の翻訳バー表示条件・AI要約の出力言語判定が「メールの言語 ≠
/// アプリの表示言語」を判定するために引き続き必要な機能で、これは表示言語の
/// **選択 UI** ではなく **現在有効な表示言語を読む**だけの読み取り専用機能
/// であり、廃止対象の範囲外 (`docs/settings.md`のF節参照)。
enum LocalizationSettingsStore {
    /// 表示・操作改善バッチが書き込んでいた `AppleLanguages` の標準
    /// `UserDefaults` キー — この設定自体は廃止したが、既にこのキーへ
    /// 明示的な言語配列 (`["ja"]`/`["en"]`) を書き込んでいた既存ユーザーの
    /// 端末では、そのままではこのアプリ**だけ**が (OS の「アプリごとの
    /// 言語」設定を無視して) 上書きされた言語のまま固定されてしまう —
    /// `migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded()`がこの残骸を
    /// 一度だけ消す。
    private static let legacyAppleLanguagesKey = "AppleLanguages"

    /// `AppEnvironment.init()`から起動のたびに (冪等に) 呼ばれる移行処理 —
    /// 既存ユーザーが表示言語ピッカーで「日本語」/「English」を明示選択して
    /// いた場合に残る`AppleLanguages`上書きを一度だけ削除し、OS本来の
    /// 言語解決 (「アプリごとの言語」を含む) に戻す。廃止済み設定が使って
    /// いた選択値の保存キー (`"app.languageOption"`) 自体は消さない —
    /// 実際の言語解決にはもう使われない無害な残骸で、G節の「アイコンバッジ」
    /// 設定廃止時と同じ「UserDefaultsの残骸はそのまま無視で可」という判断を
    /// 踏襲した。すでに上書きが無い (これから初めてこのバージョンを使う
    /// ユーザー、または既に一度移行済みのユーザー) 場合は`object(forKey:)`
    /// が`nil`を返すだけの無害な no-op。
    static func migrateAwayFromLegacyAppleLanguagesOverrideIfNeeded() {
        guard UserDefaults.standard.object(forKey: legacyAppleLanguagesKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: legacyAppleLanguagesKey)
    }

    /// 「今実際にどの言語で表示されているか」を "ja"/"en" (またはそれ以外の
    /// システム言語コード) で返す — 本文画面の翻訳ボタン表示条件・AI要約の
    /// 出力言語判定に使う。`Bundle.main.preferredLocalizations`は OS が
    /// 実際に解決した結果 (システム全体の言語設定、または「アプリごとの
    /// 言語」による本アプリだけの個別指定のどちらでも) をそのまま反映する
    /// — 上記の移行処理により`AppleLanguages`の自前上書きが無くなった後は、
    /// これが唯一の真実の情報源になる。
    static var effectiveLanguageCode: String {
        Bundle.main.preferredLocalizations.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            ?? "ja"
    }
}
