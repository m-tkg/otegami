import Foundation

/// 表示・操作改善バッチ「表示言語の設定」— アプリ UI の言語を「システムに従う /
/// 日本語 / English」から選べるようにする設定。`AccountsListContent`(iOS の
/// 「設定」/macOS Settings シーン)の新しい「表示」セクションで選択し、この
/// 値は2つのことに使われる:
///
/// 1. `AppleLanguages`(`UserDefaults` の標準キー、`Bundle.main`のローカライズ
///    解決が起動時に読む) の上書き — 次回起動から `Localizable.xcstrings`
///    (`docs/localization.md`参照)のen/ja訳が実際に切り替わる。**アプリ内
///    即時反映ではなく再起動が必要** — SwiftUIの`Text(LocalizedStringKey)`
///    解決はプロセス起動時にロードされた `Bundle` のローカライズに紐づいてお
///    り、`.environment(\.locale, ...)` を注入するだけでは文字列カタログの
///    参照先 (どの `.lproj` 相当のテーブルを引くか) までは切り替わらないた
///    め。設定画面にその旨 (「変更の反映には再起動が必要です」) を明示する。
/// 2. `effectiveLanguageCode` — メッセージの言語とアプリの表示言語を比較する
///    機能 (本文画面の翻訳ボタンの表示条件、AI要約の出力言語) がこの値を読む。
///    `.system` のときは `Locale.preferredLanguages` から実際に解決された
///    言語コードを返す。
enum AppLanguageOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    // A「UI に複数言語が混在」実機報告の原因の一つ: `Text(String)`は自動で
    // ローカライズされない ("verbatim"呼び出し) — `docs/localization.md`の
    // パターン1どおり`String(localized:)`で明示的にカタログを引く
    // (`OtherSettingsView`の`Picker`が`Text(option.title)`としてこの
    // `String`を渡すため。この「表示言語」ピッカー自身の選択肢ラベルが
    // 未対応だったのは皮肉だが、実際に表示言語を切り替えてもこのピッカー
    // だけ日本語のままになる実バグだった)。
    var title: String {
        switch self {
        case .system: String(localized: "システムに従う")
        case .japanese: String(localized: "日本語")
        case .english: "English"
        }
    }
}

enum LocalizationSettingsStore {
    /// ユーザーが選んだ選択肢そのもの ("system"/"ja"/"en") — `AppleLanguages`
    /// 自体には「システムに従う」という値を書き戻せない (キーを削除するしか
    /// ない) ため、ユーザーの選択を覚えておく専用キーが別途必要。
    static let languageOptionKey = "app.languageOption"
    static let defaultLanguageOption = AppLanguageOption.system

    /// システム標準の `AppleLanguages` キー — `Bundle.main` のローカライズ
    /// 解決が起動時に参照する。このキーを直接いじるのは古典的なテクニック
    /// (Info.plist の `CFBundleLocalizations` に含まれる言語コードの配列を
    /// 設定すると、次回起動からその言語が最優先で使われる)。
    private static let appleLanguagesKey = "AppleLanguages"

    static var current: AppLanguageOption {
        guard let raw = UserDefaults.standard.string(forKey: languageOptionKey) else {
            return defaultLanguageOption
        }
        return AppLanguageOption(rawValue: raw) ?? defaultLanguageOption
    }

    /// 選択を保存し、`AppleLanguages` を書き換える (`.system` なら削除して
    /// OS本来の言語解決に戻す)。呼び出し側 (設定画面) が「再起動が必要」の
    /// 案内を出す前提。
    static func setLanguageOption(_ option: AppLanguageOption) {
        UserDefaults.standard.set(option.rawValue, forKey: languageOptionKey)
        switch option {
        case .system:
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        case .japanese, .english:
            UserDefaults.standard.set([option.rawValue], forKey: appleLanguagesKey)
        }
    }

    /// 「今実際にどの言語で表示されているか」を "ja"/"en" (またはそれ以外の
    /// システム言語コード) で返す — 本文画面の翻訳ボタン表示条件・AI要約の
    /// 出力言語判定に使う。`.system` のときは `Locale.preferredLanguages`
    /// の先頭要素の言語コードを返す (`AppleLanguages`を上書きしていない状態
    /// でOS自体がどの言語を選んでいるか)。
    static var effectiveLanguageCode: String {
        switch current {
        case .japanese: "ja"
        case .english: "en"
        case .system: Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "ja"
        }
    }
}
