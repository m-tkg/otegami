import Foundation

/// A9-2 「常にテキストで表示」: when on, every HTML message defaults to its
/// extracted-text rendering (`text/plain` part if the message has one,
/// otherwise `HTMLTextExtractor`'s output) instead of the `WKWebView`-based
/// `HTMLMessageView`. `MessageView`'s per-message toggle button (next to the
/// `HTMLBadge`) can still flip an individual message back to HTML for that
/// viewing — this setting only decides the *default* each newly opened
/// message starts from. iOS/macOS common; plain `UserDefaults` key read
/// directly via `@AppStorage`, same reasoning as every other single-flag
/// preference in this directory (`ListDisplaySettingsStore` etc.'s doc
/// comments).
///
/// Default **off**: this app already renders HTML messages reasonably
/// (JS disabled, external/embedded images gated by their own settings —
/// `ImageSettingsStore`), so defaulting to text-only would throw away
/// legitimate formatting (tables, emphasis, structured newsletters) most
/// users would rather keep seeing unless they explicitly ask not to.
enum HTMLDisplaySettingsStore {
    static let alwaysShowPlainTextKey = "htmlDisplay.alwaysShowPlainText"
    static let defaultAlwaysShowPlainText = false

    /// Task #45「ダークモードで文字が読めない」→ Task #51 で判定方式を
    /// 変更 → **Task #80 でこの設定の意味と既定値を変更**。
    ///
    /// 実機動画 (f012→f015 遷移) で、ライトデザインの HTML メール
    /// (MakerWorld 等の白背景+濃色文字のマーケティング/通知メール) が
    /// 「初期描画はライトで正しく見える → 読み込み後にスマート反転が
    /// 後がけされて暗転する」— チラつきに加え、反転特有のアーティファクト
    /// (透過ロゴが沈む等、Task #71 参照) が発生し、ユーザーはむしろ
    /// ライト表示のままの方を望んでいることが分かった (Spark 等の他アプリ
    /// はこの種のメールをライトのまま表示する)。
    ///
    /// **Task #80 での意味変更**: 「メールがダークモードで読みにくく
    /// なりそうか」の判定 (`HTMLWebViewCoordinator.decideDarkInversion`
    /// の実効背景色/文字色の実測ロジック自体) はこの設定の ON/OFF に
    /// 関係なく常に行う (`HTMLDocumentBuilder.wrap`側の
    /// `shouldConsiderDarkModeHandling`は `forceLightBackground`とメール
    /// 自身のダーク対応有無だけで決まり、もうこのキーを参照しない)。
    /// この設定が実際に左右するのは、判定が「介入が要る」と出たときの
    /// **対処の種類**だけ:
    /// - **OFF (新既定)**: 反転せず、メール本来の配色のまま (白カード)
    ///   表示する — 新しい既定挙動。`.otegami-keep-light-active`クラス
    ///   (`HTMLDocumentBuilder.wrap`のdoc comment参照)。
    /// - **ON (旧既定・任意)**: 従来どおりの古典的「反転」手法
    ///   (`filter: invert(1) hue-rotate(180deg)`、`img`/`picture`/`video`/
    ///   背景画像を持つ要素には同フィルタを再適用して元の色を維持) を
    ///   適用する — 文字中心のメールで暗い背景を好むユーザー向けの
    ///   オプトイン。`.otegami-invert-for-dark`クラス。
    ///
    /// 色指定を一切持たないメール (判定が「介入不要」と出るケース) は
    /// この設定に関わらず常にダークネイティブ (このファイル自身の CSS
    /// リセットが与える `color: CanvasText` にダークモード中の自動解決を
    /// 任せる) のまま — Task #51 で確認済みのとおり、この既定を反転
    /// させると壊れる方向に働くため、そもそも判定の対象にすら入らない。
    /// メール自身が自前のダーク対応 (`meta name="color-scheme"` /
    /// `prefers-color-scheme`) を宣言している場合も同様に対象外 (二重に
    /// 手を加えない)。
    ///
    /// **既定を OFF に変更** (旧既定は ON): チラつき・反転アーティファクト
    /// への実機フィードバックを受け、「反転しない (ライトのまま見せる)」
    /// 方を新しい既定とし、従来の反転挙動は望むユーザーだけが明示的に
    /// ONにするオプトインへ位置付けを変えた。**キー自体は変更しない** —
    /// 既に ON で保存済みの既存ユーザーの値はそのまま尊重され、この
    /// 既定値の変更は「未設定 (今回初めて起動するユーザー)」の解決先
    /// にのみ影響する。
    ///
    /// `ImageSettingsStore`の2キーと同じ理由で、`HTMLMessageView.init`が
    /// `UserDefaults.standard.bool(forKey:)`を直接読んで`@State`を種付け
    /// する (`@AppStorage`ではない) — この設定は`HTMLDocumentBuilder.wrap
    /// (bodyHTML:autoAdjustColorsInDarkMode:)`が生成する HTML 文書そのもの
    /// に焼き込まれるため、メールを開くたびに新しく作られる
    /// `HTMLMessageView`インスタンスが常に最新の設定値を反映する必要が
    /// ある。`registerOtegamiHTMLDisplayDefaults()`が `AppEnvironment.init()`
    /// から起動時に一度呼ばれ、未設定キーでもこの既定値 (false) に解決
    /// されるようにしてある。
    static let autoAdjustColorsInDarkModeKey = "htmlDisplay.autoAdjustColorsInDarkMode"
    static let defaultAutoAdjustColorsInDarkMode = false

    /// Task #71 (実機フィードバック「メールの背景を常に白（ライト表示）に
    /// したい」): 本文を常にメール本来の配色 (Gmail の「ライト表示」相当)
    /// で見せる — ダークモード中でも `autoAdjustColorsInDarkModeKey` の
    /// 「スマート反転」を一切適用せず、HTML は wrapper 自体の
    /// `color-scheme`/背景をライトに固定し、プレーンテキストは白背景+濃色
    /// 文字で描画する (`MessageView.content`のプレーンテキスト各分岐参照)。
    /// `autoAdjustColorsInDarkModeKey`とは排他 — この設定が ON の間は
    /// スマート反転の設定トグル自体を無効化 (グレーアウト) する
    /// (`MailViewerSettingsView`参照)。既定 **OFF**: 大多数のユーザーは
    /// アプリ全体のダークモードに本文も追従してほしいはずで、常時ライト
    /// 表示は「元の配色を優先したい」という明示的な選択のときだけ使う
    /// オプトイン機能。
    ///
    /// **Task #80 との違い (重要)**: Task #80 で入った新しい既定挙動
    /// (`autoAdjustColorsInDarkModeKey`のdoc comment参照) は、ダーク
    /// モード中に**ライトデザインだと判定できたメールだけ**をライトの
    /// まま見せる — 色指定を一切持たないメールはダークネイティブの
    /// ままで、この設定とは別物。対してこの `forceLightBackgroundKey`
    /// は**判定を一切行わず無条件**に全メールをライト固定にする (色
    /// 指定のないメールも含め、常に白背景+濃色文字で強制描画) —
    /// 「メールごとの実際の配色を尊重しつつダークモードでも読みやすく
    /// する」新既定と、「メールの中身によらず常にライト表示したい」と
    /// いう、より強い・明示的な選択をするこの設定は、意図も適用範囲も
    /// 異なる。設定画面 (`MailViewerSettingsView`) の説明文もこの区別が
    /// 分かるように書く。
    ///
    /// `autoAdjustColorsInDarkModeKey`と同じ理由で `HTMLMessageView.init`
    /// が `UserDefaults.standard.bool(forKey:)` を直接読んで `@State` を
    /// 種付けする (`@AppStorage`ではない) — この設定も`HTMLDocumentBuilder
    /// .wrap(bodyHTML:autoAdjustColorsInDarkMode:forceLightBackground:)`が
    /// 生成する HTML 文書そのものに焼き込まれるため。
    static let forceLightBackgroundKey = "htmlDisplay.forceLightBackground"
    static let defaultForceLightBackground = false
}

extension UserDefaults {
    /// `ImageSettingsStore.registerOtegamiImageDefaults()`と同じ理由 —
    /// `autoAdjustColorsInDarkModeKey`/`forceLightBackgroundKey`は
    /// `HTMLMessageView.init`が`UserDefaults.standard.bool(forKey:)`を直接
    /// 読むため、`@AppStorage`の「初回読み取り時だけ default 引数が効く」
    /// という挙動に頼れない。
    static func registerOtegamiHTMLDisplayDefaults() {
        standard.register(defaults: [
            HTMLDisplaySettingsStore.autoAdjustColorsInDarkModeKey: HTMLDisplaySettingsStore.defaultAutoAdjustColorsInDarkMode,
            HTMLDisplaySettingsStore.forceLightBackgroundKey: HTMLDisplaySettingsStore.defaultForceLightBackground
        ])
    }
}
